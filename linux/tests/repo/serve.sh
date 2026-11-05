#!/bin/sh
# Serves 键道's package repositories on this machine as ime-jd-repo.hronro.com
# serves them: the Worker (linux/repo/worker.js), under Node, on <port>, in
# front of github.py standing in for GitHub on the next port, with <branch>
# the packages branch's tree and <assets> the releases' (assets.sh). Runs
# until stopped.
#
# Usage: linux/tests/repo/serve.sh <port> <branch> <assets>
set -eu

here=$(dirname "$(readlink -f "$0")")
github=$(($1 + 1))

python3 "$here/github.py" "$github" "$3" "$2" &
servers=$!
node "$here/worker.mjs" "$1" "http://127.0.0.1:$github" &
servers="$servers $!"
# shellcheck disable=SC2086
trap 'kill $servers 2>/dev/null' EXIT INT TERM
wait
