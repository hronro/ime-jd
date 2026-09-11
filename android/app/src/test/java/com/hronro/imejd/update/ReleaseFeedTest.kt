// JVM unit tests for the update feed model (no device needed). org.json is a
// stub in the unit-test android.jar, so build.gradle.kts adds the real
// implementation to the test classpath.
package com.hronro.imejd.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReleaseFeedTest {

    // --- ReleaseVersion -----------------------------------------------------

    @Test
    fun parsesTagsAndVersionNames() {
        assertEquals(ReleaseVersion(0, 6, 0), ReleaseVersion.parse("v0.6.0"))
        assertEquals(ReleaseVersion(0, 6, 0), ReleaseVersion.parse("0.6.0"))
        assertEquals(ReleaseVersion(1, 2, 3), ReleaseVersion.parse("V1.2.3"))
        assertEquals(ReleaseVersion(0, 10, 1), ReleaseVersion.parse(" v0.10.1\n"))
        assertEquals(ReleaseVersion(1, 2, 3), ReleaseVersion.parse("01.002.3"))
    }

    @Test
    fun ignoresPrereleaseAndBuildSuffixes() {
        assertEquals(ReleaseVersion(1, 0, 0), ReleaseVersion.parse("v1.0.0-rc1"))
        assertEquals(ReleaseVersion(1, 0, 0), ReleaseVersion.parse("1.0.0+build.7"))
        assertEquals(ReleaseVersion(1, 0, 0), ReleaseVersion.parse("v1.0.0-beta.2+exp"))
    }

    @Test
    fun rejectsMalformedVersions() {
        for (bad in listOf("", "v", "1.2", "1.2.3.4", "a.b.c", "1.2.x", "1..3", "v1.2.-3", "+1.2.3", "١.٢.٣", "1.2.3 4")) {
            assertNull("'$bad' should not parse", ReleaseVersion.parse(bad))
        }
    }

    @Test
    fun ordersNumericallyNotLexically() {
        assertTrue(ReleaseVersion.parse("0.9.9")!! < ReleaseVersion.parse("0.10.0")!!)
        assertTrue(ReleaseVersion.parse("0.6.0")!! < ReleaseVersion.parse("1.0.0")!!)
        assertTrue(ReleaseVersion.parse("0.6.0")!! < ReleaseVersion.parse("0.6.1")!!)
        assertEquals(0, ReleaseVersion.parse("0.6.0")!!.compareTo(ReleaseVersion.parse("v0.6.0-rc1")!!))
    }

    @Test
    fun placeholderIsOnlyAllZeros() {
        assertTrue(ReleaseVersion.parse("0.0.0")!!.isPlaceholder)
        assertFalse(ReleaseVersion.parse("0.0.1")!!.isPlaceholder)
        assertEquals("0.6.0", ReleaseVersion.parse("v0.6.0").toString())
    }

    // --- LatestRelease ------------------------------------------------------

    private val feed = """
        {
          "url": "https://api.github.com/repos/hronro/ime-jd/releases/1",
          "html_url": "https://github.com/hronro/ime-jd/releases/tag/v0.6.0",
          "tag_name": "v0.6.0",
          "name": "v0.6.0",
          "draft": false,
          "prerelease": false,
          "author": { "login": "hronro", "html_url": "https://github.com/hronro" },
          "assets": [
            {
              "name": "jd-ime-v0.6.0-android-arm64.apk",
              "size": 7168499,
              "digest": "sha256:AC133958087ED90770500E398CDAB60577B19747AB6BDFFA7F4C7357F9C57EA1",
              "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-android-arm64.apk"
            },
            {
              "name": "jd-ime-v0.6.0-android-x86_64.apk",
              "size": 7168493,
              "digest": null,
              "browser_download_url": "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-android-x86_64.apk"
            },
            { "name": "broken-no-url", "size": 1 }
          ],
          "body": "notes"
        }
    """.trimIndent()

    @Test
    fun parsesTheLatestReleaseFeed() {
        val latest = LatestRelease.parse(feed)
        assertNotNull(latest)
        latest!!
        assertEquals("v0.6.0", latest.tag)
        assertEquals(ReleaseVersion(0, 6, 0), latest.version)
        assertEquals("https://github.com/hronro/ime-jd/releases/tag/v0.6.0", latest.pageUrl)
        // The asset without a download URL is dropped, the others kept in order.
        assertEquals(
            listOf("jd-ime-v0.6.0-android-arm64.apk", "jd-ime-v0.6.0-android-x86_64.apk"),
            latest.assets.map { it.name },
        )

        val arm = latest.asset("jd-ime-v0.6.0-android-arm64.apk")!!
        assertEquals(7168499L, arm.size)
        assertEquals(
            "https://github.com/hronro/ime-jd/releases/download/v0.6.0/jd-ime-v0.6.0-android-arm64.apk",
            arm.url,
        )
        // Digest hex is normalized to lowercase for comparison with MessageDigest's output.
        assertEquals("ac133958087ed90770500e398cdab60577b19747ab6bdffa7f4c7357f9c57ea1", arm.sha256)

        assertNull(latest.asset("jd-ime-v0.6.0-android-x86_64.apk")!!.sha256)
        assertNull(latest.asset("jd-ime-v0.6.0-android-armeabi-v7a.apk"))
    }

    @Test
    fun rejectsPayloadsThatAreNotAVersionedRelease() {
        assertNull(LatestRelease.parse("not json"))
        assertNull(LatestRelease.parse("""{"message": "API rate limit exceeded"}"""))
        assertNull(LatestRelease.parse("""{"tag_name": "nightly", "html_url": "https://x"}"""))
        assertNull("html_url is required", LatestRelease.parse("""{"tag_name": "v1.0.0"}"""))
        assertNull(LatestRelease.parse("""[{"tag_name": "v1.0.0"}]"""))
    }

    @Test
    fun feedWithoutAssetsStillParses() {
        val latest = LatestRelease.parse(
            """{"tag_name": "v9.9.9", "html_url": "https://github.com/hronro/ime-jd/releases/tag/v9.9.9"}""",
        )!!
        assertEquals(ReleaseVersion(9, 9, 9), latest.version)
        assertTrue(latest.assets.isEmpty())
    }

    @Test
    fun malformedDigestsAreDropped() {
        val zeros = "0".repeat(64)
        val gs = "g".repeat(64)
        val latest = LatestRelease.parse(
            """{"tag_name": "v1.0.0", "html_url": "https://x/", "assets": [
                 {"name": "a", "browser_download_url": "https://x/a", "digest": "sha256:abc"},
                 {"name": "b", "browser_download_url": "https://x/b", "digest": "md5:$zeros"},
                 {"name": "c", "browser_download_url": "https://x/c", "digest": "sha256:$gs"}
               ]}""",
        )!!
        assertEquals(3, latest.assets.size)
        assertTrue(latest.assets.all { it.sha256 == null })
    }

    // --- UpdateFeed ---------------------------------------------------------

    @Test
    fun apkNameMatchesTheReleaseWorkflow() {
        assertEquals("jd-ime-v0.6.0-android-arm64.apk", UpdateFeed.apkName("v0.6.0", "arm64-v8a"))
        assertEquals("jd-ime-v0.6.0-android-x86_64.apk", UpdateFeed.apkName("v0.6.0", "x86_64"))
        assertNull(UpdateFeed.apkName("v0.6.0", "armeabi-v7a"))
        assertNull(UpdateFeed.apkName("v0.6.0", "x86"))
    }

    @Test
    fun installableAbiFollowsDevicePreferenceOrder() {
        assertEquals("arm64-v8a", UpdateFeed.installableAbi(arrayOf("arm64-v8a", "armeabi-v7a", "armeabi")))
        assertEquals("x86_64", UpdateFeed.installableAbi(arrayOf("x86_64", "x86", "arm64-v8a")))
        assertEquals("arm64-v8a", UpdateFeed.installableAbi(arrayOf("armeabi-v7a", "arm64-v8a")))
        assertNull(UpdateFeed.installableAbi(arrayOf("armeabi-v7a", "armeabi")))
        assertNull(UpdateFeed.installableAbi(emptyArray()))
    }
}
