#!/bin/sh
# Installs 键道's packages from <dir> — the release assets
# linux/packaging/build.sh made, one per framework and the user-dictionary
# editor — the way a user would on this distro: with its package manager,
# which brings the frameworks and GTK 4 they depend on. With `tarball`, from
# the generic tarball and its install.sh instead. With --repository, from the
# package repositories at <url> (linux/repo), added as the README says.
#
# Usage: linux/scripts/install-packages.sh <dir> [tarball]
#        linux/scripts/install-packages.sh --repository <url>
set -eu

if [ "$1" = --repository ]; then
    url=$2
    # shellcheck source=/dev/null
    . /etc/os-release
    case $ID in
    ubuntu | debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends ca-certificates wget
        wget -qO /usr/share/keyrings/ime-jd.gpg "$url/ime-jd.gpg"
        echo "deb [signed-by=/usr/share/keyrings/ime-jd.gpg] $url/apt stable main" > /etc/apt/sources.list.d/ime-jd.list
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends ime-jd-fcitx5 ime-jd-ibus ime-jd-userdict
        ;;
    fedora)
        curl -fsSLo /etc/yum.repos.d/ime-jd.repo "$url/rpm/ime-jd.repo"
        dnf install -y -q ime-jd-fcitx5 ime-jd-ibus ime-jd-userdict
        ;;
    opensuse-*)
        zypper --non-interactive --quiet addrepo "$url/rpm/ime-jd.repo"
        # The key's prompt, answered as a user who checked its fingerprint.
        zypper --non-interactive --quiet --gpg-auto-import-keys install ime-jd-fcitx5 ime-jd-ibus ime-jd-userdict
        ;;
    alpine)
        wget -qO /etc/apk/keys/ime-jd.rsa.pub "$url/ime-jd.rsa.pub"
        echo "$url/alpine" >> /etc/apk/repositories
        apk add --no-cache ime-jd-fcitx5 ime-jd-ibus ime-jd-userdict
        ;;
    *)
        echo "$0: no repository for $ID" >&2
        exit 1
        ;;
    esac
    exit
fi

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
    # Not signed with a key zypper knows: that is the repository's.
    zypper --non-interactive --quiet --no-gpg-checks install \
        "$dir"/*-fcitx5.rpm "$dir"/*-ibus.rpm "$dir"/*-userdict.rpm
    ;;
arch)
    # The whole system brought up to date first: Arch supports no partial
    # upgrades, and dependencies from a newer database than an image's
    # packages can conflict with them.
    pacman -Syu --noconfirm
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
