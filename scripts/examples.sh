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
