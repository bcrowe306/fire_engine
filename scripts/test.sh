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
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

read -r -a OPTS <<< "${FIRE_OPT:-none}"
ARTIFACTS="${FIRE_ARTIFACTS_DIR:-$ROOT/.test_artifacts}"
TIMEOUT="${FIRE_TIMEOUT:-600}"
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

# Portable timeout (GNU `timeout` is missing on stock macOS). `odin test` runs
# the test binary as its child, so the children are killed first.
run_with_timeout() {
	local secs="$1"; shift
	"$@" &
	local pid=$!
	(
		sleep "$secs"
		echo "*** killed after ${secs}s (hung?)"
		pkill -9 -P "$pid" 2>/dev/null
		kill -9 "$pid" 2>/dev/null
	) &
	local watchdog=$!
	wait "$pid"
	local status=$?
	pkill -P "$watchdog" 2>/dev/null
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

start=$(date +%s)
JOBS=()
for opt in "${OPTS[@]}"; do
	artifacts="$ARTIFACTS"
	[ "${#OPTS[@]}" -gt 1 ] && artifacts="$ARTIFACTS/$opt"
	for pkg in "${PKGS[@]}"; do
		run_one "$pkg" "$opt" "$artifacts" &
		JOBS+=("$pkg:$opt:$artifacts")
	done
done
wait

failed=()
plot_dirs=()
for job in "${JOBS[@]}"; do
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
