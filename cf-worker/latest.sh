#!/bin/sh
# Puts a release in the R2 bucket the Worker (worker.js) serves the latest
# release from, at ime-jd-repo.hronro.com/releases/: the installers the
# self-updating clients download — the Windows .zip, the macOS .pkg, the
# Android .apk and the Linux tarball, for each arch — as <tag>/<asset>, and
# then the update feed naming them, latest.json, in the shape of GitHub's
# `releases/latest` as far as the clients read it, their download URLs the
# Worker's. Last, the files of the release the previous feed named are taken
# out: the bucket holds one release, and the Worker passes older ones
# through from GitHub.
#
# Usage: cf-worker/latest.sh <tag>
#
# A tag that is not GitHub's latest release — a pre-release, or an older
# release built again — leaves the bucket as it is.
#
# It wants gh, with GH_TOKEN or a login, jq, and Wrangler, run through npx,
# with an API token allowed to edit R2 storage in CLOUDFLARE_API_TOKEN and
# the account in CLOUDFLARE_ACCOUNT_ID, or a login. $REPO_URL is where the
# Worker serves, https://ime-jd-repo.hronro.com unless set. $R2_STORAGE is
# how Wrangler reaches the bucket, --remote unless set: for a test,
# `--local --persist-to <dir>`, the storage `wrangler dev --persist-to <dir>`
# serves.
set -eu

tag=$1
repo=${GITHUB_REPOSITORY:-hronro/ime-jd}
url=${REPO_URL:-https://ime-jd-repo.hronro.com}
storage=${R2_STORAGE:---remote}
bucket=ime-jd-latest

case $tag in
*-*)
    echo "$tag is a pre-release: the bucket keeps the latest release."
    exit 0
    ;;
esac
latest=$(gh api "repos/$repo/releases/latest" --jq .tag_name)
if [ "$tag" != "$latest" ]; then
    echo "$tag is not the latest release, $latest: the bucket is left as it is."
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

wrangler() {
    # shellcheck disable=SC2086
    npx --yes wrangler@4.164.0 r2 object "$@" $storage
}

sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1"
    else
        shasum -a 256 "$1"
    fi | cut -d' ' -f1
}

# Every self-updating client's installer, each arch's.
gh release download "$tag" -R "$repo" -D "$tmp/assets" \
    -p "jd-ime-$tag-windows-*.zip" -p "jd-ime-$tag-macos-*.pkg" \
    -p "jd-ime-$tag-android-*.apk" -p "jd-ime-$tag-linux-*.tar.xz"
for kind in 'windows-*.zip' 'macos-*.pkg' 'android-*.apk' 'linux-*.tar.xz'; do
    # shellcheck disable=SC2086
    set -- "$tmp/assets/jd-ime-$tag-"$kind
    if [ ! -e "$1" ]; then
        echo "$tag has no jd-ime-$tag-$kind." >&2
        exit 1
    fi
done

# Each file's size and SHA-256, the SHA-256 checked against GitHub's, where
# GitHub has one: the clients check what they download against these.
gh api "repos/$repo/releases/tags/$tag" --jq '.assets[] | "\(.name) \(.digest // "")"' > "$tmp/digests"
for file in "$tmp/assets"/*; do
    name=$(basename "$file")
    digest=sha256:$(sha256 "$file")
    github=$(awk -v name="$name" '$1 == name { print $2 }' "$tmp/digests")
    if [ -n "$github" ] && [ "$github" != "$digest" ]; then
        echo "$name: downloaded $digest, GitHub has $github." >&2
        exit 1
    fi
    jq -n --arg name "$name" --argjson size "$(wc -c < "$file" | tr -d ' ')" --arg digest "$digest" \
        --arg url "$url/releases/download/$tag/$name" \
        '{name: $name, size: $size, digest: $digest, browser_download_url: $url}'
done | jq -s --arg tag "$tag" --arg page "https://github.com/$repo/releases/tag/$tag" \
    '{tag_name: $tag, html_url: $page, assets: .}' > "$tmp/latest.json"

# The feed it replaces, for the files to take out after.
if ! wrangler get "$bucket/latest.json" --file "$tmp/previous.json" >/dev/null; then
    echo "No feed could be read from the bucket: nothing will be taken out of it."
    rm -f "$tmp/previous.json"
fi

for file in "$tmp/assets"/*; do
    name=$(basename "$file")
    case $name in
    *.zip) type=application/zip ;;
    *.apk) type=application/vnd.android.package-archive ;;
    *.tar.xz) type=application/x-xz ;;
    *) type=application/octet-stream ;;
    esac
    wrangler put "$bucket/$tag/$name" --file "$file" --content-type "$type"
done
# The feed last, once every file it names is there.
wrangler put "$bucket/latest.json" --file "$tmp/latest.json" --content-type application/json
cat "$tmp/latest.json"

if [ -f "$tmp/previous.json" ]; then
    jq -r --arg tag "$tag" 'select(.tag_name != $tag) | .tag_name as $t | .assets[] | "\($t)/\(.name)"' \
        "$tmp/previous.json" |
        while IFS= read -r key; do
            wrangler delete "$bucket/$key" || echo "$key could not be taken out of the bucket." >&2
        done
fi
