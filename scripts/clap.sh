#!/usr/bin/env bash
# Builds the test plug-ins for tests/clap: FireTest.clap, in C against
# CLAP's own headers (vendor/clap), and FireOdin.clap, Odin plug-ins made
# with fire:clap/sdk. In .build/clap (bundles on macOS, shared libraries
# elsewhere). tests/clap skips without them.
#
#   ./scripts/clap.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT=.build/clap
SRC=tests/clap/c_plugin/fire_test_plugin.c
mkdir -p "$OUT"
CC="${CC:-cc}"
case "$(uname -s)" in
Darwin)
	B="$OUT/FireTest.clap/Contents"
	mkdir -p "$B/MacOS"
	"$CC" -O2 -Wall -fvisibility=hidden -bundle -Ivendor/clap/include "$SRC" -o "$B/MacOS/FireTest"
	cat > "$B/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>FireTest</string>
	<key>CFBundleIdentifier</key><string>dev.fire-engine.test</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
	;;
MINGW*|MSYS*)
	if command -v clang > /dev/null; then
		clang -O2 -Wall -shared -Ivendor/clap/include "$SRC" -o "$OUT/FireTest.clap"
	else
		# MSVC: find Visual Studio, set up its environment, build a DLL.
		VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
		VS="$("$VSWHERE" -latest -products '*' -property installationPath | tr -d '\r')"
		BAT="$(mktemp -d)/build.bat"
		cat > "$BAT" <<BATCH
@call "$VS\\VC\\Auxiliary\\Build\\vcvars64.bat" > nul
cl /nologo /O2 /W3 /D_CRT_SECURE_NO_WARNINGS /LD /Ivendor\\clap\\include tests\\clap\\c_plugin\\fire_test_plugin.c /Fe:$OUT\\FireTest.dll /Fo:$OUT\\
BATCH
		cmd //c "$(cygpath -w "$BAT")"
		mv -f "$OUT/FireTest.dll" "$OUT/FireTest.clap"
	fi
	;;
*)
	"$CC" -O2 -Wall -fvisibility=hidden -shared -fPIC -Ivendor/clap/include "$SRC" -o "$OUT/FireTest.clap" -lm
	;;
esac
# The Odin plug-ins.
ODIN_SRC=tests/clap/odin_plugin
case "$(uname -s)" in
Darwin)
	B="$OUT/FireOdin.clap/Contents"
	mkdir -p "$B/MacOS"
	odin build "$ODIN_SRC" -collection:fire=f_engine -build-mode:shared -o:speed -out:"$B/MacOS/FireOdin.dylib"
	mv -f "$B/MacOS/FireOdin.dylib" "$B/MacOS/FireOdin" # a bundle's executable has no extension
	sed -e 's/FireTest/FireOdin/g' -e 's/dev.fire-engine.test/dev.fire-engine.odin/' "$OUT/FireTest.clap/Contents/Info.plist" > "$B/Info.plist"
	;;
MINGW*|MSYS*)
	odin build "$ODIN_SRC" -collection:fire=f_engine -build-mode:shared -o:speed -out:"$OUT/FireOdin.dll"
	mv -f "$OUT/FireOdin.dll" "$OUT/FireOdin.clap"
	;;
*)
	odin build "$ODIN_SRC" -collection:fire=f_engine -build-mode:shared -o:speed -out:"$OUT/FireOdin.so"
	mv -f "$OUT/FireOdin.so" "$OUT/FireOdin.clap"
	;;
esac
echo "built $OUT/FireTest.clap and $OUT/FireOdin.clap"
