#!/bin/sh
# Lays the packages in each <dist>, as linux/packaging/build.sh names them,
# out as GitHub Releases has them: <out>/<tag>/<asset>, the tag read from the
# name.
#
# Usage: linux/tests/repo/assets.sh <out> <dist>...
set -eu

out=$1
shift
for dist in "$@"; do
    for file in "$dist"/jd-ime-v*; do
        [ -e "$file" ] || continue
        name=$(basename "$file")
        tag=${name#jd-ime-}
        tag=${tag%%-*}
        mkdir -p "$out/$tag"
        ln -f "$file" "$out/$tag/$name" 2>/dev/null || cp "$file" "$out/$tag/$name"
    done
done
