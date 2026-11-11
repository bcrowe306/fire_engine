#!/usr/bin/env bash
# Builds Pads.app and Pads-<version>-macos-<arch>.dmg in .build/release
# (dmgbuild, from .deps/venv). Unsigned for now: the first open is
# right-click > Open (signing and notarization are on the roadmap).
#
#   ./scripts/release/macos.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
APP="$OUT/macos/Pads.app"
rm -rf "$OUT/macos"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
build_pads "$APP/Contents/MacOS/Pads"
cp "$ROOT/apps/pads/assets/icon.icns" "$APP/Contents/Resources/Pads.icns"
collect_licenses "$APP/Contents/Resources/LICENSES"
SHORT="${VERSION%%-*}" # (CFBundleShortVersionString: numbers only)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleName</key><string>Pads</string>
	<key>CFBundleDisplayName</key><string>Pads</string>
	<key>CFBundleExecutable</key><string>Pads</string>
	<key>CFBundleIdentifier</key><string>dev.fire-engine.pads</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleIconFile</key><string>Pads</string>
	<key>CFBundleShortVersionString</key><string>$SHORT</string>
	<key>CFBundleVersion</key><string>$VERSION+$COMMIT</string>
	<key>CFBundleGetInfoString</key><string>Pads $VERSION ($COMMIT, $DATE)</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Pads records audio tracks and samples from your audio inputs.</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
	<key>CFBundleDocumentTypes</key><array><dict>
		<key>CFBundleTypeName</key><string>Pads Project</string>
		<key>CFBundleTypeRole</key><string>Editor</string>
		<key>CFBundleTypeExtensions</key><array><string>pads</string></array>
		<key>LSTypeIsPackage</key><true/>
	</dict></array>
</dict></plist>
PLIST
# An ad-hoc signature (not a Developer ID): Apple silicon runs nothing unsigned.
codesign --force --deep --sign - "$APP"
"$APP/Contents/MacOS/Pads" --version
DMG="$OUT/Pads-$VERSION-macos-$ARCH.dmg"
rm -f "$DMG"
"$ROOT/.deps/venv/bin/dmgbuild" -s "$(dirname "$0")/dmg_settings.py" -D app="$APP" -D icon="$ROOT/apps/pads/assets/icon.icns" "Pads $VERSION" "$DMG"
echo "made $DMG"
