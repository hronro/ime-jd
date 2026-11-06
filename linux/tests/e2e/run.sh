#!/bin/sh
# Runs the end-to-end tests against the installed frontends: each framework
# in a D-Bus session of its own, with a daemon of its own. The editor, whose
# window needs a display, is only started. Where the update check is built —
# the generic tarball — its updater is run against a feed of the test's own.
#
# For a disposable environment — a container — with 键道 and its editor
# installed to /usr, fcitx5, ibus, dbus and python3-gi, and libcurl for the
# updater: it writes the user's ~/.config and ~/.cache.
set -eu

here=$(dirname "$(readlink -f "$0")")
config=${XDG_CONFIG_HOME:-$HOME/.config}
status=0

fresh() {
    rm -rf "$config/ime-jd" "$config/fcitx5" "$config/ibus" "$HOME/.cache/ibus"
    # As a user who switched the update check off: no test asks GitHub.
    mkdir -p "$config/ime-jd"
    printf '[Update]\nCheckAutomatically=false\n' > "$config/ime-jd/settings.ini"
}

echo "== Fcitx 5"
fresh
mkdir -p "$config/fcitx5"
cat > "$config/fcitx5/profile" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=ime-jd

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=ime-jd
Layout=

[GroupOrder]
0=Default
EOF
# No display here, and nothing that would stand in for IBus. The session's
# shell takes this directory as $1. fcitx5 saves its configuration on its way
# out, so it is stopped and waited for, before the next framework's fresh
# start removes that directory.
# shellcheck disable=SC2016
dbus-run-session -- sh -c '
    fcitx5 --disable=wayland,waylandim,xcb,xim,classicui,kimpanel,notificationitem,ibusfrontend,fcitx4frontend \
        >/tmp/fcitx5.log 2>&1 &
    fcitx5=$!
    python3 "$1/fcitx5_test.py"
    tested=$?
    kill "$fcitx5" 2>/dev/null
    wait "$fcitx5"
    exit "$tested"' sh "$here" || { status=1; tail -20 /tmp/fcitx5.log; }

echo "== IBus"
fresh
# IBus names its address file after the machine ID, which containers often
# lack; a fixed one serves the daemon, the engine it starts, and the test.
export IBUS_ADDRESS_FILE="${TMPDIR:-/tmp}/imejd-e2e-ibus-address"
# shellcheck disable=SC2016
dbus-run-session -- sh -c '
    ibus-daemon --daemonize --replace --panel=disable --config=disable >/tmp/ibus.log 2>&1
    exec python3 "$1/ibus_test.py"' sh "$here" || { status=1; tail -20 /tmp/ibus.log; }

echo "== Editor"
# That it runs at all: the libraries it links to, GTK 4 among them, found.
ime-jd-userdict --version || status=1

# Where the tarball installs it, or a build from source with the update check.
for updater in /usr/lib/ime-jd/ime-jd-update /usr/libexec/ime-jd-update; do
    if [ -x "$updater" ]; then
        echo "== Updater"
        fresh
        dbus-run-session -- python3 "$here/update_test.py" "$updater" || status=1
        break
    fi
done

exit $status
