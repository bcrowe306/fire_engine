#!/usr/bin/env bash
# Runs Fire Engine test packages under tests/.
#
#   ./scripts/test.sh              all packages
#   ./scripts/test.sh dsp rt       selected packages
#
# Env:
#   FIRE_UPDATE_GOLDEN=1   rewrite golden WAVs instead of comparing
#   FIRE_OPT=speed         optimization level (default: none; CI also runs speed)
#   FIRE_NO_PLOT=1         skip plotting failure artifacts
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OPT="${FIRE_OPT:-none}"
export FIRE_ARTIFACTS_DIR="${FIRE_ARTIFACTS_DIR:-$ROOT/.test_artifacts}"
rm -rf "$FIRE_ARTIFACTS_DIR"

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

mkdir -p "$ROOT/.build"
failed=()
for pkg in "${PKGS[@]}"; do
	echo "=== tests/$pkg (-o:$OPT)"
	if ! odin test "tests/$pkg" -collection:fire=f_engine -o:"$OPT" \
		-vet -strict-style -out:"$ROOT/.build/test_$pkg.bin"; then
		failed+=("$pkg")
	fi
done

# Render a PNG for every comparison that left artifacts behind.
if [ "${#failed[@]}" -gt 0 ] && [ -z "${FIRE_NO_PLOT:-}" ] && [ -d "$FIRE_ARTIFACTS_DIR" ]; then
	PY="$(command -v python3 || command -v python || true)"
	if [ -n "$PY" ]; then
		for dir in "$FIRE_ARTIFACTS_DIR"/*/; do
			[ -f "$dir/actual.wav" ] && "$PY" scripts/plot.py "$dir" || true
		done
	fi
fi

if [ "${#failed[@]}" -gt 0 ]; then
	echo "FAILED packages: ${failed[*]}"
	[ -d "$FIRE_ARTIFACTS_DIR" ] && echo "Artifacts: $FIRE_ARTIFACTS_DIR"
	exit 1
fi
echo "All test packages passed."
