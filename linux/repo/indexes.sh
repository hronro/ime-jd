#!/bin/sh
# Builds the index files of 键道's package repositories, which the `packages`
# branch holds and the Worker (worker.js) serves at ime-jd-repo.hronro.com,
# from every release's packages:
#
#   apt/      Debian and Ubuntu: one suite, `stable`, for every release of
#             both, as the .deb is built to run on all of them. Its packages
#             are pool/<tag>/<asset>, which the Worker fetches from the
#             release.
#   rpm/      Fedora and openSUSE: one repository, for dnf and zypper alike,
#             its packages packages/<tag>/<asset>; ime-jd.repo describes it.
#   alpine/   Alpine: an index for each arch. apk asks for a package by its
#             name and version, which the Worker turns into the asset's name.
#   ime-jd.asc, ime-jd.gpg, ime-jd.rsa.pub
#             the public keys: OpenPGP, armored and not, for apt and rpm, and
#             RSA for apk.
#
# Usage: linux/repo/indexes.sh apt|rpm|apk <assets> <branch> <out>
#
# <assets> holds every release's packages as <tag>/<asset>, as GitHub
# Releases does. <branch> is the branch as it was, empty the first time: the
# indexes it had stay a while, for caches still holding the files that name
# them. <out> receives the new tree.
#
# apt and rpm want Debian's apt-utils, createrepo-c, gnupg and rpm, and the
# OpenPGP key in the file $GPG_KEY, its passphrase in $GPG_PASSPHRASE; apk
# wants Alpine's abuild and openssl, and the RSA key in the file $APK_KEY.
# $REPO_URL is where the repositories are served,
# https://ime-jd-repo.hronro.com unless set.
set -eu

