#!/bin/sh
# Build and package the JdIME input method as a .pkg installer.
#
# Usage:
#   scripts/build-pkg.sh                 build for the host's native arch (default)
#   scripts/build-pkg.sh --universal     build a universal (arm64 + x86_64) binary
#   scripts/build-pkg.sh --libjd <path>  link a prebuilt libjd.a instead of
#                                        building it from source with zig (it
#                                        must cover the arch(es) being built)
#
# Output: build/pkg/jd-ime-macos-<label>.pkg
#   <label> is the native arch ("arm64" | "x86_64") or "universal".
#
# Per-arch is the default because the bundle is ~96% embedded trie (read-only
# data); a universal binary ships that trie twice and roughly doubles the .pkg
# for no benefit when each machine only needs its own slice.

set -eu

INVOKE_DIR="$(pwd)"
cd "$(dirname "$0")/.."

UNIVERSAL=false
LIBJD_A=""
while [ $# -gt 0 ]; do
    case "$1" in
        --universal) UNIVERSAL=true ;;
        --libjd) shift; [ $# -gt 0 ] || { echo "--libjd needs a path" >&2; exit 1; }; LIBJD_A="$1" ;;
        --libjd=*) LIBJD_A="${1#--libjd=}" ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

# A relative --libjd path is resolved against the caller's directory (we have
# since cd'd into macos/).
if [ -n "$LIBJD_A" ]; then
    case "$LIBJD_A" in
        /*) ;;
        *) LIBJD_A="$INVOKE_DIR/$LIBJD_A" ;;
    esac
fi

if $UNIVERSAL; then
    BUILD_ARCHS="arm64 x86_64"
    HOST_ARCHS="arm64,x86_64"
    LABEL="universal"
else
    case "$(uname -m)" in
        arm64)  BUILD_ARCHS="arm64" ;;
        x86_64) BUILD_ARCHS="x86_64" ;;
        *) echo "unsupported host arch: $(uname -m)" >&2; exit 1 ;;
    esac
    HOST_ARCHS="$BUILD_ARCHS"
    LABEL="$BUILD_ARCHS"
fi

command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }

# Single source of truth for the version: core/build.zig.zon's `.version`.
# It's forwarded to xcodebuild as MARKETING_VERSION (the Info.plist's
# CFBundleShortVersionString is $(MARKETING_VERSION)), so the .app and the .pkg
# both carry it. project.yml's MARKETING_VERSION is a deliberate `0.0.0`
# placeholder for plain Xcode/IDE builds.
CORE_VERSION=$(sed -n 's/.*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' ../core/build.zig.zon | head -n1)
[ -n "$CORE_VERSION" ] || { echo "could not read .version from ../core/build.zig.zon" >&2; exit 1; }
echo "==> Version (from core/build.zig.zon): $CORE_VERSION"

echo "==> Generating Xcode project..."
xcodegen generate >/dev/null

if [ -n "$LIBJD_A" ]; then
    echo "==> Using prebuilt libjd: $LIBJD_A"
fi

# LIBJD_A is forwarded as a build setting so the "Build libjd" Run Script Phase
# (scripts/build-libjd.sh) sees it; empty means "build from source with zig".
echo "==> Building JdIME.app (Release, archs: $BUILD_ARCHS)..."
xcodebuild \
    -project JdIME.xcodeproj \
    -scheme JdIME \
    -configuration Release \
    -derivedDataPath build \
    ARCHS="$BUILD_ARCHS" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$CORE_VERSION" \
    LIBJD_A="$LIBJD_A" \
    clean build >/dev/null

APP_PATH="build/Build/Products/Release/JdIME.app"
[ -d "$APP_PATH" ] || { echo "build did not produce $APP_PATH" >&2; exit 1; }

VERSION="$CORE_VERSION"
IDENT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")

OUT_DIR="build/pkg"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$OUT_DIR"

# Stage at /Library/Input Methods/ — system-wide install (standard for macOS
# IMEs, e.g. Rime, Squirrel). Requires admin password at install time but
# makes the IME available to every user on the machine.
mkdir -p "$STAGE_DIR/Library/Input Methods"
cp -R "$APP_PATH" "$STAGE_DIR/Library/Input Methods/"

echo "==> pkgbuild..."
pkgbuild \
    --root "$STAGE_DIR" \
    --identifier "$IDENT.pkg" \
    --version "$VERSION" \
    --install-location "/" \
    --scripts scripts/pkg \
    "$OUT_DIR/JdIME-component.pkg"

# Render distribution.xml with version, identifier, and the arch(es) this pkg
# is allowed to install on (hostArchitectures) baked in.
DIST_RENDERED="$STAGE_DIR/distribution.xml"
sed \
    -e "s|@VERSION@|$VERSION|g" \
    -e "s|@IDENT@|$IDENT.pkg|g" \
    -e "s|@ARCHS@|$HOST_ARCHS|g" \
    scripts/pkg/distribution.xml > "$DIST_RENDERED"

PKG_OUT="$OUT_DIR/jd-ime-macos-$LABEL.pkg"
echo "==> productbuild..."
productbuild \
    --distribution "$DIST_RENDERED" \
    --resources scripts/pkg \
    --package-path "$OUT_DIR" \
    "$PKG_OUT"

rm -f "$OUT_DIR/JdIME-component.pkg"
echo "built $PKG_OUT"

# Optional signing (uncomment and configure the identity for distribution):
# productsign --sign "Developer ID Installer: <Your Name> (TEAMID)" \
#     "$PKG_OUT" "${PKG_OUT%.pkg}-signed.pkg"
