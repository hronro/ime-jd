#!/bin/sh
# Installs, with the distro's package manager, what building 键道's Linux
# frontends and user-dictionary editor needs (`build`), and what running them
# end to end needs (`test`): the frameworks, D-Bus, PyGObject with IBus's
# introspection data, GTK 4 for the editor, and xz for the tarball. For the
# containers CI builds and tests in, and for reproducing them.
#
# Usage: linux/scripts/install-deps.sh build|test...
set -eu

build=false
test=false
for what in "$@"; do
    case $what in
    build) build=true ;;
    test) test=true ;;
    *) echo "usage: $0 build|test..." >&2; exit 1 ;;
    esac
done

# Picks the lists this run asked for.
pick() {
    if $build; then echo "$1"; fi
    if $test; then echo "$2"; fi
}

# shellcheck source=/dev/null
. /etc/os-release
case $ID in
ubuntu | debian)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # shellcheck disable=SC2046
    apt-get install -y -qq --no-install-recommends $(pick \
        "g++ meson ninja-build pkg-config libfcitx5core-dev fcitx5-modules-dev libibus-1.0-dev valac libgtk-4-dev xz-utils" \
        "fcitx5 ibus dbus python3-gi gir1.2-ibus-1.0 libgtk-4-1 xz-utils")
    ;;
fedora)
    # shellcheck disable=SC2046
    dnf install -y -q $(pick \
        "gcc-c++ meson ninja-build pkgconf fcitx5-devel ibus-devel vala gtk4-devel xz" \
        "fcitx5 ibus dbus-daemon dbus-tools python3-gobject gtk4 xz")
    ;;
opensuse-*)
    # shellcheck disable=SC2046
    zypper --non-interactive --quiet install $(pick \
        "gcc-c++ meson ninja pkgconf fcitx5-devel ibus-devel vala gtk4-devel xz" \
        "fcitx5 ibus dbus-1-daemon python3-gobject typelib-1_0-IBus-1_0 libgtk-4-1 xz")
    ;;
arch)
    # shellcheck disable=SC2046
    pacman -Syu --noconfirm --needed $(pick \
        "gcc meson ninja pkgconf fcitx5 ibus vala gtk4 xz" \
        "fcitx5 ibus dbus python-gobject gtk4 xz")
    ;;
alpine)
    # shellcheck disable=SC2046
    apk add --no-cache $(pick \
        "g++ meson samurai pkgconf fcitx5-dev ibus-dev vala gtk4.0-dev xz" \
        "fcitx5 ibus dbus py3-gobject3 gtk4.0 xz")
    ;;
*)
    echo "$0: no package list for $ID" >&2
    exit 1
    ;;
esac
