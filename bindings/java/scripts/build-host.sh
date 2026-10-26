#!/bin/sh
# Build libjd and the JNI shim for the machine running this script, so the
# binding's tests run on a plain JVM (the buildHostLibs task in
# build.gradle.kts). Android's per-ABI build is android/scripts/build-libjd.sh.
#   1. zig builds the engine         -> <out>/libjd.{dylib,so}
#   2. zig cc compiles the JNI shim   -> <out>/libjdjni.{dylib,so}, which finds
#                                        libjd next to itself (rpath)
# Like Android's, the shim links the *dynamic* libjd: the static archive uses
# local-exec TLS relocations, which a linker refuses in a shared object.
#
# Usage: scripts/build-host.sh <jni-headers-dir> <out-dir>
#   <jni-headers-dir>  javac -h's output (build/generated/jni): the natives
#                      jd_jni.c implements
# Env:   JNI_INCLUDE -> a JDK's include/ directory (jni.h). Otherwise found in
#                       JAVA_HOME, then in the home of the `java` on PATH. It
#                       takes a JDK, not just a runtime: Android Studio's
#                       bundled JBR has no include/.
#        OPT         -> zig optimize mode (default safe: the tests run with
#                       libjd's runtime safety checks on)

set -eu

JAVA_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_DIR=$(CDPATH= cd -- "$JAVA_DIR/../../core" && pwd)
HEADERS=${1:?usage: build-host.sh <jni-headers-dir> <out-dir>}
OUT=${2:?usage: build-host.sh <jni-headers-dir> <out-dir>}
SHIM="$JAVA_DIR/src/main/c/jd_jni.c"

if [ ! -f "$HEADERS/com_hronro_jd_Jni.h" ]; then
    echo "error: no $HEADERS/com_hronro_jd_Jni.h (javac -h writes it: ./gradlew compileJava)" >&2
    exit 1
fi

# --- locate zig (Gradle's daemon may not inherit an interactive PATH) ---
if ! command -v zig >/dev/null 2>&1; then
    for cand in /opt/homebrew/bin/zig /usr/local/bin/zig "$HOME/.local/bin/zig"; do
        [ -x "$cand" ] && { PATH="$(dirname "$cand"):$PATH"; export PATH; break; }
    done
fi
command -v zig >/dev/null 2>&1 || { echo "error: zig not found on PATH" >&2; exit 1; }

# --- locate jni.h ---
INC="${JNI_INCLUDE:-}"
if [ -z "$INC" ]; then
    path_java_home=""
    if command -v java >/dev/null 2>&1; then
        path_java_home=$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java\.home = //p')
    fi
    for home in "${JAVA_HOME:-}" "$path_java_home"; do
        if [ -n "$home" ] && [ -f "$home/include/jni.h" ]; then
            INC="$home/include"
            break
        fi
    done
fi
if [ -z "$INC" ] || [ ! -f "$INC/jni.h" ]; then
    echo "error: no jni.h in JAVA_HOME (${JAVA_HOME:-unset}) or the java on PATH;" \
        "set JNI_INCLUDE to a JDK's include/ directory" >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin) md=darwin; ext=dylib; origin='@loader_path' ;;
    Linux)  md=linux;  ext=so;    origin='$ORIGIN' ;;
    *) echo "error: unsupported host $(uname -s)" >&2; exit 1 ;;
esac

echo "zig:  $(command -v zig) ($(zig version))"
echo "jni:  $INC"

# 1. Core engine -> libjd
( cd "$CORE_DIR" && zig build -Doptimize="${OPT:-safe}" --prefix "$OUT/libjd" )
cp "$OUT/libjd/lib/libjd.$ext" "$OUT/libjd.$ext"

# 2. JNI shim -> libjdjni, linked against the dynamic libjd
zig cc -shared -fPIC -O2 -Wall -Wextra -Werror=missing-prototypes \
    -I"$INC" -I"$INC/$md" -I"$HEADERS" -I"$CORE_DIR/include" \
    "$SHIM" -L"$OUT" -ljd -Wl,-rpath,"$origin" \
    -o "$OUT/libjdjni.$ext"

echo "  -> $OUT/{libjd,libjdjni}.$ext"
