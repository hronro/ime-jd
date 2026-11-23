// The Cloudflare Worker behind ime-jd-repo.hronro.com (README.md): every
// release's downloads, with the update feed the self-updating clients read
// (macOS, Windows, Android and the Linux tarball), and 键道's apt, rpm and
// Alpine package repositories (linux/README.md, "Repositories") — so that
// users who cannot reach GitHub, as many in mainland China cannot, need not.
//
// Its own files are the latest release's: the installers those clients
// download, and the feed naming them, latest.json, which the release
// workflow puts in the R2 bucket LATEST (latest.sh) once the release is
// complete, taking the previous release's out. Everything else is passed
// through from GitHub: the index files, and the public keys they are signed
// with, are the `packages` branch's, which the release workflow writes; the
// packages, and older releases' installers, are the release assets on
// GitHub. So package managers and the updaters talk to this host alone:
//
//   /releases/latest.json                           the update feed
//   /releases/latest/download/jd-ime-<rest>         the latest release's jd-ime-<tag>-<rest>: a redirect to it
//   /releases/download/<tag>/<asset>                a release's installer, as GitHub names it
//   /apt/pool/<tag>/<asset>                         a .deb, as the apt index names it
//   /rpm/packages/<tag>/<asset>                     an .rpm, as the rpm index names it
//   /alpine/<arch>/ime-jd-<frontend>-<version>.apk  an .apk, as apk asks for it
//   /                                               the README's install steps
//   anything else                                   the branch's file at that path
//
// A release's files do not change, so one, once downloaded, stays in the
// cache of the Cloudflare data center that served it, and is served from
// there. GitHub limits downloads per address, and the addresses Cloudflare
// fetches from, shared with every other Worker, are often over that limit,
// even for a first download; asked again a moment later, GitHub mostly
// answers. A file GitHub keeps refusing is left to GitHub itself: the client
// is sent there, and counted against its own address. Without the feed in
// the bucket, the client is sent to GitHub's own, `releases/latest`, which
// names GitHub's downloads.
//
// RELEASES and BRANCH may be set in the Worker's environment, and LATEST be
// a stand-in or left out, for a test's stand-ins.

const RELEASES = 'https://github.com/hronro/ime-jd/releases/download/'
const BRANCH = 'https://raw.githubusercontent.com/hronro/ime-jd/packages/'
const README = 'https://github.com/hronro/ime-jd#linux-安装步骤'
const GITHUB_FEED = 'https://api.github.com/repos/hronro/ime-jd/releases/latest'
const LATEST_PAGE = 'https://github.com/hronro/ime-jd/releases/latest'

/** The update feed: its path here, and its key in the bucket. */
const FEED_PATH = '/releases/latest.json'
const FEED_KEY = 'latest.json'

/** How long to wait before asking GitHub again for a file it refused, in milliseconds; a try for each. */
const RETRY_DELAYS = [250, 500, 1000, 2000]

/** What a package manager's request may need answered; nothing else goes upstream. */
const FORWARDED = ['range', 'if-range', 'if-none-match', 'if-modified-since', 'user-agent']

/** The headers a cached package keeps, a range answered from it among them. */
const KEPT = ['content-type', 'content-length', 'etag', 'last-modified']

