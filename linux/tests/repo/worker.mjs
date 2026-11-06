// Runs the repository Worker (linux/repo/worker.js) on Node's HTTP server, as
// Cloudflare runs it, with github.py standing in for GitHub at <github>: its
// requests marked as the Worker's, which github.py can be told to refuse, as
// GitHub refuses Cloudflare's addresses, and a cache like the data center's.
//
// Usage: node linux/tests/repo/worker.mjs <port> <github>
import http from 'node:http'

import worker from '../../repo/worker.js'

const [port, github] = process.argv.slice(2)
const env = {
    RELEASES: `${github}/hronro/ime-jd/releases/download/`,
    BRANCH: `${github}/raw/hronro/ime-jd/packages/`,
}

const fetchFromHere = globalThis.fetch
globalThis.fetch = (url, init = {}) => {
    const headers = new Headers(init.headers)
    headers.set('x-imejd-worker', '1')
    return fetchFromHere(url, { ...init, headers })
}

/** Cloudflare's Cache API as far as the Worker uses it: put, and match answering a range. */
class Cache {
    #entries = new Map()

    async put(key, response) {
        const url = typeof key === 'string' ? key : key.url
        if (response.status === 206) {
            throw new TypeError('cache.put: a partial response')
        }
        const body = new Uint8Array(await response.arrayBuffer())
        this.#entries.set(url, { status: response.status, headers: [...response.headers], body })
        console.error(`cache: stored ${url}`)
    }

    async match(request) {
        const entry = this.#entries.get(request.url)
        if (!entry) {
            return undefined
        }
        console.error(`cache: hit ${request.url}`)
        const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.get('range') ?? '')
        if (!range) {
            return new Response(entry.body, { status: entry.status, headers: entry.headers })
        }
        const start = Number(range[1])
        const end = range[2] === '' ? entry.body.length - 1 : Math.min(Number(range[2]), entry.body.length - 1)
        const headers = new Headers(entry.headers)
        headers.set('content-range', `bytes ${start}-${end}/${entry.body.length}`)
        headers.set('content-length', String(end - start + 1))
        return new Response(entry.body.slice(start, end + 1), { status: 206, headers })
    }
}
globalThis.caches = { default: new Cache() }

const ctx = {
    waitUntil(promise) {
        promise.catch((error) => console.error(`waitUntil: ${error}`))
    },
}

http.createServer(async (incoming, outgoing) => {
    const headers = new Headers()
    for (const [name, value] of Object.entries(incoming.headers)) {
        headers.set(name, Array.isArray(value) ? value.join(', ') : value)
    }
    // As Cloudflare hands a request over: with the redirect mode `manual`.
    const request = new Request(`http://${incoming.headers.host}${incoming.url}`, {
        method: incoming.method,
        headers,
        redirect: 'manual',
    })
    const response = await worker.fetch(request, env, ctx)
    outgoing.writeHead(response.status, Object.fromEntries(response.headers))
    if (response.body && incoming.method !== 'HEAD') {
        for await (const chunk of response.body) {
            outgoing.write(chunk)
        }
    }
    outgoing.end()
}).listen(Number(port), '127.0.0.1')
