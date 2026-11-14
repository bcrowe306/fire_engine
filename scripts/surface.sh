#!/usr/bin/env bash
# Builds the C control-surface scripts: tests/surface's, against
# f_engine/surface/fire_surface.h (.build/surface/mini.(dylib|so|dll)), and
# the Pads example examples/pads_surface (pads_mini.*, for tests/pads_api_c).
# Those tests skip without them.
#
#   ./scripts/surface.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT=.build/surface
mkdir -p "$OUT"
build() { # build SOURCE NAME
	local SRC="$1" NAME="$2"
case "$(uname -s)" in
Darwin) "${CC:-cc}" -O2 -Wall -fvisibility=hidden -dynamiclib "$SRC" -o "$OUT/$NAME.dylib" ;;
MINGW*|MSYS*)
	if command -v clang > /dev/null; then
		clang -O2 -Wall -shared "$SRC" -o "$OUT/$NAME.dll"
	else
		VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
		VS="$("$VSWHERE" -latest -products '*' -property installationPath | tr -d '\r')"
		BAT="$(mktemp -d)/build.bat"
		cat > "$BAT" <<BATCH
@call "$VS\\VC\\Auxiliary\\Build\\vcvars64.bat" > nul
cl /nologo /O2 /W3 /LD $(cygpath -w "$SRC") /Fe:$OUT\\$NAME.dll /Fo:$OUT\\
BATCH
		cmd //c "$(cygpath -w "$BAT")"
	fi
	;;
*) "${CC:-cc}" -O2 -Wall -fvisibility=hidden -shared -fPIC "$SRC" -o "$OUT/$NAME.so" ;;
esac
}
build tests/surface/c_script/mini.c mini
build examples/pads_surface/pads_mini.c pads_mini
echo "built $OUT"
