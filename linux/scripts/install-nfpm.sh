#!/bin/sh
# Installs nfpm, which linux/packaging/build.sh packages with, into <dir>: a
# pinned release, checked against the SHA-256 it was published with.
#
# Usage: linux/scripts/install-nfpm.sh <dir>
set -eu

version=2.48.0
case $(uname -m) in
x86_64) arch=x86_64 sha256=6d7f9a28b2f397934403950fcbba83f598b08d02edbe79a0815b3b4897341750 ;;
aarch64) arch=arm64 sha256=a9a75213763783b7669719e505474c748c5ad7dc66591a195619deb50f85c2f4 ;;
*) echo "$0: no nfpm release for $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$1"
tarball=$(mktemp)
trap 'rm -f "$tarball"' EXIT
curl -fsSL -o "$tarball" "https://github.com/goreleaser/nfpm/releases/download/v$version/nfpm_${version}_Linux_$arch.tar.gz"
echo "$sha256  $tarball" | sha256sum -c - >/dev/null
tar -xzf "$tarball" -C "$1" nfpm
"$1/nfpm" --version >/dev/null
