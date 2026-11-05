// The Cloudflare Worker behind ime-jd-repo.hronro.com: 键道's apt, rpm and
// Alpine package repositories (linux/README.md, "Repositories").
//
// It keeps no files of its own. The index files, and the public keys they are
// signed with, are the `packages` branch's, which the release workflow writes;
// the packages are the release assets already on GitHub. Both are passed
// through, not redirected to, so package managers talk to this host alone,
// and it follows GitHub's own redirect, to where an asset is stored, itself:
//
//   /apt/pool/<tag>/<asset>                         a .deb, as the apt index names it
//   /rpm/packages/<tag>/<asset>                     an .rpm, as the rpm index names it
//   /alpine/<arch>/ime-jd-<frontend>-<version>.apk  an .apk, as apk asks for it
//   /                                               the README's install steps
//   anything else                                   the branch's file at that path
//
// RELEASES and BRANCH may be set in the Worker's environment, for a test's
// stand-ins.

const RELEASES = 'https://github.com/hronro/ime-jd/releases/download/'
const BRANCH = 'https://raw.githubusercontent.com/hronro/ime-jd/packages/'
const README = 'https://github.com/hronro/ime-jd#linux-安装步骤'

/** What a package manager's request may need answered; nothing else goes upstream. */
const FORWARDED = ['range', 'if-range', 'if-none-match', 'if-modified-since', 'user-agent']

/** The release asset, as `<tag>/<asset>`, that a package's path names; null for any other path. */
export function assetFor(path) {
    let match = path.match(/^\/(?:apt\/pool|rpm\/packages)\/(v\d+\.\d+\.\d+[\w.+-]*)\/(jd-ime-[\w.+-]+\.(?:deb|rpm))$/)
    if (match) {
        return `${match[1]}/${match[2]}`
    }
    // apk asks for <arch>/<name>-<version>.apk; the release names its assets
    // by tag, platform and arch, as linux/packaging/build.sh does.
    match = path.match(/^\/alpine\/(x86_64|aarch64)\/ime-jd-(fcitx5|ibus|userdict)-(\d+\.\d+\.\d+)-r\d+\.apk$/)
    if (match) {
        const [, arch, frontend, version] = match
        return `v${version}/jd-ime-v${version}-alpine-${arch === 'aarch64' ? 'arm64' : arch}-${frontend}.apk`
    }
    return null
}

/** Whether `path` names a file the branch could hold: plain names, nothing climbing out. */
function isBranchPath(path) {
    return /^(\/[\w.+-]+)+$/.test(path) && !path.split('/').some((part) => part === '.' || part === '..')
}

export default {
    async fetch(request, env) {
        if (request.method !== 'GET' && request.method !== 'HEAD') {
            return new Response('Method not allowed\n', { status: 405, headers: { allow: 'GET, HEAD' } })
        }
        const { pathname } = new URL(request.url)
        if (pathname === '/') {
            return Response.redirect(README, 302)
        }

        const asset = assetFor(pathname)
        let upstream
        if (asset) {
            upstream = (env?.RELEASES ?? RELEASES) + asset
        } else if (isBranchPath(pathname)) {
            upstream = (env?.BRANCH ?? BRANCH) + pathname.slice(1)
        } else {
            return new Response('Not found\n', { status: 404 })
        }

        const headers = new Headers()
        for (const name of FORWARDED) {
            const value = request.headers.get(name)
            if (value !== null) {
                headers.set(name, value)
            }
        }
        // A request the Worker receives has the redirect mode `manual`, which
        // would hand GitHub's redirect to the client: a new one follows it,
        // here, carrying only the headers above. The index files may be a
        // minute old at Cloudflare's edge, on top of GitHub's own five
        // minutes; the indexes are laid out to stay consistent meanwhile.
        return fetch(upstream, {
            method: request.method,
            headers,
            redirect: 'follow',
            cf: asset ? undefined : { cacheEverything: true, cacheTtl: 60 },
        })
    },
}
