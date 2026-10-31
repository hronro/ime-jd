#!/bin/sh
# Builds 键道's Linux release assets. What they are for depends on where this
# runs:
#
#   glibc — Ubuntu 22.04, the oldest release builds target, so they run on
#   every newer distro: a .deb, an .rpm and an Arch package for each
#   framework and for the user-dictionary editor, and the generic tarball,
#   which installs all three at fixed paths.
#
#   musl — Alpine 3.22, likewise: an .apk for each.
#
# Usage: linux/packaging/build.sh <out-dir> [libjd.a]
#
# Without libjd.a, Meson builds it with Zig. nfpm (https://nfpm.goreleaser.com)
# is $NFPM, or the one on PATH. Each framework's package is its frontend and
# depends on that framework; the editor's depends on GTK 4, and the two
# recommend it. The package managers install the rest from there.
set -eu

out=$(mkdir -p "$1" && cd "$1" && pwd)
libjd=${2:+$(cd "$(dirname "$2")" && pwd)/$(basename "$2")}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
nfpm=${NFPM:-nfpm}

version=$(sed -n 's/^[[:space:]]*\.version = "\([0-9.]*\)",$/\1/p' "$root/core/build.zig.zon")
[ -n "$version" ] || { echo "no version in core/build.zig.zon" >&2; exit 1; }

case $(uname -m) in
x86_64) nfpm_arch=amd64 asset_arch=x86_64 multiarch=x86_64-linux-gnu ;;
aarch64) nfpm_arch=arm64 asset_arch=arm64 multiarch=aarch64-linux-gnu ;;
*) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# The assets' platform: Alpine's packages say so, as an .apk beside the
# Android app's on the release page would otherwise pass for one.
if [ -e /etc/alpine-release ]; then
    formats=apk platform=alpine
else
    formats="deb rpm archlinux" platform=linux
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---- Build once, test, stage ----

meson setup "$work/build" "$root/linux" --prefix=/usr --buildtype=release \
    -Dfcitx5=enabled -Dibus=enabled -Deditor=enabled ${libjd:+-Dlibjd="$libjd"}
meson compile -C "$work/build"
meson test -C "$work/build" --print-errorlogs

# The packages' layout: Fcitx 5's addon directory as this system has it,
# moved to each distro's below; the IBus engine in /usr/libexec.
DESTDIR="$work/pkg" meson install -C "$work/build" --quiet
addon=$(find "$work/pkg" -name libime-jd.so)

# The tarball's: the same everywhere, so it can install without knowing the
# distro. Fcitx 5 loads the addon from its absolute path.
if [ "$formats" != apk ]; then
    meson configure "$work/build" -Dfcitx5_addon_dir=/usr/lib/ime-jd -Dibus_engine_dir=/usr/lib/ime-jd
    DESTDIR="$work/tar" meson install -C "$work/build" --quiet
fi

# ---- Packages ----

# The editor's application ID, which names its desktop entry and icon.
editor_id=io.github.hronro.ImeJd.UserDict
desktop_entry=/usr/share/applications/$editor_id.desktop

# Where Fcitx 5 loads addons from, in each format's distros.
addon_dir() {
    case $1 in
    deb) echo "/usr/lib/$multiarch/fcitx5" ;;
    rpm) echo /usr/lib64/fcitx5 ;;
    archlinux | apk) echo /usr/lib/fcitx5 ;;
    esac
}

# `name (>= version)` in each format's spelling.
requirement() {
    case $3 in
    deb) echo "$1 (>= $2)" ;;
    rpm) echo "$1 >= $2" ;;
    archlinux | apk) echo "$1>=$2" ;;
    esac
}

# GTK 4, for the editor: 4.6 is what it is built against here. RPM distros
# name its package differently (gtk4 on Fedora, libgtk-4-1 on openSUSE), so
# the .rpm asks for the library itself. Alpine's leaves out the GLES library
# its renderer loads at start, and without which a GTK 4 window aborts:
# mesa-gles.
gtk4() {
    case $1 in
    deb) echo "libgtk-4-1 (>= 4.6)" ;;
    rpm) echo "libgtk-4.so.1()(64bit)" ;;
    archlinux) echo "gtk4>=4.6" ;;
    apk) printf '%s\n' "gtk4.0>=4.6" mesa-gles ;;
    esac
}

# The C++ runtime the IBus engine needs. Fcitx 5 brings it for the addon,
# but IBus is C and may not, Alpine's least of all. RPM distros name its
# package differently (libstdc++ on Fedora, libstdc++6 on openSUSE), so the
# .rpm asks for the library itself.
cxx_runtime() {
    case $1 in
    deb) echo libstdc++6 ;;
    rpm) echo "libstdc++.so.6()(64bit)" ;;
    archlinux) echo gcc-libs ;;
    apk) echo libstdc++ ;;
    esac
}

entry() {
    printf '  - src: %s\n    dst: %s\n    file_info:\n      mode: %s\n' "$1" "$2" "${3:-0644}"
}

