#!/bin/sh
# Installs 键道's packages from <dir> — the release assets
# linux/packaging/build.sh made, one per framework and the user-dictionary
# editor — the way a user would on this distro: with its package manager,
# which brings the frameworks and GTK 4 they depend on. With `tarball`, from
# the generic tarball and its install.sh instead.
#
# Usage: linux/scripts/install-packages.sh <dir> [tarball]
set -eu

dir=$(cd "$1" && pwd)

if [ "${2:-}" = tarball ]; then
    work=$(mktemp -d)
    set -- "$dir"/jd-ime-v*-linux-*.tar.xz
    tar -xJf "$1" -C "$work"
    set -- "$work"/jd-ime-v*/install.sh
    "$1"
    exit
fi

# shellcheck source=/dev/null
. /etc/os-release
case $ID in
ubuntu | debian)
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        "$dir"/*-fcitx5.deb "$dir"/*-ibus.deb "$dir"/*-userdict.deb
    ;;
fedora)
    dnf install -y -q "$dir"/*-fcitx5.rpm "$dir"/*-ibus.rpm "$dir"/*-userdict.rpm
    ;;
opensuse-*)
    # Not signed with a key zypper knows.
    zypper --non-interactive --quiet install --allow-unsigned-rpm \
        "$dir"/*-fcitx5.rpm "$dir"/*-ibus.rpm "$dir"/*-userdict.rpm
    ;;
arch)
    pacman -Sy --noconfirm
    pacman -U --noconfirm "$dir"/*-fcitx5.pkg.tar.zst "$dir"/*-ibus.pkg.tar.zst "$dir"/*-userdict.pkg.tar.zst
    ;;
alpine)
    # Not signed with a key apk knows.
    apk add --no-cache --allow-untrusted "$dir"/*-fcitx5.apk "$dir"/*-ibus.apk "$dir"/*-userdict.apk
    ;;
*)
    echo "$0: no package format for $ID" >&2
    exit 1
    ;;
esac
