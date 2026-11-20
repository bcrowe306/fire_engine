#!/usr/bin/env bash
# Builds Pads-<version>-linux-<arch>.AppImage (appimagetool, from
# $APPIMAGETOOL or ~/tools) and pads_<version>_<arch>.deb (dpkg-deb) in
# .build/release, for the Linux machine's architecture (x86-64 or ARM64).
#
# Built in a Ubuntu 22.04 container (scripts/release/linux/Dockerfile;
# Docker), the oldest system the packages run on: what a binary links
# against sets the oldest glibc and libstdc++ it runs with, and a build on
# a newer system won't start on an older one (Debian 12, Raspberry Pi OS
# Bookworm). SDL3, ImGui, libusb and Link are built there too, kept in a
# Docker volume between runs. FIRE_RELEASE_NATIVE=1 builds on this machine
# as it is instead (its own glibc then the packages' oldest).
#
#   ./scripts/release/linux.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
DEBARCH=amd64
APPARCH=x86_64
if [ "$ARCH" = arm64 ]; then DEBARCH=arm64; APPARCH=aarch64; fi
TOOL="${APPIMAGETOOL:-$HOME/tools/appimagetool-$APPARCH.AppImage}"
# The newest glibc and libstdc++ (GCC 12's) the baseline's packages may need.
BASELINE_GLIBC=2.35
BASELINE_GLIBCXX=3.4.30

if [ -z "${FIRE_IN_BASELINE:-}" ] && [ "${FIRE_RELEASE_NATIVE:-0}" != 1 ]; then
	command -v docker > /dev/null || { echo "linux.sh: needs Docker (or FIRE_RELEASE_NATIVE=1)" >&2; exit 1; }
	[ -f "$TOOL" ] || { echo "linux.sh: no appimagetool at $TOOL" >&2; exit 1; }
	ODIN_RELEASE="$(sed -n 's/^ *release: *\(dev-[0-9-]*\).*/\1/p' "$ROOT/.github/workflows/ci.yml" | head -1)"
	IMAGE="fire-pads-linux:22.04-$ODIN_RELEASE"
	docker build -q -t "$IMAGE" --build-arg ODIN_RELEASE="$ODIN_RELEASE" "$(dirname "$0")/linux"
	# The tree copied into the volume over what it built before (its
	# libraries: the baseline's, never this machine's; never secrets.env).
	docker run --rm -v "$ROOT:/src:ro" -v "fire-pads-linux-$ARCH:/work" -v "$TOOL:/tools/appimagetool:ro" -v "$OUT:/out" \
		-e FIRE_IN_BASELINE=1 -e APPIMAGETOOL=/tools/appimagetool -e PADS_COMMIT="$COMMIT" "$IMAGE" bash -euc '
		rsync -a --delete --exclude=/.git --exclude=/.build --exclude=/.deps --exclude=/.test_artifacts --exclude=/secrets.env \
			--exclude=/vendor/sdl3/lib --exclude="/vendor/imgui/libimgui_*" --exclude=/vendor/libusb/lib --exclude=/third_party \
			/src/ /work/
		cd /work
		task deps
		bash scripts/release/linux.sh
		cp .build/release/Pads-*-linux-*.AppImage .build/release/pads_*.deb /out/'
	exit 0
fi

L="$OUT/linux"
rm -rf "$L"
mkdir -p "$L"
build_pads "$L/pads"
"$L/pads" --version
# The oldest glibc and libstdc++ it runs with: what it links against.
newest() { objdump -T "$1" | grep -o "$2_[0-9.]*" | sed "s/$2_//" | sort -uV | tail -1; }
NEED_GLIBC="$(newest "$L/pads" GLIBC)"
NEED_GLIBCXX="$(newest "$L/pads" GLIBCXX)"
echo "needs glibc $NEED_GLIBC, libstdc++ $NEED_GLIBCXX"
if [ -n "${FIRE_IN_BASELINE:-}" ]; then
	newer() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" != "$2" ]; }
	if newer "$NEED_GLIBC" "$BASELINE_GLIBC" || newer "$NEED_GLIBCXX" "$BASELINE_GLIBCXX"; then
		echo "linux.sh: needs more than the baseline (glibc $BASELINE_GLIBC, libstdc++ $BASELINE_GLIBCXX)" >&2
		exit 1
	fi
fi
DESKTOP="[Desktop Entry]
Type=Application
Name=Pads
GenericName=Sampler and sequencer
Comment=Pads, samples, a sequencer and a song arranger
Exec=pads %F
Icon=pads
Terminal=false
Categories=AudioVideo;Audio;Music;Midi;
Keywords=sampler;sequencer;drum machine;music;"
# A file system tree of what goes where, for both packages.
tree() {
	local R="$1"
	mkdir -p "$R/usr/bin" "$R/usr/share/applications" "$R/usr/share/icons/hicolor/256x256/apps" "$R/usr/share/icons/hicolor/1024x1024/apps" "$R/usr/share/doc/pads"
	cp "$L/pads" "$R/usr/bin/pads"
	printf '%s\n' "$DESKTOP" > "$R/usr/share/applications/pads.desktop"
	cp "$ROOT/apps/pads/assets/icon_256.png" "$R/usr/share/icons/hicolor/256x256/apps/pads.png"
	cp "$ROOT/apps/pads/assets/icon.png" "$R/usr/share/icons/hicolor/1024x1024/apps/pads.png"
	collect_licenses "$R/usr/share/doc/pads/LICENSES"
}

# The AppImage.
A="$L/Pads.AppDir"
tree "$A"
printf '%s\n' "$DESKTOP" > "$A/pads.desktop"
cp "$ROOT/apps/pads/assets/icon_256.png" "$A/pads.png"
cat > "$A/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/pads" "$@"
RUN
chmod +x "$A/AppRun"
IMG="$OUT/Pads-$VERSION-linux-$ARCH.AppImage"
rm -f "$IMG"
ARCH=$APPARCH "$TOOL" --appimage-extract-and-run --no-appstream "$A" "$IMG"
echo "made $IMG"

# The .deb (its version: 0.1.0~dev, so 0.1.0 itself sorts after it).
D="$L/deb"
tree "$D"
mkdir -p "$D/DEBIAN"
DEBVER="${VERSION/-/\~}-1"
SIZE="$(du -sk "$D/usr" | cut -f1)"
cat > "$D/DEBIAN/control" <<CONTROL
Package: pads
Version: $DEBVER
Section: sound
Priority: optional
Architecture: $DEBARCH
Installed-Size: $SIZE
Depends: libc6 (>= $NEED_GLIBC), libstdc++6 (>= 12), libasound2t64 | libasound2
Recommends: libjack-jackd2-0 | libjack0
Maintainer: Fire Engine developers <https://github.com/bcrowe306/fire_engine/issues>
Homepage: https://github.com/bcrowe306/fire_engine
Description: A pad sampler, sequencer and song arranger
 Pads plays samples, synths and CLAP plug-ins from pads, sequences them,
 arranges songs and mixes them, on the Fire Engine audio engine.
 This is a development release ($COMMIT, $DATE).
CONTROL
cp "$ROOT/apps/pads/LICENSE" "$D/usr/share/doc/pads/copyright"
DEB="$OUT/pads_${DEBVER}_$DEBARCH.deb"
dpkg-deb --build --root-owner-group "$D" "$DEB"
echo "made $DEB"