contents() {
    frontend=$1 format=$2
    case $frontend in
    fcitx5)
        entry "$addon" "$(addon_dir "$format")/libime-jd.so"
        entry "$work/pkg/usr/share/fcitx5/addon/ime-jd.conf" /usr/share/fcitx5/addon/ime-jd.conf
        entry "$work/pkg/usr/share/fcitx5/inputmethod/ime-jd.conf" /usr/share/fcitx5/inputmethod/ime-jd.conf
        for size in scalable 16x16 22x22 24x24 32x32; do
            icon=/usr/share/icons/hicolor/$size/apps/fcitx-ime-jd.svg
            entry "$work/pkg$icon" "$icon"
        done
        ;;
    ibus)
        entry "$work/pkg/usr/libexec/ibus-engine-ime-jd" /usr/libexec/ibus-engine-ime-jd 0755
        entry "$work/pkg/usr/share/ibus/component/ime-jd.xml" /usr/share/ibus/component/ime-jd.xml
        entry "$work/pkg/usr/share/ibus-ime-jd/icons/ime-jd.svg" /usr/share/ibus-ime-jd/icons/ime-jd.svg
        ;;
    userdict)
        entry "$work/pkg/usr/bin/ime-jd-userdict" /usr/bin/ime-jd-userdict 0755
        entry "$work/pkg$desktop_entry" "$desktop_entry"
        for size in scalable 16x16 22x22 24x24 32x32; do
            icon=/usr/share/icons/hicolor/$size/apps/$editor_id.svg
            entry "$work/pkg$icon" "$icon"
        done
        ;;
    esac
    if [ "$format" = deb ]; then
        entry "$root/LICENSE" "/usr/share/doc/ime-jd-$frontend/copyright"
    fi
}

config() {
    frontend=$1 format=$2
    # Recommended: an .apk has no such field, and nfpm leaves it out.
    recommends=ime-jd-userdict
    case $frontend in
    fcitx5)
        depends=$(requirement fcitx5 5.0.14 "$format")
        description="键道输入法 for Fcitx 5
An independent implementation of the 键道 (xkjd) input scheme, with its
dictionary built in, as an input method for Fcitx 5. The framework draws
the candidate window and the input method's menu."
        ;;
    ibus)
        depends="$(requirement ibus 1.5.26 "$format")
$(cxx_runtime "$format")"
        description="键道输入法 for IBus
An independent implementation of the 键道 (xkjd) input scheme, with its
dictionary built in, as an input method for IBus. The framework draws the
candidate window and the input method's menu."
        ;;
    userdict)
        depends=$(gtk4 "$format")
        recommends=
        description="键道用户自造词
The window that edits 键道's user dictionary, the phrases the input method
offers beside its own, for both its Fcitx 5 and its IBus frontend. The
input method's menu opens it."
        ;;
    esac
    cat <<EOF
name: ime-jd-$frontend
arch: $nfpm_arch
platform: linux
version: $version
release: 1
section: utils
priority: optional
maintainer: hronro <hronro@gmail.com>
vendor: hronro
homepage: https://github.com/hronro/ime-jd
license: GPL-3.0-or-later
description: |-
$(echo "$description" | sed 's/^/  /')
depends:
$(echo "$depends" | sed 's/.*/  - "&"/')
${recommends:+recommends:
  - $recommends}
contents:
$(contents "$frontend" "$format")
# libjd's dictionary is most of the package, and xz halves what gzip leaves
# of it; every dpkg and rpm these packages are for reads xz.
deb:
  compression: xz
rpm:
  compression: xz
EOF
}

extension() {
    case $1 in
    archlinux) echo pkg.tar.zst ;;
    *) echo "$1" ;;
    esac
}

for frontend in fcitx5 ibus userdict; do
    for format in $formats; do
        config "$frontend" "$format" > "$work/nfpm-$frontend-$format.yaml"
        "$nfpm" package --config "$work/nfpm-$frontend-$format.yaml" --packager "$format" \
            --target "$out/jd-ime-v$version-$platform-$asset_arch-$frontend.$(extension "$format")"
    done
done

# ---- The tarball ----

# The editor's files listed apart, for install.sh to leave out where GTK 4 is
# missing.
if [ "$formats" != apk ]; then
    name=jd-ime-v$version-linux-$asset_arch
    mkdir -p "$work/$name"
    mv "$work/tar" "$work/$name/files"
    (cd "$work/$name/files" && find usr -type f | sort) > "$work/files"
    grep -e /ime-jd-userdict -e "/$editor_id\." "$work/files" > "$work/$name/editor.txt"
    grep -v -e /ime-jd-userdict -e "/$editor_id\." "$work/files" > "$work/$name/files.txt"
    cp "$here/install.sh" "$here/uninstall.sh" "$work/$name/"
    tar -C "$work" --owner=0 --group=0 -cJf "$out/$name.tar.xz" "$name"
fi

ls -l "$out"
