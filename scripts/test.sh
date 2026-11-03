#!/usr/bin/env bash
# Runs Fire Engine test packages under tests/, all in parallel.
#
#   ./scripts/test.sh              all packages
#   ./scripts/test.sh dsp rt       selected packages
#
# Env:
#   FIRE_UPDATE_GOLDEN=1   rewrite golden WAVs instead of comparing
#   FIRE_OPT=speed         optimization level(s), space-separated (default: none).
#                          FIRE_OPT="none speed" runs both at once; artifacts then
#                          go to $FIRE_ARTIFACTS_DIR/<opt>/.
#   FIRE_NO_PLOT=1         skip plotting failure artifacts
#   FIRE_TIMEOUT=600       seconds before a hung package is killed (default 600)
#   FIRE_MAX_RSS_MB=3072   memory (MB) at which a package's processes are killed
#                          (macOS and Linux), so a runaway test can't exhaust RAM
#   FIRE_JOBS=4            packages built and run at once (default: CPU count).
#                          Each compile takes ~300 MB, so small machines need a cap.
#
# Packages containing a SERIAL file run after all others, one at a time:
# real-device streaming tests that require zero xruns (so compiles and other
# tests don't preempt their audio threads), and tests whose system-wide device
# changes other processes would see. The file says why.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

read -r -a OPTS <<< "${FIRE_OPT:-none}"
ARTIFACTS="${FIRE_ARTIFACTS_DIR:-$ROOT/.test_artifacts}"
TIMEOUT="${FIRE_TIMEOUT:-600}"
JOBS_MAX="${FIRE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
rm -rf "$ARTIFACTS"

if [ "$#" -gt 0 ]; then
	PKGS=("$@")
else
	PKGS=()
	for d in tests/*/; do
		name="$(basename "$d")"
		[ "$name" = "golden" ] && continue
		PKGS+=("$name")
	done
fi

# Binaries and logs live under the artifacts dir, so concurrent invocations with
# different FIRE_ARTIFACTS_DIR values never share files.
WORK="$ARTIFACTS/.run"
LOGS="$WORK"
mkdir -p "$WORK"

# Portable timeout (GNU `timeout` is missing on stock macOS; `pkill` is missing
# in Git bash on Windows). The watchdog cancels by trapping TERM and killing
# its own sleep. On timeout it kills `odin test` and the test binary it runs.
run_with_timeout() {
	local secs="$1"; shift
	"$@" &
	local pid=$!
	(
		exec 2>/dev/null
		trap 'exit 0' TERM
		# Also a memory cap: a runaway test (an infinite loop that allocates)
		# can otherwise exhaust the machine's RAM. Needs `ps -o rss=`
		# (macOS, Linux); elsewhere only the timeout applies.
		limit_kb=$(( ${FIRE_MAX_RSS_MB:-3072} * 1024 ))
		measure=0
		ps -o rss= -p $$ > /dev/null 2>&1 && command -v pgrep > /dev/null && measure=1
		waited=0
		ticks=0
		reason=""
		while kill -0 "$pid"; do
			if [ "$waited" -ge "$secs" ]; then
				reason="killed after ${secs}s (hung?)"
				break
			fi
			if [ "$measure" = 1 ]; then
				# The process and its descendants (odin test runs the test binary).
				tree="$pid"
				level="$pid"
				for _ in 1 2 3; do
					level="$(for p in $level; do pgrep -P "$p"; done | tr '\n' ' ')"
					[ -z "${level// /}" ] && break
					tree="$tree $level"
				done
				rss="$(ps -o rss= -p "$(echo $tree | tr ' ' ',')" | awk '{s += $1} END {print s + 0}')"
				if [ "$rss" -gt "$limit_kb" ]; then
					reason="killed: using $((rss / 1024)) MB, over FIRE_MAX_RSS_MB=${FIRE_MAX_RSS_MB:-3072} (runaway allocation?)"
					break
				fi
			fi
			sleep 0.25 # often: a runaway can allocate a gigabyte a second
			ticks=$((ticks + 1))
			[ $((ticks % 4)) = 0 ] && waited=$((waited + 1))
		done
		[ -z "$reason" ] && exit 0
		echo "*** $reason"
		if command -v pkill >/dev/null; then
			pkill -9 -P "$pid"
		elif [ -r "/proc/$pid/winpid" ] && command -v taskkill >/dev/null; then
			taskkill //F //T //PID "$(cat "/proc/$pid/winpid")" >/dev/null
		fi
		kill -9 "$pid"
	) &
	local watchdog=$!
	wait "$pid"
	local status=$?
	kill "$watchdog" 2>/dev/null
	wait "$watchdog" 2>/dev/null
	return "$status"
}

run_one() {
	local pkg="$1" opt="$2" artifacts="$3"
	local tag="${pkg}_${opt}"
	local bin="$WORK/test_$tag.bin"
	FIRE_ARTIFACTS_DIR="$artifacts" run_with_timeout "$TIMEOUT" \
		odin test "tests/$pkg" -collection:fire=f_engine -o:"$opt" \
		-vet -strict-style -out:"$bin" \
		> "$LOGS/$tag.log" 2>&1
	echo $? > "$LOGS/$tag.status"
}

# SERIAL packages: compile in the parallel phase, run later.
build_one() {
	local pkg="$1" opt="$2"
	local tag="${pkg}_${opt}"
	odin build "tests/$pkg" -build-mode:test -collection:fire=f_engine -o:"$opt" \
		-vet -strict-style -out:"$WORK/test_$tag.bin" > "$LOGS/$tag.log" 2>&1
	echo $? > "$LOGS/$tag.status"
}

run_built() {
	local pkg="$1" opt="$2" artifacts="$3"
	local tag="${pkg}_${opt}"
	[ "$(cat "$LOGS/$tag.status")" = "0" ] || return # compile failed: log already says why
	(cd "tests/$pkg" && FIRE_ARTIFACTS_DIR="$artifacts" run_with_timeout "$TIMEOUT" "$WORK/test_$tag.bin") \
		>> "$LOGS/$tag.log" 2>&1
	echo $? > "$LOGS/$tag.status"
}

# A package with a REQUIRES file runs only when every glob on its non-comment
# lines matches a file (an optional, separately built dependency). The
# comment lines say how to get it.
requirements_met() {
	local f="tests/$1/REQUIRES" pattern
	[ -f "$f" ] || return 0
	while read -r pattern; do
		case "$pattern" in ''|'#'*) continue ;; esac
		compgen -G "$pattern" > /dev/null || return 1
	done < "$f"
	return 0
}
requirements_hint() {
	grep '^#' "tests/$1/REQUIRES" | sed 's/^# *//' | tr '\n' ' '
}

