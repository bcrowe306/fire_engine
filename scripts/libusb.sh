#!/usr/bin/env bash
# Fetches libusb at a pinned release and builds it as a static library for
# the app layer's USB devices (app/core/devices*.odin: a control surface's
# display, Push 2's). Its own build is autotools; this compiles its sources
# with CMake and a config.h written here, so it builds the same on macOS,
# Linux and Windows (MSVC).
#
#   ./scripts/libusb.sh          fetch and build (skips work already done)
#   ./scripts/libusb.sh --clean  start over
#
# Result: vendor/libusb/lib/<os>_<arch>/libusb.a (windows_x86_64/libusb.lib),
# gitignored. libusb is LGPL-2.1+; it is linked into Pads (GPL-3.0+).
# Needs git, CMake 3.16+ and a C compiler. Linux: no libudev (netlink).
set -euo pipefail

LIBUSB_TAG="v1.0.29"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/.deps/src/libusb"
BUILD="$ROOT/.deps/build/libusb"

case "$(uname -s)" in
Darwin) OS=darwin ;;
Linux) OS=linux ;;
MINGW*|MSYS*|CYGWIN*) OS=windows ;;
*) echo "libusb.sh: no build for $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
x86_64|amd64) ARCH=amd64 ;;
arm64|aarch64) ARCH=arm64 ;;
*) ARCH="$(uname -m)" ;;
esac
LIB="$ROOT/vendor/libusb/lib/${OS}_${ARCH}"
[ "$OS" = windows ] && LIB="$ROOT/vendor/libusb/lib/windows_x86_64" # (as SDL3's)

if [ "$OS" = darwin ]; then # (see link.sh: CMake hangs on protected folders in PATH)
	PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vE "^$HOME/(Downloads|Desktop|Library/Mobile Documents)(/|$)" | paste -sd: -)"
	export PATH
fi
if ! command -v cmake > /dev/null && [ -x "/c/Program Files/CMake/bin/cmake.exe" ]; then
	PATH="$PATH:/c/Program Files/CMake/bin"
fi
command -v cmake > /dev/null || { echo "libusb.sh: CMake 3.16+ is required" >&2; exit 1; }

if [ "${1:-}" = "--clean" ]; then rm -rf "$SRC" "$BUILD" "$LIB"; fi
if [ ! -f "$SRC/.fire_tag" ] || [ "$(cat "$SRC/.fire_tag")" != "$LIBUSB_TAG" ]; then
	rm -rf "$SRC"
	mkdir -p "$(dirname "$SRC")"
	git -c advice.detachedHead=false clone -q --depth 1 --branch "$LIBUSB_TAG" https://github.com/libusb/libusb.git "$SRC"
	echo "$LIBUSB_TAG" > "$SRC/.fire_tag"
fi

mkdir -p "$BUILD" "$LIB"
# config.h: what autotools would find.
case "$OS" in
darwin) cat > "$BUILD/config.h" <<'H'
#define DEFAULT_VISIBILITY __attribute__((visibility("default")))
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))
#define ENABLE_LOGGING 1
#define PLATFORM_POSIX 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_NFDS_T 1
#define HAVE_SYS_TIME_H 1
#define HAVE_PTHREAD_THREADID_NP 1
#define HAVE_IOKIT_USB_IOUSBHOSTFAMILYDEFINITIONS_H 1
#define _GNU_SOURCE 1
H
	;;
linux) cat > "$BUILD/config.h" <<'H'
#define DEFAULT_VISIBILITY __attribute__((visibility("default")))
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))
#define ENABLE_LOGGING 1
#define PLATFORM_POSIX 1
#define HAVE_CLOCK_GETTIME 1
#define HAVE_NFDS_T 1
#define HAVE_SYS_TIME_H 1
#define HAVE_ASM_TYPES_H 1
#define HAVE_EVENTFD 1
#define HAVE_TIMERFD 1
#define HAVE_PIPE2 1
#define HAVE_PTHREAD_CONDATTR_SETCLOCK 1
#define HAVE_PTHREAD_SETNAME_NP 1
#define _GNU_SOURCE 1
H
	;;
windows) cat > "$BUILD/config.h" <<'H'
#if (_MSC_VER >= 1900)
#define _TIMESPEC_DEFINED 1
#endif
#pragma warning(disable:4127 4200 4201 4324 4996)
#define DEFAULT_VISIBILITY
#define PRINTF_FORMAT(a, b)
#define ENABLE_LOGGING 1
#define PLATFORM_WINDOWS 1
H
	;;
esac

CMAKE_SRC="$SRC"; CMAKE_BUILD="$BUILD"
if command -v cygpath > /dev/null; then CMAKE_SRC="$(cygpath -m "$SRC")"; CMAKE_BUILD="$(cygpath -m "$BUILD")"; fi
cat > "$BUILD/CMakeLists.txt" <<CMAKE
cmake_minimum_required(VERSION 3.16)
project(fire_libusb C)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded") # static CRT, as Odin links
set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0)
set(S "$CMAKE_SRC/libusb")
set(SOURCES \${S}/core.c \${S}/descriptor.c \${S}/hotplug.c \${S}/io.c \${S}/strerror.c \${S}/sync.c)
if(APPLE)
	list(APPEND SOURCES \${S}/os/darwin_usb.c \${S}/os/events_posix.c \${S}/os/threads_posix.c)
elseif(WIN32)
	list(APPEND SOURCES \${S}/os/events_windows.c \${S}/os/threads_windows.c \${S}/os/windows_common.c \${S}/os/windows_usbdk.c \${S}/os/windows_winusb.c)
else()
	list(APPEND SOURCES \${S}/os/linux_usbfs.c \${S}/os/linux_netlink.c \${S}/os/events_posix.c \${S}/os/threads_posix.c)
endif()
add_library(usb STATIC \${SOURCES})
target_include_directories(usb PRIVATE "$CMAKE_BUILD" \${S} \${S}/os)
if(MSVC)
	target_compile_options(usb PRIVATE /W1)
else()
	target_compile_options(usb PRIVATE -w -O2 -fvisibility=hidden)
endif()
CMAKE

cmake -S "$BUILD" -B "$BUILD/out" -DCMAKE_BUILD_TYPE=Release > /dev/null
cmake --build "$BUILD/out" --config Release -j > /dev/null
if [ "$OS" = windows ]; then
	cp "$BUILD/out/Release/usb.lib" "$LIB/libusb.lib"
else
	cp "$BUILD/out/libusb.a" "$LIB/libusb.a"
fi
cp "$SRC/COPYING" "$ROOT/vendor/libusb/COPYING.libusb"
echo "Built libusb $LIBUSB_TAG: $LIB"
