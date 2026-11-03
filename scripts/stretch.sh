#!/usr/bin/env bash
# Builds Signalsmith Stretch (vendored in vendor/signalsmith) with our C
# wrapper into a static library for fire:stretch:
#   f_engine/sys/signalsmith/lib/libfire_signalsmith.a (fire_signalsmith.lib on Windows)
# The library (lib/) is gitignored; the sources are committed (MIT).
# Needs CMake 3.16+ and a C++17 compiler (MSVC on Windows).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYS="$ROOT/f_engine/sys/signalsmith"
BUILD="$ROOT/.build/signalsmith"
mkdir -p "$BUILD" "$SYS/lib"

# macOS privacy protection can block access to ~/Downloads etc.; CMake scans
# PATH and would hang on such an entry (see scripts/link.sh).
if [ "$(uname -s)" = "Darwin" ]; then
	PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vE "^$HOME/(Downloads|Desktop|Library/Mobile Documents)(/|$)" | paste -sd: -)"
	export PATH
fi
if ! command -v cmake > /dev/null && [ -x "/c/Program Files/CMake/bin/cmake.exe" ]; then
	PATH="$PATH:/c/Program Files/CMake/bin"
fi
command -v cmake > /dev/null || { echo "stretch.sh: CMake 3.16+ is required" >&2; exit 1; }

P="$ROOT"
command -v cygpath > /dev/null && P="$(cygpath -m "$ROOT")" # native CMake on Windows needs C:/ paths
cat > "$BUILD/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.16)
project(fire_signalsmith CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded") # static CRT, as Odin links
add_library(fire_signalsmith STATIC "$P/f_engine/sys/signalsmith/wrapper.cpp")
target_include_directories(fire_signalsmith PRIVATE "$P/vendor/signalsmith/stretch" "$P/vendor/signalsmith/linear/include")
CMAKE

case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	cmake -S "$BUILD" -B "$BUILD/out" > /dev/null
	cmake --build "$BUILD/out" --config Release > /dev/null
	cp "$BUILD/out/Release/fire_signalsmith.lib" "$SYS/lib/fire_signalsmith.lib"
	;;
*)
	cmake -S "$BUILD" -B "$BUILD/out" -DCMAKE_BUILD_TYPE=Release > /dev/null
	cmake --build "$BUILD/out" -j > /dev/null
	cp "$BUILD/out/libfire_signalsmith.a" "$SYS/lib/libfire_signalsmith.a"
	;;
esac
echo "Built: $(ls "$SYS/lib")"