/** The release asset, as `<tag>/<asset>`, that a package's or an installer's path names; null for any other path. */
export function assetFor(path) {
    // A release's installers and packages under GitHub's own path, so that a
    // download URL here is GitHub's with the host changed.
    let match = path.match(
        /^\/releases\/download\/(v\d+\.\d+\.\d+[\w.+-]*)\/(jd-ime-[\w.+-]+\.(?:zip|pkg|apk|ipa|tar\.xz|deb|rpm|pkg\.tar\.zst))$/,
    )
    if (match && match[2].startsWith(`jd-ime-${match[1]}-`)) {
        return `${match[1]}/${match[2]}`
    }
    match = path.match(/^\/(?:apt\/pool|rpm\/packages)\/(v\d+\.\d+\.\d+[\w.+-]*)\/(jd-ime-[\w.+-]+\.(?:deb|rpm))$/)
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
 * A fetch from GitHub that follows its redirects here, asked again while
 * GitHub refuses it, up to a few times: its last answer. A request the Worker
 * receives has the redirect mode `manual`, which would hand GitHub's own
 * redirect, to where a file is stored, to the client.
 */
async function fetchUpstream(url, init) {
    for (const delay of RETRY_DELAYS) {
        const response = await fetch(url, { ...init, redirect: 'follow' })
        if (!isRefusal(response.status)) {
            return response
        }
        await response.body?.cancel()
        await new Promise((resolve) => setTimeout(resolve, delay))
    }
    return fetch(url, { ...init, redirect: 'follow' })
}

/** A file of the latest release, from the bucket, as `<tag>/<asset>`; null where it is not there. */
async function fromBucket(bucket, key, method) {
    if (!bucket) {
        return null
    }
    const object = method === 'HEAD' ? await bucket.head(key) : await bucket.get(key)
    if (!object) {
        return null
    }
    const headers = new Headers()
    object.writeHttpMetadata(headers)
    headers.set('content-length', String(object.size))
    headers.set('etag', object.httpEtag)
    headers.set('last-modified', object.uploaded.toUTCString())
    return new Response(method === 'HEAD' ? null : object.body, { headers })
}

/** The client sent to GitHub itself, which the Worker could not get the file from. */
function sendToGitHub(response, upstream) {
    response.body?.cancel()
    return Response.redirect(upstream, 302)
}

/** A package or an installer: from this data center's cache, the bucket, or its release on GitHub. */
async function servePackage(request, url, asset, env, ctx) {
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
    let response = await fromBucket(env?.LATEST, asset, request.method)
    if (!response) {
        const upstream = (env?.RELEASES ?? RELEASES) + asset
        response = await fetchUpstream(upstream, {
            method: request.method,
            headers: whole ? forwarded(request, ['user-agent']) : forwarded(request),
        })
        if (isRefusal(response.status)) {
            return sendToGitHub(response, upstream)
        }
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

/** The update feed, as the release workflow left it in the bucket; GitHub's own without it. */
async function serveFeed(request, env) {
    const bucket = env?.LATEST
    const object = bucket ? await (request.method === 'HEAD' ? bucket.head(FEED_KEY) : bucket.get(FEED_KEY)) : null
    if (!object) {
        return Response.redirect(GITHUB_FEED, 302)
    }
    // Read afresh every time, so that a check made from a menu sees a
    // release as soon as the bucket has it.
    return new Response(request.method === 'HEAD' ? null : object.body, {
        headers: {
            'content-type': 'application/json; charset=utf-8',
            'content-length': String(object.size),
            'cache-control': 'no-store',
        },
    })
}

/**
 * The latest release's `jd-ime-<tag>-<rest>`, asked for as `jd-ime-<rest>`,
 * which names the same file in every release: a redirect to it, so that a
 * link to it need not change with each release.
 */
async function serveLatest(url, name, env) {
    const object = await env?.LATEST?.get(FEED_KEY)
    if (!object) {
        return Response.redirect(LATEST_PAGE, 302)
    }
    const feed = await object.json()
    const asset = `jd-ime-${feed.tag_name}-${name.slice('jd-ime-'.length)}`
    if (!feed.assets?.some((a) => a.name === asset)) {
        return new Response('Not found\n', { status: 404 })
    }
    return Response.redirect(`${url.origin}/releases/download/${feed.tag_name}/${asset}`, 302)
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
        if (url.pathname === FEED_PATH) {
            return serveFeed(request, env)
        }
        const latest = url.pathname.match(/^\/releases\/latest\/download\/(jd-ime-[\w.+-]+)$/)
        if (latest) {
            return serveLatest(url, latest[1], env)
        }
        const asset = assetFor(url.pathname)
        if (asset) {
            return servePackage(request, url, asset, env, ctx)
        }
        if (isBranchPath(url.pathname)) {
            return serveIndex(request, (env?.BRANCH ?? BRANCH) + url.pathname.slice(1))
        }
        return new Response('Not found\n', { status: 404 })
    },
}
