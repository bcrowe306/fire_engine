#!/usr/bin/env bash
# Builds Pads-<version>-windows-x86_64-setup.exe (Inno Setup's ISCC: a
# Start menu shortcut, an uninstaller) and Pads-<version>-windows-x86_64.zip
# (the same files) in .build/release, in Git Bash on Windows. Unsigned for
# now (signing is on the roadmap): SmartScreen asks once.
#
#   ./scripts/release/windows.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
W="$OUT/windows"
rm -rf "$W"
mkdir -p "$W/Pads"
# Its icon, in the .exe; a window app (no console).
cat > "$W/pads.rc" <<RC
1 ICON "$(cygpath -m "$ROOT/apps/pads/assets/icon.ico")"
RC
EXTRA_BUILD="-resource:$(cygpath -m "$W/pads.rc") -subsystem:windows" build_pads "$W/Pads/Pads.exe"
collect_licenses "$W/Pads/LICENSES"
[ -e "$NOTES" ] && cp "$NOTES" "$W/Pads/Release notes.md"
cat > "$W/pads.iss" <<ISS
[Setup]
AppId={{7B1E2C6A-3F4D-4C1B-9E8A-50A1D2C3E4F5}
AppName=Pads
AppVersion=$VERSION
AppVerName=Pads $VERSION
AppPublisher=Fire Engine
AppPublisherURL=https://github.com/bcrowe306/fire_engine
DefaultDirName={autopf}\\Pads
DefaultGroupName=Pads
UninstallDisplayIcon={app}\\Pads.exe
LicenseFile=$(cygpath -w "$ROOT/apps/pads/LICENSE")
SetupIconFile=$(cygpath -w "$ROOT/apps/pads/assets/icon.ico")
OutputDir=$(cygpath -w "$OUT")
OutputBaseFilename=Pads-$VERSION-windows-x86_64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
PrivilegesRequiredOverridesAllowed=dialog

[Files]
Source: "$(cygpath -w "$W/Pads")\\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\\Pads"; Filename: "{app}\\Pads.exe"
Name: "{group}\\Uninstall Pads"; Filename: "{uninstallexe}"
Name: "{autodesktop}\\Pads"; Filename: "{app}\\Pads.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "A desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\\Pads.exe"; Description: "Open Pads"; Flags: nowait postinstall skipifsilent
ISS
ISCC="${ISCC:-}"
for c in "$ISCC" "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe" "$LOCALAPPDATA/Programs/Inno Setup 6/ISCC.exe"; do
	if [ -n "$c" ] && [ -e "$c" ]; then ISCC="$c"; break; fi
done
"$ISCC" /Q "$(cygpath -w "$W/pads.iss")"
echo "made $OUT/Pads-$VERSION-windows-x86_64-setup.exe"
ZIP="$OUT/Pads-$VERSION-windows-x86_64.zip"
rm -f "$ZIP"
powershell -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$W/Pads")' -DestinationPath '$(cygpath -w "$ZIP")'"
echo "made $ZIP"
