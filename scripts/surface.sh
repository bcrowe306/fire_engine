#!/usr/bin/env bash
# Builds the C control-surface script for tests/surface, against
# f_engine/surface/fire_surface.h: .build/surface/mini.(dylib|so|dll).
# tests/surface skips without it.
#
#   ./scripts/surface.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT=.build/surface
SRC=tests/surface/c_script/mini.c
mkdir -p "$OUT"
case "$(uname -s)" in
Darwin) "${CC:-cc}" -O2 -Wall -fvisibility=hidden -dynamiclib "$SRC" -o "$OUT/mini.dylib" ;;
MINGW*|MSYS*)
	if command -v clang > /dev/null; then
		clang -O2 -Wall -shared "$SRC" -o "$OUT/mini.dll"
	else
		VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
		VS="$("$VSWHERE" -latest -products '*' -property installationPath | tr -d '\r')"
		BAT="$(mktemp -d)/build.bat"
		cat > "$BAT" <<BATCH
@call "$VS\\VC\\Auxiliary\\Build\\vcvars64.bat" > nul
cl /nologo /O2 /W3 /LD tests\\surface\\c_script\\mini.c /Fe:$OUT\\mini.dll /Fo:$OUT\\
BATCH
		cmd //c "$(cygpath -w "$BAT")"
	fi
	;;
*) "${CC:-cc}" -O2 -Wall -fvisibility=hidden -shared -fPIC "$SRC" -o "$OUT/mini.so" ;;
esac
echo "built $OUT"
