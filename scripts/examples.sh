#!/usr/bin/env bash
# Builds every example (with -vet -strict-style) and runs it headless:
# FIRE_EXAMPLE_FAKE=1 makes device examples use the simulated driver.
#
#   ./scripts/examples.sh            all examples
#   ./scripts/examples.sh graph_offline
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export FIRE_EXAMPLE_FAKE=1
mkdir -p .build/examples
names=("$@")
[ ${#names[@]} -eq 0 ] && for d in examples/*/; do names+=("$(basename "$d")"); done
failed=()
for name in "${names[@]}"; do
	# An example with a REQUIRES file needs a separately built library (see
	# the file): skipped until it is there.
	req="examples/$name/REQUIRES"
	if [ -f "$req" ]; then
		missing=0
		while read -r pattern; do
			case "$pattern" in ''|'#'*) continue ;; esac
			compgen -G "$pattern" > /dev/null || missing=1
		done < "$req"
		if [ "$missing" = 1 ]; then
			echo "=== examples/$name skipped: $(grep '^#' "$req" | sed 's/^# *//' | tr '\n' ' ')"
			continue
		fi
	fi
	echo "=== examples/$name"
	bin=".build/examples/$name"
	[ "$(uname -s | cut -c1-5)" = "MINGW" ] && bin="$bin.exe"
	if odin build "examples/$name" -collection:fire=f_engine -vet -strict-style -out:"$bin" && "$bin"; then
		:
	else
		failed+=("$name")
	fi
done
if [ ${#failed[@]} -gt 0 ]; then
	echo "FAILED examples: ${failed[*]}"
	exit 1
fi
echo "All examples built and ran."
