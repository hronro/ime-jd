#!/bin/sh
# Writes 键道's AUR package for release <tag>, a PKGBUILD and its .SRCINFO, to
# <out>. One split package, ime-jd-bin, makes ime-jd-fcitx5-bin,
# ime-jd-ibus-bin and ime-jd-userdict-bin out of the release's own Arch
# packages (linux/packaging/build.sh), for x86_64 and aarch64, checked against
# the SHA-256 of the assets in <assets>: the same files, under the names the
# AUR gives packages it builds from binaries.
#
# Usage: linux/repo/aur.sh <tag> <assets> <out>
#
# For Arch, whose makepkg writes .SRCINFO; as root, it runs it as nobody.
set -eu

tag=$1
assets=$(cd "$2" && pwd)
out=$(mkdir -p "$3" && cd "$3" && pwd)

# The SHA-256 of the release's three Arch packages for <arch>, quoted.
sums() {
    for frontend in fcitx5 ibus userdict; do
        printf " '%s'" "$(sha256sum "$assets/jd-ime-$tag-linux-$1-$frontend.pkg.tar.zst" | cut -d' ' -f1)"
    done
}

cat > "$out/PKGBUILD" <<EOF
# Maintainer: hronro <hronro@gmail.com>
#
# Written for each release by linux/repo/aur.sh in
# https://github.com/hronro/ime-jd: change that, not this.

pkgbase=ime-jd-bin
pkgname=(ime-jd-fcitx5-bin ime-jd-ibus-bin ime-jd-userdict-bin)
pkgver=${tag#v}
pkgrel=1
pkgdesc='键道输入法, an independent implementation of the 键道 (xkjd) input scheme'
arch=(x86_64 aarch64)
url=https://github.com/hronro/ime-jd
license=(GPL-3.0-or-later)
options=(!strip !debug)
_assets=https://github.com/hronro/ime-jd/releases/download/v\$pkgver/jd-ime-v\$pkgver-linux
source_x86_64=("\$_assets-x86_64-"{fcitx5,ibus,userdict}.pkg.tar.zst)
source_aarch64=("\$_assets-arm64-"{fcitx5,ibus,userdict}.pkg.tar.zst)
noextract=(jd-ime-v\$pkgver-linux-{x86_64,arm64}-{fcitx5,ibus,userdict}.pkg.tar.zst)
sha256sums_x86_64=($(sums x86_64) )
sha256sums_aarch64=($(sums arm64) )

# The release's Arch package for <frontend>, without its pacman metadata.
_unpack() {
    local arch=\$CARCH
    [[ \$arch == aarch64 ]] && arch=arm64
    bsdtar -xf "\$srcdir/jd-ime-v\$pkgver-linux-\$arch-\$1.pkg.tar.zst" -C "\$pkgdir" --exclude '.*'
}

package_ime-jd-fcitx5-bin() {
    pkgdesc='键道输入法 for Fcitx 5'
    depends=('fcitx5>=5.0.14')
    optdepends=('ime-jd-userdict-bin: the window that edits the user dictionary')
    provides=(ime-jd-fcitx5)
    conflicts=(ime-jd-fcitx5)
    _unpack fcitx5
}

package_ime-jd-ibus-bin() {
    pkgdesc='键道输入法 for IBus'
    depends=('ibus>=1.5.26' gcc-libs)
    optdepends=('ime-jd-userdict-bin: the window that edits the user dictionary')
    provides=(ime-jd-ibus)
    conflicts=(ime-jd-ibus)
    _unpack ibus
}

package_ime-jd-userdict-bin() {
    pkgdesc="键道用户自造词, the window that edits 键道's user dictionary"
    depends=('gtk4>=4.6')
    provides=(ime-jd-userdict)
    conflicts=(ime-jd-userdict)
    _unpack userdict
}
EOF

# makepkg wants a directory it may write to, even for this.
build=$(mktemp -d)
cp "$out/PKGBUILD" "$build/"
if [ "$(id -u)" -eq 0 ]; then
    chown -R nobody "$build"
    (cd "$build" && runuser -u nobody -- makepkg --printsrcinfo) > "$out/.SRCINFO"
else
    (cd "$build" && makepkg --printsrcinfo) > "$out/.SRCINFO"
fi
rm -r "$build"
