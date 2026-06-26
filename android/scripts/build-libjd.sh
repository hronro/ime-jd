#!/bin/sh
# Build the native libraries for the Android app, one slice per ABI:
#   1. zig cross-compiles the shared engine  -> libjd.so      (per ABI)
#   2. NDK clang links the C JNI shim against -> libjdjni.so   (per ABI, NEEDED: libjd.so)
# Both land in app/src/main/jniLibs/<abi>/, which Gradle packages as-is (no
# CMake / externalNativeBuild). Mirrors ios/scripts/build-libjd.sh.
#
# Why the dynamic libjd.so and not the static libjd.a: the static archive is
# built PIE with local-exec TLS (std.heap.smp_allocator's thread_index), whose
# R_AARCH64_TLSLE_* relocations ld.lld rejects inside a -shared object. The
# dynamic lib uses a shared-compatible TLS model, so we link against it and ship
# both .so files (Engine loads libjd first, then libjdjni).
#
# Usage: scripts/build-libjd.sh [abi ...]   (default: arm64-v8a x86_64)
# Env:   ANDROID_HOME / ANDROID_NDK_HOME, MIN_SDK (default 24), OPT (default ReleaseSmall)

set -eu

ANDROID_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CORE_DIR=$(CDPATH= cd -- "$ANDROID_DIR/../core" && pwd)
JNILIBS_DIR="$ANDROID_DIR/app/src/main/jniLibs"
SHIM="$ANDROID_DIR/app/src/main/cpp/jd_jni.c"

ABIS="${*:-arm64-v8a x86_64}"
MIN_SDK="${MIN_SDK:-24}"
OPT="-Doptimize=${OPT:-ReleaseSmall}"

# --- locate zig (Gradle's daemon may not inherit an interactive PATH) ---
if ! command -v zig >/dev/null 2>&1; then
    for cand in /opt/homebrew/bin/zig /usr/local/bin/zig "$HOME/.local/bin/zig"; do
        [ -x "$cand" ] && { PATH="$(dirname "$cand"):$PATH"; export PATH; break; }
    done
fi
command -v zig >/dev/null 2>&1 || { echo "error: zig not found on PATH" >&2; exit 1; }

# --- locate the NDK ---
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
NDK="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK" ]; then
    # newest installed side-by-side NDK
    NDK=$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)
fi
[ -n "$NDK" ] && [ -d "$NDK" ] || { echo "error: NDK not found (set ANDROID_NDK_HOME)" >&2; exit 1; }

HOST_TAG=$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)
TOOLBIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
CLANG="$TOOLBIN/clang"
STRIP="$TOOLBIN/llvm-strip"

echo "zig:  $(command -v zig) ($(zig version))"
echo "ndk:  $NDK ($HOST_TAG)"

for abi in $ABIS; do
    case "$abi" in
        arm64-v8a)   zig_target="aarch64-linux-android"   ; clang_target="aarch64-linux-android$MIN_SDK" ;;
        x86_64)      zig_target="x86_64-linux-android"     ; clang_target="x86_64-linux-android$MIN_SDK" ;;
        armeabi-v7a) zig_target="arm-linux-androideabi"    ; clang_target="armv7a-linux-androideabi$MIN_SDK" ;;
        x86)         zig_target="x86-linux-android"        ; clang_target="i686-linux-android$MIN_SDK" ;;
        *) echo "error: unsupported ABI '$abi'" >&2; exit 1 ;;
    esac

    echo "=== $abi ==="
    prefix="$CORE_DIR/zig-out/android/$abi"

    # 1. Core engine -> libjd.so
    ( cd "$CORE_DIR" && zig build -Dtarget="$zig_target" "$OPT" --prefix "$prefix" )

    # 2. JNI shim -> libjdjni.so, linked against the dynamic libjd.so
    out="$JNILIBS_DIR/$abi"
    mkdir -p "$out"
    cp "$prefix/lib/libjd.so" "$out/libjd.so"
    "$CLANG" --target="$clang_target" -shared -fPIC -O2 \
        -I"$CORE_DIR/include" \
        "$SHIM" -L"$prefix/lib" -ljd \
        -o "$out/libjdjni.so"

    # Trim symbols (keep dynamic/exported) — the project values small binaries.
    "$STRIP" --strip-unneeded "$out/libjd.so" "$out/libjdjni.so" 2>/dev/null || true

    echo "  -> $out/{libjd.so,libjdjni.so}"
done

echo "done."
