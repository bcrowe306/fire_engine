#!/usr/bin/env bash
# Makes Pads' icons from apps/pads/assets/icon_source.jpeg (macOS: sips and
# iconutil): icon.png (1024), icon_256.png, icon.icns (the .app's), icon.ico
# (Windows'). The results are committed, so other systems need no tools.
#
#   ./scripts/release/icons.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
A="$ROOT/apps/pads/assets"
SRC="$A/icon_source.jpeg"
T="$(mktemp -d)"
sips -s format png -z 1024 1024 "$SRC" --out "$A/icon.png" > /dev/null
sips -z 256 256 "$A/icon.png" --out "$A/icon_256.png" > /dev/null
S="$T/icon.iconset"
mkdir -p "$S"
for n in 16 32 128 256 512; do
	sips -z $n $n "$A/icon.png" --out "$S/icon_${n}x${n}.png" > /dev/null
	sips -z $((n * 2)) $((n * 2)) "$A/icon.png" --out "$S/icon_${n}x${n}@2x.png" > /dev/null
done
iconutil -c icns "$S" -o "$A/icon.icns"
sips -s format ico "$A/icon_256.png" --out "$A/icon.ico" > /dev/null
rm -rf "$T"
ls -la "$A"
