#!/usr/bin/env bash
# Generates the API reference (docs/reference/**.md) from doc comments.
#
#   ./scripts/docs.sh           regenerate docs/reference
#   ./scripts/docs.sh --check   fail if docs/reference is out of date, or if a
#                               strict package has undocumented exports (CI)
#
# Pages are Markdown with Starlight front matter; see docs/README.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# package dir (under f_engine/) [: target for OS-specific packages]
PACKAGES=(
	core timebase rt dsp graph transport link audiofile audiofile/codecs stream clip
	backend backend/fake backend/jack
	backend/coreaudio:darwin_arm64 backend/alsa:linux_amd64 backend/wasapi:windows_amd64
	midi midi/coremidi:darwin_arm64 midi/alsa:linux_amd64 midi/winmm:windows_amd64
	testkit
)
# Every exported symbol must be documented in these packages (all of them).
STRICT=" "
for entry in "${PACKAGES[@]}"; do STRICT+="${entry%%:*} "; done

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
# A private work dir per run, so concurrent runs don't collide.
mkdir -p "$ROOT/.build"
WORK="$(mktemp -d "$ROOT/.build/docs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OUT="$ROOT/docs/reference"
[ $CHECK = 1 ] && OUT="$WORK/reference"
mkdir -p "$WORK/bin" "$OUT"

DOCGEN="$WORK/bin/docgen"
case "$(uname -s)" in MINGW*|MSYS*) DOCGEN="$DOCGEN.exe" ;; esac
odin build tools/docgen -collection:fire=f_engine -out:"$DOCGEN" >/dev/null
status=0
for entry in "${PACKAGES[@]}"; do
	pkg="${entry%%:*}"
	target=""
	[ "$entry" != "$pkg" ] && target="-target:${entry#*:}"
	# odin doc cannot target Windows from another OS (it wants an SDK, and
	# doesn't take -windows-sdk-root): those pages are generated on Windows.
	if [[ "$target" == *windows* ]] && [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]]; then
		[ $CHECK = 1 ] && cp "$ROOT/docs/reference/$pkg.md" "$OUT/$pkg.md" 2>/dev/null || true
		continue
	fi
	name="${pkg//\//_}"
	mkdir -p "$(dirname "$OUT/$pkg.md")"
	odin doc "f_engine/$pkg" -collection:fire=f_engine -doc-format -all-packages $target -out:"$WORK/$name.odin-doc" >/dev/null
	strict=""
	[[ "$STRICT" == *" $pkg "* ]] && strict="--strict"
	if ! "$DOCGEN" "$WORK/$name.odin-doc" "f_engine/$pkg" "$OUT/$pkg.md" $strict; then
		status=1
	fi
done

if [ $CHECK = 1 ]; then
	if ! diff -r -q "$ROOT/docs/reference" "$OUT" >/dev/null 2>&1; then
		diff -r -q "$ROOT/docs/reference" "$OUT" || true
		echo "docs/reference is out of date: run ./scripts/docs.sh and commit the result"
		status=1
	fi
fi
exit $status