format=$1
assets=$(cd "$2" && pwd)
branch=$(cd "$3" && pwd)
out=$(mkdir -p "$4" && cd "$4" && pwd)
url=${REPO_URL:-https://ime-jd-repo.hronro.com}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Links every release's <pattern> assets into <dir>/<tag>/.
gather() {
    pattern=$1 dir=$2
    for file in "$assets"/*/$pattern; do
        [ -e "$file" ] || continue
        tag=$(basename "$(dirname "$file")")
        mkdir -p "$dir/$tag"
        ln -s "$file" "$dir/$tag/"
    done
}

# ---- OpenPGP, for apt and rpm ----

gpg_init() {
    GNUPGHOME=$tmp/gnupg
    export GNUPGHOME
    mkdir -m 700 "$GNUPGHOME"
    gpg --batch --quiet --import "$GPG_KEY"
    fingerprint=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr/ { print $10; exit }')
}

# gpg with the key, its passphrase on standard input.
gpg_sign() {
    printf '%s\n' "$GPG_PASSPHRASE" |
        gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --local-user "$fingerprint" "$@"
}

# ---- apt ----

apt_indexes() {
    gpg_init
    work=$tmp/apt
    gather 'jd-ime-v*-linux-*.deb' "$work/pool"
    mkdir -p "$work/pool"
    (cd "$work" && apt-ftparchive packages pool > "$tmp/Packages")

    for arch in amd64 arm64; do
        dir=$work/dists/stable/main/binary-$arch
        mkdir -p "$dir/by-hash/SHA256"
        # Each arch's own: apt-ftparchive tells arches apart by file names,
        # which the assets', named for the release page, are not.
        awk -v arch="$arch" 'BEGIN { RS = ""; ORS = "\n\n" }
            $0 ~ ("(^|\n)Architecture: " arch "(\n|$)") { print }' "$tmp/Packages" > "$dir/Packages"
        gzip -9nk "$dir/Packages"
        xz -k "$dir/Packages"
        # Fetched by their hashes, which the signed Release names, so a cache
        # that has the new Release and the old indexes, or the other way
        # round, cannot mix the two; the old ones stay one more release.
        for index in "$dir"/Packages* "$branch/apt/dists/stable/main/binary-$arch"/Packages*; do
            [ -f "$index" ] || continue
            cp "$index" "$dir/by-hash/SHA256/$(sha256sum "$index" | cut -d' ' -f1)"
        done
    done

    # SHA256 alone, the hash the by-hash directories are named by: apt fetches
    # by the strongest hash a Release lists.
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=ime-jd \
        -o APT::FTPArchive::Release::Label=ime-jd \
        -o APT::FTPArchive::Release::Suite=stable \
        -o APT::FTPArchive::Release::Codename=stable \
        -o APT::FTPArchive::Release::Architectures='amd64 arm64' \
        -o APT::FTPArchive::Release::Components=main \
        -o APT::FTPArchive::Release::Description='键道输入法 for Fcitx 5 and IBus' \
        -o APT::FTPArchive::Release::Acquire-By-Hash=yes \
        -o APT::FTPArchive::Release::MD5=false \
        -o APT::FTPArchive::Release::SHA1=false \
        -o APT::FTPArchive::Release::SHA512=false \
        release "$work/dists/stable" > "$tmp/Release"
    mv "$tmp/Release" "$work/dists/stable/Release"
    gpg_sign --clearsign --output "$work/dists/stable/InRelease" "$work/dists/stable/Release"
    gpg_sign --armor --detach-sign --output "$work/dists/stable/Release.gpg" "$work/dists/stable/Release"

    mkdir -p "$out/apt"
    cp -R "$work/dists" "$out/apt/"
    gpg --armor --export "$fingerprint" > "$out/ime-jd.asc"
    gpg --export "$fingerprint" > "$out/ime-jd.gpg"

    cat > "$out/README.md" <<EOF
# 键道输入法's package repositories

The index files of 键道's apt, rpm and Alpine repositories, which
$url serves, with every release's packages from GitHub
Releases. The release workflow writes this branch; linux/README.md on master
says how to add the repositories, and linux/repo/ how they are built.
EOF
}

# ---- rpm ----

rpm_indexes() {
    gpg_init
    work=$tmp/rpm
    gather 'jd-ime-v*-linux-*.rpm' "$work/packages"
    mkdir -p "$work/packages"
    # gzip, which every dnf and zypper reads.
    createrepo_c --quiet --general-compress-type=gz "$work"
    gpg_sign --armor --detach-sign --output "$work/repodata/repomd.xml.asc" "$work/repodata/repomd.xml"
    gpg --armor --export "$fingerprint" > "$work/repodata/repomd.xml.key"

    mkdir -p "$out/rpm"
    cp -R "$work/repodata" "$out/rpm/"
    # The metadata the last repomd.xml named, for caches that still have it:
    # each file's name carries its checksum.
    if [ -f "$branch/rpm/repodata/repomd.xml" ]; then
        sed -n 's|.*<location href="repodata/\([^"/]*\)".*|\1|p' "$branch/rpm/repodata/repomd.xml" |
            while IFS= read -r name; do
                [ -e "$out/rpm/repodata/$name" ] || cp "$branch/rpm/repodata/$name" "$out/rpm/repodata/"
            done
    fi

    cat > "$out/rpm/ime-jd.repo" <<EOF
[ime-jd]
name=ime-jd (键道输入法)
baseurl=$url/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$url/ime-jd.asc
EOF
}

# ---- apk ----

apk_indexes() {
    # The key's file name is the name apk looks the public key up by:
    # /etc/apk/keys/ime-jd.rsa.pub.
    cp "$APK_KEY" "$tmp/ime-jd.rsa"
    for pair in x86_64:x86_64 aarch64:arm64; do
        arch=${pair%%:*} asset_arch=${pair#*:}
        dir=$tmp/alpine/$arch
        mkdir -p "$dir"
        for file in "$assets"/*/jd-ime-v*-alpine-"$asset_arch"-*.apk; do
            [ -e "$file" ] && ln -s "$file" "$dir/"
        done
        set -- "$dir"/*.apk
        [ -e "$1" ] || continue
        # Signed with a key this system does not trust; the index then
        # carries each package's checksum. Their dependencies are Alpine's.
        apk index --quiet --allow-untrusted --no-warnings --description ime-jd --output "$dir/APKINDEX.tar.gz" "$@"
        abuild-sign -q -k "$tmp/ime-jd.rsa" "$dir/APKINDEX.tar.gz"
        mkdir -p "$out/alpine/$arch"
        cp "$dir/APKINDEX.tar.gz" "$out/alpine/$arch/"
    done
    openssl rsa -in "$APK_KEY" -pubout -out "$out/ime-jd.rsa.pub" 2>/dev/null
}

case $format in
apt) apt_indexes ;;
rpm) rpm_indexes ;;
apk) apk_indexes ;;
*)
    echo "usage: $0 apt|rpm|apk <assets> <branch> <out>" >&2
    exit 2
    ;;
esac
