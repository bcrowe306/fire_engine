# The system Pads' Linux packages are built on (scripts/release/linux.sh):
# Ubuntu 22.04, so they need glibc 2.35 and GCC 12's libstdc++ at most and
# run on it, Debian 12, Raspberry Pi OS Bookworm and anything newer. Built
# for the machine's own architecture (x86-64 or ARM64).
FROM ubuntu:22.04

ARG ODIN_RELEASE=dev-2026-10
ARG TASK_VERSION=v3.44.1
ENV DEBIAN_FRONTEND=noninteractive

# Odin's linker (clang), CMake for SDL3, libusb and Link; SDL3's build
# dependencies (it loads X11, Wayland, Vulkan and the rest at run time);
# ALSA; Python for Dear Bindings; the packaging tools.
RUN apt-get update && apt-get install -y --no-install-recommends \
	build-essential clang llvm cmake ninja-build pkg-config git curl ca-certificates rsync file \
	python3 python3-venv autoconf automake libtool \
	libasound2-dev libudev-dev libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxfixes-dev libxi-dev \
	libxss-dev libxtst-dev libxkbcommon-dev libdrm-dev libgbm-dev libgl1-mesa-dev libgles2-mesa-dev libegl1-mesa-dev \
	libdbus-1-dev libpulse-dev libwayland-dev libdecor-0-dev libvulkan-dev wayland-protocols \
	&& rm -rf /var/lib/apt/lists/*

RUN ARCH="$(dpkg --print-architecture)" \
	&& mkdir -p /opt/odin \
	&& curl -fsSL "https://github.com/odin-lang/Odin/releases/download/$ODIN_RELEASE/odin-linux-$ARCH-$ODIN_RELEASE.tar.gz" | tar -xz -C /opt/odin --strip-components=1 \
	&& ln -sf /opt/odin/odin /usr/local/bin/odin \
	&& curl -fsSL "https://github.com/go-task/task/releases/download/$TASK_VERSION/task_linux_$ARCH.tar.gz" | tar -xz -C /usr/local/bin task \
	&& odin version && task --version
