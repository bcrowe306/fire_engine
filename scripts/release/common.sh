# Shared by the release scripts (sourced): the version, where things go,
# the release build, and the licences every package carries.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="$(sed -n 's/^PADS_VERSION :: "\(.*\)"/\1/p' "$ROOT/apps/pads/version.odin")"
COMMIT="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
DATE="$(date +%Y-%m-%d)"
OUT="$ROOT/.build/release"
mkdir -p "$OUT"
case "$(uname -m)" in arm64|aarch64) ARCH=arm64 ;; *) ARCH=x86_64 ;; esac

# Builds Pads, optimized (with debug info: crash reports name lines), to $1.
build_pads() {
	local LINKC="off"
	for f in "$ROOT"/third_party/link/lib/*abl_link*; do [ -e "$f" ] && LINKC="on"; done
	odin build "$ROOT/apps/pads" -collection:fire="$ROOT/f_engine" -collection:app="$ROOT/app" \
		-collection:deps="$ROOT/vendor" -collection:padslink="$ROOT/apps/pads/link/$LINKC" \
		-define:PADS_COMMIT="$COMMIT" -define:PADS_DATE="$DATE" \
		${EXTRA_BUILD:-} -o:speed -debug -vet -strict-style -out:"$1"
	echo "built $1 (Link: $LINKC)"
}

# Copies the licences of Pads and what it is built from into $1.
collect_licenses() {
	local D="$1"
	mkdir -p "$D"
	cp "$ROOT/apps/pads/LICENSE" "$D/Pads (GPL-3.0-or-later).txt"
	cp "$ROOT/LICENSE" "$D/Fire Engine (MIT).txt"
	cp "$ROOT/vendor/sdl3/LICENSE-SDL.txt" "$D/SDL3 (zlib).txt"
	cp "$ROOT/vendor/imgui/LICENSE" "$D/Dear ImGui (MIT).txt"
	cp "$ROOT/vendor/clap/LICENSE" "$D/CLAP (MIT).txt"
	cp "$ROOT/vendor/fonts/OpenSans/OFL.txt" "$D/Open Sans (OFL).txt"
	cp "$ROOT/vendor/fonts/Lucide/LICENSE" "$D/Lucide (ISC).txt"
	# (Ableton Link: when it is built in.)
	local LS="$ROOT/third_party/link/src"
	if [ -e "$LS/LICENSE.md" ] && ls "$ROOT"/third_party/link/lib/*abl_link* > /dev/null 2>&1; then
		cp "$LS/LICENSE.md" "$D/Ableton Link.md"
		cp "$LS/GNU-GPL-v2.0.md" "$D/Ableton Link (GPL-2.0).md"
	fi
}

# The release notes, from docs/release-notes.md.
NOTES="$ROOT/docs/release-notes.md"
