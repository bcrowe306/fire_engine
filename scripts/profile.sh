#!/usr/bin/env bash
# Profiles Pads on this machine: the heavy project (tests/app_ui/drive/profile_heavy.txt)
# playing, with each main view shown, and an empty project; a Spall trace of
# each and a summary (scripts/prof.py) into DIR.
#
#   ./scripts/profile.sh [DIR] [FRAMES]     # default .build/profile, 600 frames
#
# Builds .build/app/pads-prof (task app:pads-prof: -define:FIRE_PROF=true)
# unless PADS_PROF names a build already made. Fake audio, headless (no
# window): the UI is still drawn every frame (--profile), except in
# heavy-audio, which leaves the cores to the audio. The fake device
# plays 256-frame blocks at 48 kHz: a block's budget is 5333 µs, a frame's
# (60 a second) 16667 µs. On a machine
# without a GPU the "gpu draw" zone is the software renderer's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${1:-$ROOT/.build/profile}"
FRAMES="${2:-600}"
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
cd "$ROOT"
PADS="${PADS_PROF:-$ROOT/.build/app/pads-prof}"
if [ -z "${PADS_PROF:-}" ]; then task app:pads-prof >/dev/null; fi
EXE=""; [ -f "$PADS.exe" ] && EXE=".exe"
PY="$(command -v python3 || command -v python)"

run() { # NAME DRIVE-LINES... (PROFILE=0: the script's frames only, not drawn)
	local name="$1"; shift
	local drive="$DIR/$name.txt"
	: > "$drive"
	for l in "$@"; do printf '%s\n' "$l" >> "$drive"; done
	local prefs="$DIR/prefs-$name"
	rm -rf "$prefs"
	echo "== $name"
	local flat=(--profile "$FRAMES")
	[ "${PROFILE:-1}" = 0 ] && flat=()
	"$PADS$EXE" --fake --headless --prefs "$prefs" ${flat[@]+"${flat[@]}"} --drive "$drive" --out "$DIR/shots" --trace "$DIR/$name.spall" | tail -1
	"$PY" scripts/prof.py "$DIR/$name.spall" --per frame --top 30 --budget graph=5333 --budget frame=16667 > "$DIR/$name.summary.txt"
	head -3 "$DIR/$name.summary.txt" | tail -2
}

heavy="$(cat tests/app_ui/drive/profile_heavy.txt)"
IFS=$'\n' read -r -d '' -a H <<< "$heavy" || true
run empty "size 1440 900" "wait 10"
# The audio alone: the script's frames are not drawn (headless), so no
# renderer (a software one, on a machine without a GPU) shares the cores.
PROFILE=0 run heavy-audio "${H[@]}" "panel sequence" "wait $FRAMES"
for view in sequence mixer song perform; do
	run "heavy-$view" "${H[@]}" "panel $view" "wait 10"
done
echo "traces and summaries in $DIR (open a .spall at https://gravitymoth.com/spall/)"