start=$(date +%s)
JOBS=()
SERIAL=()
for opt in "${OPTS[@]}"; do
	artifacts="$ARTIFACTS"
	[ "${#OPTS[@]}" -gt 1 ] && artifacts="$ARTIFACTS/$opt"
	for pkg in "${PKGS[@]}"; do
		if ! requirements_met "$pkg"; then
			[ "$opt" = "${OPTS[0]}" ] && echo "=== tests/$pkg skipped: $(requirements_hint "$pkg")"
			continue
		fi
		JOBS+=("$pkg:$opt:$artifacts")
		# Portable job limit (no `wait -n` in macOS's bash 3.2).
		while [ "$(jobs -rp | wc -l)" -ge "$JOBS_MAX" ]; do sleep 0.1; done
		if [ -f "tests/$pkg/SERIAL" ]; then
			SERIAL+=("$pkg:$opt:$artifacts")
			build_one "$pkg" "$opt" &
		else
			run_one "$pkg" "$opt" "$artifacts" &
		fi
	done
done
wait
for job in ${SERIAL[@]+"${SERIAL[@]}"}; do
	IFS=: read -r pkg opt artifacts <<< "$job"
	run_built "$pkg" "$opt" "$artifacts"
done

failed=()
plot_dirs=()
for job in ${JOBS[@]+"${JOBS[@]}"}; do
	IFS=: read -r pkg opt artifacts <<< "$job"
	tag="${pkg}_${opt}"
	status="$(cat "$LOGS/$tag.status" 2>/dev/null || echo 1)"
	if [ "$status" = "0" ]; then
		summary="$(grep -E '^Finished' "$LOGS/$tag.log" | tail -1)"
		echo "=== tests/$pkg (-o:$opt) ok  ${summary}"
	else
		echo "=== tests/$pkg (-o:$opt) FAILED"
		cat "$LOGS/$tag.log"
		failed+=("$pkg(-o:$opt)")
		plot_dirs+=("$artifacts")
	fi
done

# Render a PNG for every comparison that left artifacts behind.
if [ "${#failed[@]}" -gt 0 ] && [ -z "${FIRE_NO_PLOT:-}" ]; then
	PY="$(command -v python3 || command -v python || true)"
	if [ -n "$PY" ]; then
		for base in $(printf '%s\n' "${plot_dirs[@]}" | sort -u); do
			[ -d "$base" ] || continue
			for dir in "$base"/*/; do
				[ -f "$dir/actual.wav" ] && "$PY" scripts/plot.py "$dir" || true
			done
		done
	fi
fi

echo "($(( $(date +%s) - start ))s)"
if [ "${#failed[@]}" -gt 0 ]; then
	echo "FAILED: ${failed[*]}"
	echo "Artifacts and logs: $ARTIFACTS"
	exit 1
fi
echo "All test packages passed."
