#!/usr/bin/env bash
# Fetches Ableton Link at a pinned release and builds its C wrapper (abl_link)
# as a static library for fire:link.
#
#   ./scripts/link.sh          fetch and build (skips work already done)
#   ./scripts/link.sh --clean  start over
#
# Result: third_party/link/lib/libabl_link.a (abl_link.lib on Windows).
# third_party/ is gitignored: Link is GPLv2+ (or Ableton's commercial licence)
# and is never committed. Apps that link fire:link must follow that licence.
# Needs git, CMake 3.16+ and a C++ compiler (MSVC on Windows).
set -euo pipefail

LINK_TAG="Link-4.1.1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/third_party/link"
SRC="$DIR/src"
BUILD="$DIR/build"
LIB="$DIR/lib"

# macOS privacy protection can block (not fail) access to ~/Downloads,
# ~/Desktop and iCloud folders, and CMake searches every PATH entry: one
# such entry hangs the configure step. Leave them out of PATH.
if [ "$(uname -s)" = "Darwin" ]; then
	PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vE "^$HOME/(Downloads|Desktop|Library/Mobile Documents)(/|$)" | paste -sd: -)"
	export PATH
fi

# On Windows, CMake is often installed but not yet on this shell's PATH.
if ! command -v cmake > /dev/null && [ -x "/c/Program Files/CMake/bin/cmake.exe" ]; then
	PATH="$PATH:/c/Program Files/CMake/bin"
fi
command -v cmake > /dev/null || { echo "link.sh: CMake 3.16+ is required" >&2; exit 1; }

[ "${1:-}" = "--clean" ] && rm -rf "$DIR"
mkdir -p "$DIR" "$LIB"

if [ ! -f "$SRC/.fire_tag" ] || [ "$(cat "$SRC/.fire_tag")" != "$LINK_TAG" ]; then
	rm -rf "$SRC"
	git clone -q --depth 1 --branch "$LINK_TAG" --recurse-submodules --shallow-submodules \
		https://github.com/Ableton/link "$SRC"
	echo "$LINK_TAG" > "$SRC/.fire_tag"
fi

# A minimal project: only the abl_link library, none of Link's examples or tests.
mkdir -p "$BUILD"
CMAKE_SRC="$SRC"
command -v cygpath > /dev/null && CMAKE_SRC="$(cygpath -m "$SRC")" # native CMake on Windows needs C:/ paths
cat > "$BUILD/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.16)
project(fire_abl_link C CXX)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded") # static CRT, as Odin links
include("$CMAKE_SRC/AbletonLinkConfig.cmake")
include("$CMAKE_SRC/extensions/abl_link/abl_link.cmake")
CMAKE

case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	cmake -S "$BUILD" -B "$BUILD/out" -DCMAKE_BUILD_TYPE=Release >/dev/null
	cmake --build "$BUILD/out" --config Release --target abl_link >/dev/null
	cp "$BUILD/out/Release/abl_link.lib" "$LIB/abl_link.lib"
	;;
*)
	cmake -S "$BUILD" -B "$BUILD/out" -DCMAKE_BUILD_TYPE=Release >/dev/null
	cmake --build "$BUILD/out" --target abl_link -j >/dev/null
	cp "$BUILD/out/libabl_link.a" "$LIB/libabl_link.a"
	;;
esac
echo "Built $LINK_TAG: $(ls "$LIB")"
