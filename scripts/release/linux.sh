#!/usr/bin/env bash
# Builds Pads-<version>-linux-<arch>.AppImage (appimagetool, from
# $APPIMAGETOOL or ~/tools) and pads_<version>_<arch>.deb (dpkg-deb) in
# .build/release, on the Linux machine it runs on (x86-64 or ARM64).
#
#   ./scripts/release/linux.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
DEBARCH=amd64
APPARCH=x86_64
if [ "$ARCH" = arm64 ]; then DEBARCH=arm64; APPARCH=aarch64; fi
L="$OUT/linux"
rm -rf "$L"
mkdir -p "$L"
build_pads "$L/pads"
"$L/pads" --version
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
TOOL="${APPIMAGETOOL:-$HOME/tools/appimagetool-$APPARCH.AppImage}"
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
Depends: libc6, libstdc++6, libasound2t64 | libasound2
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
