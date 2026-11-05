// Runs the repository Worker (linux/repo/worker.js) on Node's HTTP server, as
// Cloudflare runs it, with github.py standing in for GitHub at <github>.
//
// Usage: node linux/tests/repo/worker.mjs <port> <github>
import http from 'node:http'

import worker from '../../repo/worker.js'

const [port, github] = process.argv.slice(2)
const env = {
    RELEASES: `${github}/hronro/ime-jd/releases/download/`,
    BRANCH: `${github}/raw/hronro/ime-jd/packages/`,
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
    const response = await worker.fetch(request, env)
    outgoing.writeHead(response.status, Object.fromEntries(response.headers))
    if (response.body && incoming.method !== 'HEAD') {
        for await (const chunk of response.body) {
            outgoing.write(chunk)
        }
    }
    outgoing.end()
}).listen(Number(port), '127.0.0.1')
