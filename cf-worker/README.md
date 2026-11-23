# 键道's downloads

`ime-jd-repo.hronro.com` is where 键道 is downloaded from, besides GitHub Releases: a Cloudflare Worker (`worker.js`) that serves every platform's installers, the update feed the self-updating clients read — macOS, Windows, Android's GitHub build and Linux's generic tarball — and Linux's package repositories. So users who cannot reach GitHub, as many in mainland China cannot, get 键道 and its updates all the same. The README links to the installers ([安装指南](../README.md#-安装指南)).

| Path | |
|---|---|
| `/releases/latest.json` | the update feed: the latest release, in the shape of GitHub's `releases/latest` as far as the clients read it (`tag_name`, `html_url`, and each asset's `name`, `size`, `digest` and `browser_download_url`), the download URLs the Worker's |
| `/releases/download/<tag>/<asset>` | a release's installer or package, as GitHub's own path names it: a download URL there with the host changed |
| `/releases/latest/download/jd-ime-<rest>` | a redirect to the latest release's `jd-ime-<tag>-<rest>`, for links that need not change with each release, such as `jd-ime-windows-x86_64.zip` |
| `/apt/`, `/rpm/`, `/alpine/`, the keys | the package repositories: their index files from the `packages` branch, their packages from the releases — see [linux/README.md, Repositories](../linux/README.md#repositories) |
| `/` | a redirect to the README's Linux install steps |

## The latest release

The latest release is the Worker's own: its installers — the Windows `.zip`, the macOS `.pkg`, the Android `.apk` and the generic tarball, for each arch, some 40 MB — and the feed naming them are kept in the R2 bucket `ime-jd-latest`, as `<tag>/<asset>` and `latest.json`, so that neither the update check nor a download of the latest release waits on GitHub. A release puts itself there once every one of those is built — `publish-latest` in `.github/workflows/release.yml` runs `latest.sh`, which downloads them from the release, checks them against the SHA-256 GitHub has for each, uploads them, then the feed, and last takes the previous release's files out — and the clients only learn of it then. A pre-release, or a release that is not GitHub's latest (an older one built again), leaves the bucket as it is. Without the feed in the bucket, `/releases/latest.json` sends the client to GitHub's `releases/latest`, which names GitHub's own downloads, and `/releases/latest/download/` to the release page.

The clients still check what they download against the feed's SHA-256, now from a host that is not GitHub. Releases up to 0.13.0 read GitHub's feed, and move here with the update to a release that reads this one.

## Caching and GitHub's limits

Everything else is passed through from GitHub — older releases' installers, the packages, and the repositories' index files — with GitHub's own redirect, to where a file is stored, followed by the Worker, so a client talks to this host alone. A release's files do not change, so one, once downloaded, stays in the cache of the Cloudflare data center that served it, under its address here, and later downloads there come from the cache; so does the latest release's, from the bucket.

GitHub limits downloads per address, and the addresses Cloudflare fetches from, which every Worker shares, are often over that limit, even for a Worker's first download, though asked again a moment later GitHub mostly answers. So when GitHub refuses a file (403, 429, or a server error), the Worker asks again, up to four more times over four seconds, and only then sends the client to GitHub's own address for it, a redirect every client here follows, and the download counts against the client's own address.

Should a release's files ever be replaced after it was published, the cache would keep serving the old ones, which fail their checksums: purge their addresses from Cloudflare's cache (Caching → Configuration → Purge Cache, by URL).

## Setup

Once, with the Cloudflare account that has `hronro.com`:

- Make the bucket, with R2 enabled on the account: `npx wrangler r2 bucket create ime-jd-latest`. `wrangler.toml` binds it to the Worker as `LATEST`.
- Deploy the Worker, which changes only with `worker.js`, so a release does not deploy it: `npx wrangler deploy --config cf-worker/wrangler.toml`.
- Give the API token in the Actions secret `CLOUDFLARE_API_TOKEN`, which `deploy-web` uses too, the permission to edit R2 storage (**Workers R2 Storage: Edit**); `CLOUDFLARE_ACCOUNT_ID` is the same account's. Without the secret, `publish-latest` is skipped.
- Put the latest release in the bucket by hand, with a login (`npx wrangler login`) or those two variables, and `gh`: `cf-worker/latest.sh <tag>`. The next release does it itself.

The package repositories' keys and secrets are set up as [linux/README.md](../linux/README.md#repositories) says.

## Tests

`worker.test.mjs` tests the Worker's routing, with stand-ins for GitHub and the bucket: `node --test cf-worker/worker.test.mjs`, run on every push by `test-on-push.yml`. The package repositories are tested through the Worker end to end, run by Node in front of a stand-in for GitHub (`linux/tests/repo/`), by `build-on-push.yml`.

`latest.sh` can be run against Wrangler's local storage, and the Worker served from it, to try both together:

```
R2_STORAGE='--local --persist-to /tmp/r2' REPO_URL=http://127.0.0.1:8787 cf-worker/latest.sh <tag>
npx wrangler dev --config cf-worker/wrangler.toml --local --persist-to /tmp/r2 --port 8787
```

## Files

| | |
|---|---|
| `worker.js` | The Worker. |
| `wrangler.toml` | Its configuration: the route and the bucket. |
| `latest.sh` | Puts a release in the bucket. |
| `worker.test.mjs` | The Worker's tests. |
