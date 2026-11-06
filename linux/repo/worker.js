// The Cloudflare Worker behind ime-jd-repo.hronro.com: 键道's apt, rpm and
// Alpine package repositories (linux/README.md, "Repositories").
//
// It keeps no files of its own. The index files, and the public keys they are
// signed with, are the `packages` branch's, which the release workflow writes;
// the packages are the release assets already on GitHub. Both are passed
// through, so package managers talk to this host alone:
//
//   /apt/pool/<tag>/<asset>                         a .deb, as the apt index names it
//   /rpm/packages/<tag>/<asset>                     an .rpm, as the rpm index names it
//   /alpine/<arch>/ime-jd-<frontend>-<version>.apk  an .apk, as apk asks for it
//   /                                               the README's install steps
//   anything else                                   the branch's file at that path
//
// A release's files do not change, so a package, once downloaded, stays in
// the cache of the Cloudflare data center that served it, and is served from
// there. GitHub limits downloads per address, and the addresses Cloudflare
// fetches from, shared with every other Worker, are often over that limit,
// even for a first download: when GitHub refuses one, the client is sent to
// GitHub itself, and counted against its own address.
//
// RELEASES and BRANCH may be set in the Worker's environment, for a test's
// stand-ins.

const RELEASES = 'https://github.com/hronro/ime-jd/releases/download/'
const BRANCH = 'https://raw.githubusercontent.com/hronro/ime-jd/packages/'
const README = 'https://github.com/hronro/ime-jd#linux-安装步骤'

/** What a package manager's request may need answered; nothing else goes upstream. */
const FORWARDED = ['range', 'if-range', 'if-none-match', 'if-modified-since', 'user-agent']

/** The headers a cached package keeps, a range answered from it among them. */
const KEPT = ['content-type', 'content-length', 'etag', 'last-modified']

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

/** Whether GitHub's answer means "not from you, not now" rather than "no such file". */
function isRefusal(status) {
    return status === 403 || status === 429 || status >= 500
}

/** The request's headers named, as a fetch upstream carries them. */
function forwarded(request, names = FORWARDED) {
    const headers = new Headers()
    for (const name of names) {
        const value = request.headers.get(name)
        if (value !== null) {
            headers.set(name, value)
        }
    }
    return headers
}

/**
 * A fetch from GitHub that follows its redirects here. A request the Worker
 * receives has the redirect mode `manual`, which would hand GitHub's own
 * redirect, to where a file is stored, to the client.
 */
function fetchUpstream(url, init) {
    return fetch(url, { ...init, redirect: 'follow' })
}

/** The client sent to GitHub itself, which the Worker could not get the file from. */
function sendToGitHub(response, upstream) {
    response.body?.cancel()
    return Response.redirect(upstream, 302)
}

/** A package: from this data center's cache, or from its release on GitHub. */
async function servePackage(request, url, upstream, ctx) {
    const cache = globalThis.caches?.default
    // Under its address here: GitHub's own download links carry a signature
    // that changes every time, which no cache would match.
    const key = `${url.origin}${url.pathname}`
    if (cache) {
        // The cache answers the client's range and conditions itself.
        const cached = await cache.match(new Request(key, { headers: forwarded(request) }))
        if (cached) {
            return request.method === 'HEAD' ? new Response(null, cached) : cached
        }
    }

    // For the cache, the whole file, whatever part of it the client asked
    // for: it gets the whole file too, which HTTP allows.
    const whole = cache !== undefined && request.method === 'GET'
    const response = await fetchUpstream(upstream, {
        method: request.method,
        headers: whole ? forwarded(request, ['user-agent']) : forwarded(request),
    })
    if (isRefusal(response.status)) {
        return sendToGitHub(response, upstream)
    }
    if (!whole || response.status !== 200 || !response.body) {
        return response
    }

    const headers = new Headers()
    for (const name of KEPT) {
        const value = response.headers.get(name)
        if (value !== null) {
            headers.set(name, value)
        }
    }
    // As long as the cache will: only a release's files replaced after it
    // was published make it wrong, and those are purged by hand.
    headers.set('cache-control', 'public, max-age=31536000, immutable')
    const [kept, sent] = response.body.tee()
    ctx.waitUntil(cache.put(key, new Response(kept, { headers })))
    return new Response(sent, { headers })
}

/**
 * An index file, or a key, from the branch. Cloudflare keeps each a minute,
 * on top of GitHub's own five; the indexes are laid out to stay consistent
 * meanwhile.
 */
async function serveIndex(request, upstream) {
    const response = await fetchUpstream(upstream, {
        method: request.method,
        headers: forwarded(request),
        cf: { cacheEverything: true, cacheTtlByStatus: { '200-299': 60 } },
    })
    return isRefusal(response.status) ? sendToGitHub(response, upstream) : response
}

export default {
    async fetch(request, env, ctx) {
        if (request.method !== 'GET' && request.method !== 'HEAD') {
            return new Response('Method not allowed\n', { status: 405, headers: { allow: 'GET, HEAD' } })
        }
        const url = new URL(request.url)
        if (url.pathname === '/') {
            return Response.redirect(README, 302)
        }
        const asset = assetFor(url.pathname)
        if (asset) {
            return servePackage(request, url, (env?.RELEASES ?? RELEASES) + asset, ctx)
        }
        if (isBranchPath(url.pathname)) {
            return serveIndex(request, (env?.BRANCH ?? BRANCH) + url.pathname.slice(1))
        }
        return new Response('Not found\n', { status: 404 })
    },
}
