// The update feed's data model — plain Kotlin + org.json, no Android
// framework types, so it runs as a JVM unit test (src/test/.../ReleaseFeedTest).
// UpdateChecker does the fetching and the presenting.
//
// The feed is GitHub's `releases/latest` endpoint for this repository. Every
// platform frontend that updates itself reads the same feed and applies the
// same rules (macos/JdIME/Update/UpdateFeed.swift, windows/src/update/feed.rs):
// compare the release's MAJOR.MINOR.PATCH against the running build, and pick
// the asset `.github/workflows/release.yml` names for this platform.
package com.hronro.imejd.update

import org.json.JSONException
import org.json.JSONObject

/**
 * A release version, MAJOR.MINOR.PATCH, parsed from a Git tag ("v0.6.0") or
 * a versionName ("0.6.0"). A -prerelease / +build suffix is ignored: the feed
 * only ever reports full releases, and the numeric triple is all that decides
 * whether one build is newer than another.
 */
data class ReleaseVersion(val major: Int, val minor: Int, val patch: Int) : Comparable<ReleaseVersion> {

    /**
     * 0.0.0 — the placeholder that plain IDE builds carry (see
     * app/build.gradle.kts). Such a build is not a release: it must never be
     * told to "update", and the automatic check skips it entirely.
     */
    val isPlaceholder: Boolean get() = major == 0 && minor == 0 && patch == 0

    override fun compareTo(other: ReleaseVersion): Int =
        compareValuesBy(this, other, { it.major }, { it.minor }, { it.patch })

    override fun toString(): String = "$major.$minor.$patch"

    companion object {
        fun parse(text: String): ReleaseVersion? {
            var body = text.trim()
            if (body.startsWith("v") || body.startsWith("V")) body = body.substring(1)
            val cut = body.indexOfFirst { it == '-' || it == '+' }
            if (cut >= 0) body = body.substring(0, cut)
            val parts = body.split('.')
            if (parts.size != 3) return null
            val numbers = parts.map { part ->
                // ASCII digits only: toInt() would also accept a leading sign.
                if (part.isEmpty() || !part.all { it in '0'..'9' }) return null
                part.toIntOrNull() ?: return null
            }
            return ReleaseVersion(numbers[0], numbers[1], numbers[2])
        }
    }
}

/** One downloadable file attached to a release. */
data class ReleaseAsset(
    val name: String,
    val url: String,
    val size: Long,
    /**
     * Lowercase hex SHA-256 from the API's `digest` field ("sha256:<hex>"),
     * when GitHub supplied one. The download is checked against it.
     */
    val sha256: String?,
)

/**
 * The newest release, as reported by the `releases/latest` endpoint (which
 * excludes drafts and pre-releases).
 */
data class LatestRelease(
    /** The Git tag, e.g. "v0.6.0". Also the version the asset names carry. */
    val tag: String,
    val version: ReleaseVersion,
    /** The human-readable release page (notes + downloads). */
    val pageUrl: String,
    val assets: List<ReleaseAsset>,
) {
    fun asset(name: String): ReleaseAsset? = assets.firstOrNull { it.name == name }

    companion object {
        /**
         * Decode the endpoint's JSON. Null when the payload is not a release
         * with a version tag — a rate-limit error body, say.
         */
        fun parse(json: String): LatestRelease? {
            val obj = try {
                JSONObject(json)
            } catch (_: JSONException) {
                return null
            }
            val tag = obj.optString("tag_name", "")
            val version = ReleaseVersion.parse(tag) ?: return null
            val page = obj.optString("html_url", "")
            if (page.isEmpty()) return null

            val assets = ArrayList<ReleaseAsset>()
            val raw = obj.optJSONArray("assets")
            if (raw != null) {
                for (i in 0 until raw.length()) {
                    val a = raw.optJSONObject(i) ?: continue
                    val name = a.optString("name", "")
                    val url = a.optString("browser_download_url", "")
                    if (name.isEmpty() || url.isEmpty()) continue
                    val digest = a.optString("digest", "")
                    val sha256 = digest
                        .takeIf { it.startsWith("sha256:") }
                        ?.substring("sha256:".length)
                        ?.lowercase()
                        ?.takeIf { hex -> hex.length == 64 && hex.all { it in '0'..'9' || it in 'a'..'f' } }
                    assets.add(ReleaseAsset(name, url, a.optLong("size", 0L), sha256))
                }
            }
            return LatestRelease(tag, version, page, assets)
        }
    }
}

object UpdateFeed {
    /** `releases/latest` — drafts and pre-releases excluded by the endpoint. */
    const val LATEST_RELEASE_URL = "https://api.github.com/repos/hronro/ime-jd/releases/latest"

    /** Where a user goes to read notes or download by hand. */
    const val RELEASES_PAGE_URL = "https://github.com/hronro/ime-jd/releases"

    /** Minimum gap between two automatic checks, in milliseconds. */
    const val CHECK_INTERVAL_MS = 24L * 60 * 60 * 1000

    /**
     * The release's APK for an Android ABI, "jd-ime-<tag>-android-<arch>.apk",
     * exactly as release.yml names it — or null for an ABI no release ships
     * (armeabi-v7a / x86 are not built yet).
     */
    fun apkName(tag: String, abi: String): String? {
        val arch = when (abi) {
            "arm64-v8a" -> "arm64"
            "x86_64" -> "x86_64"
            else -> return null
        }
        return "jd-ime-$tag-android-$arch.apk"
    }

    /**
     * The first ABI in the device's preference order (Build.SUPPORTED_ABIS)
     * that a release ships an APK for, or null when none does.
     */
    fun installableAbi(supportedAbis: Array<String>): String? =
        supportedAbis.firstOrNull { apkName("v0.0.0", it) != null }
}
