// The Worker's (worker.js) own routing: the update feed and the
// latest release's files from its bucket, older releases from GitHub, and
// GitHub asked again while it refuses. GitHub is a stand-in fetch, the bucket
// a map; the package repositories, end to end, are linux/tests/repo/'s.
//
// Usage: node --test cf-worker/worker.test.mjs
import assert from 'node:assert/strict'
import { afterEach, test } from 'node:test'

import worker, { assetFor } from './worker.js'

const HOST = 'https://ime-jd-repo.example'
const TAG = 'v1.2.3'
const ZIP = `jd-ime-${TAG}-windows-x86_64.zip`
const FEED = JSON.stringify({
    tag_name: TAG,
    html_url: `https://github.com/hronro/ime-jd/releases/tag/${TAG}`,
    assets: [{ name: ZIP, size: 3, digest: 'sha256:0', browser_download_url: `${HOST}/releases/download/${TAG}/${ZIP}` }],
})

/** R2, as far as the Worker uses it. */
function bucket(files) {
    const object = (key) => {
        const body = files[key]
        return {
            size: new TextEncoder().encode(body).length,
            httpEtag: '"etag"',
            uploaded: new Date(0),
            writeHttpMetadata(headers) {
                headers.set('content-type', 'application/octet-stream')
            },
            body: new Response(body).body,
            json: async () => JSON.parse(body),
        }
    }
    return {
        get: async (key) => (key in files ? object(key) : null),
        head: async (key) => (key in files ? object(key) : null),
    }
}

/** GitHub: each fetch answered by the next of `statuses`, the last one repeated. */
function github(statuses) {
    const asked = []
    globalThis.fetch = async (url) => {
        asked.push(String(url))
        const status = statuses[Math.min(asked.length, statuses.length) - 1]
        return new Response(status === 200 ? 'from github' : 'refused', { status })
    }
    return asked
}

const realFetch = globalThis.fetch
afterEach(() => {
    globalThis.fetch = realFetch
})

function get(path, env) {
    return worker.fetch(new Request(HOST + path), env, { waitUntil() {} })
}

test('names installers under GitHub’s path, only as their release names them', () => {
    assert.equal(assetFor(`/releases/download/${TAG}/${ZIP}`), `${TAG}/${ZIP}`)
    assert.equal(assetFor(`/releases/download/${TAG}/jd-ime-${TAG}-linux-arm64.tar.xz`), `${TAG}/jd-ime-${TAG}-linux-arm64.tar.xz`)
    assert.equal(assetFor(`/releases/download/v1.2.2/${ZIP}`), null, 'another release’s name')
    assert.equal(assetFor(`/releases/download/${TAG}/jd-ime-${TAG}-android-mapping.txt`), null, 'not an installer')
    assert.equal(assetFor(`/releases/download/${TAG}/jd-cli-${TAG}-linux-x86_64.tar.xz`), null, 'not 键道’s')
})

test('serves the feed from the bucket', async () => {
    const response = await get('/releases/latest.json', { LATEST: bucket({ 'latest.json': FEED }) })
    assert.equal(response.status, 200)
    assert.equal(response.headers.get('cache-control'), 'no-store')
    assert.equal((await response.json()).tag_name, TAG)
})

test('sends the client to GitHub’s feed without one in the bucket', async () => {
    for (const env of [{ LATEST: bucket({}) }, {}]) {
        const response = await get('/releases/latest.json', env)
        assert.equal(response.status, 302)
        assert.equal(response.headers.get('location'), 'https://api.github.com/repos/hronro/ime-jd/releases/latest')
    }
})

test('redirects a latest download to the release’s own name', async () => {
    const env = { LATEST: bucket({ 'latest.json': FEED }) }
    const response = await get('/releases/latest/download/jd-ime-windows-x86_64.zip', env)
    assert.equal(response.status, 302)
    assert.equal(response.headers.get('location'), `${HOST}/releases/download/${TAG}/${ZIP}`)
    assert.equal((await get('/releases/latest/download/jd-ime-windows-mips.zip', env)).status, 404)
    const without = await get('/releases/latest/download/jd-ime-windows-x86_64.zip', {})
    assert.equal(without.headers.get('location'), 'https://github.com/hronro/ime-jd/releases/latest')
})

test('serves the latest release’s installer from the bucket, not GitHub', async () => {
    const asked = github([500])
    const response = await get(`/releases/download/${TAG}/${ZIP}`, { LATEST: bucket({ [`${TAG}/${ZIP}`]: 'zip' }) })
    assert.equal(response.status, 200)
    assert.equal(await response.text(), 'zip')
    assert.equal(response.headers.get('content-length'), '3')
    assert.deepEqual(asked, [])
})

test('passes an older release through from GitHub, asked again while it refuses', async () => {
    const asked = github([429, 403, 200])
    const response = await get(`/releases/download/v1.2.2/jd-ime-v1.2.2-macos-arm64.pkg`, { LATEST: bucket({}) })
    assert.equal(response.status, 200)
    assert.equal(await response.text(), 'from github')
    assert.equal(asked.length, 3)
    assert.equal(asked[0], 'https://github.com/hronro/ime-jd/releases/download/v1.2.2/jd-ime-v1.2.2-macos-arm64.pkg')
})

test('sends the client to GitHub once GitHub keeps refusing', async () => {
    const asked = github([429])
    const response = await get(`/releases/download/v1.2.2/jd-ime-v1.2.2-macos-arm64.pkg`, {})
    assert.equal(response.status, 302)
    assert.equal(response.headers.get('location'), asked[0])
    assert.equal(asked.length, 5)
})

test('passes GitHub’s answer for a file it does not have, without asking again', async () => {
    const asked = github([404])
    const response = await get(`/releases/download/v1.2.2/jd-ime-v1.2.2-macos-arm64.pkg`, {})
    assert.equal(response.status, 404)
    assert.equal(asked.length, 1)
})
