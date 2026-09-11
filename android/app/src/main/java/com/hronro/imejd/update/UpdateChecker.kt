// Update discovery for the Android IME — the counterpart of
// macos/JdIME/Update/UpdateManager.swift's checking half.
//
// One daily GET of the release feed (UpdateFeed), from whichever of the two
// entry points comes first: the IME service showing its keyboard, or the
// container app opening. The result is persisted in SharedPreferences so the
// app, the embedded preview, and the IME (all one process, but not one
// lifetime) read the same state: the newest known release, and whether the
// user has been shown it yet. Installing is UpdateInstaller's job.
//
// The check sends nothing but the request itself (no identifiers beyond a
// User-Agent naming this app and its version). It can be switched off in the
// container app, and never runs for placeholder 0.0.0 builds.
package com.hronro.imejd.update

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** A release newer than the installed build. */
data class AvailableUpdate(
    val tag: String,
    val version: ReleaseVersion,
    val pageUrl: String,
    /** The APK for this device's ABI — null when the release ships none for it. */
    val apk: ReleaseAsset?,
)

object UpdateChecker {

    sealed class Result {
        data class UpToDate(val current: ReleaseVersion) : Result()
        data class Available(val update: AvailableUpdate) : Result()
        data class Failed(val reason: String) : Result()
    }

    private const val PREFS = "update_state"
    private const val PREF_AUTO_CHECK = "auto_check"
    private const val PREF_LAST_CHECK = "last_check"
    private const val PREF_LATEST_TAG = "latest_tag"
    private const val PREF_LATEST_PAGE = "latest_page"
    private const val PREF_APK_NAME = "apk_name"
    private const val PREF_APK_URL = "apk_url"
    private const val PREF_APK_SIZE = "apk_size"
    private const val PREF_APK_SHA256 = "apk_sha256"
    private const val PREF_SEEN_TAG = "seen_tag"

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "jd-update").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())
    private val inFlight = AtomicBoolean(false)

    /**
     * The installed build's version (versionName, which release CI sets from
     * the tag). Null when it isn't a well-formed release version.
     */
    fun currentVersion(context: Context): ReleaseVersion? {
        val name = try {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName
        } catch (_: Exception) {
            null
        }
        return ReleaseVersion.parse(name ?: return null)
    }

    // --- Settings & recorded state -------------------------------------------

    fun isAutoCheckEnabled(context: Context): Boolean =
        prefs(context).getBoolean(PREF_AUTO_CHECK, true)

    fun setAutoCheckEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(PREF_AUTO_CHECK, enabled).apply()
    }

    /**
     * The newest release the feed has reported, if it is ahead of the
     * installed build. Persisted, so it survives the process being recycled.
     */
    fun availableUpdate(context: Context): AvailableUpdate? {
        val current = currentVersion(context) ?: return null
        val p = prefs(context)
        val tag = p.getString(PREF_LATEST_TAG, null) ?: return null
        val version = ReleaseVersion.parse(tag) ?: return null
        if (version <= current) return null
        val page = p.getString(PREF_LATEST_PAGE, null) ?: return null
        val apkName = p.getString(PREF_APK_NAME, null)
        val apkUrl = p.getString(PREF_APK_URL, null)
        val apk = if (apkName != null && apkUrl != null) {
            ReleaseAsset(apkName, apkUrl, p.getLong(PREF_APK_SIZE, 0L), p.getString(PREF_APK_SHA256, null))
        } else {
            null
        }
        return AvailableUpdate(tag, version, page, apk)
    }

    /**
     * An available update the user has not been shown yet — what the
     * keyboard's idle candidate bar announces. Cleared by [markNoticeSeen]
     * once they tap through (or open the app and see the update card).
     */
    fun pendingNotice(context: Context): AvailableUpdate? {
        val update = availableUpdate(context) ?: return null
        return update.takeIf { prefs(context).getString(PREF_SEEN_TAG, null) != it.tag }
    }

    fun markNoticeSeen(context: Context) {
        val tag = prefs(context).getString(PREF_LATEST_TAG, null) ?: return
        prefs(context).edit().putString(PREF_SEEN_TAG, tag).apply()
    }

    private fun record(context: Context, latest: LatestRelease) {
        val abi = UpdateFeed.installableAbi(Build.SUPPORTED_ABIS)
        val apk = abi?.let { UpdateFeed.apkName(latest.tag, it) }?.let { latest.asset(it) }
        prefs(context).edit()
            .putString(PREF_LATEST_TAG, latest.tag)
            .putString(PREF_LATEST_PAGE, latest.pageUrl)
            .apply {
                if (apk != null) {
                    putString(PREF_APK_NAME, apk.name)
                    putString(PREF_APK_URL, apk.url)
                    putLong(PREF_APK_SIZE, apk.size)
                    putString(PREF_APK_SHA256, apk.sha256) // null removes
                } else {
                    remove(PREF_APK_NAME); remove(PREF_APK_URL); remove(PREF_APK_SIZE); remove(PREF_APK_SHA256)
                }
            }
            .apply()
    }

    // --- Checking -----------------------------------------------------------

    /**
     * The automatic path: silently, at most once per CHECK_INTERVAL_MS, only
     * when enabled and only for real release builds. Cheap when nothing is
     * due — one prefs read. [onNewUpdate] fires on the main thread if the
     * check finds a release ahead of this build, so the caller can refresh
     * its notice without waiting for the next keyboard show.
     */
    fun checkIfDue(context: Context, onNewUpdate: (() -> Unit)? = null) {
        if (!isAutoCheckEnabled(context)) return
        val current = currentVersion(context) ?: return
        if (current.isPlaceholder) return
        val last = prefs(context).getLong(PREF_LAST_CHECK, 0L)
        if (System.currentTimeMillis() - last < UpdateFeed.CHECK_INTERVAL_MS) return
        check(context) { result ->
            if (result is Result.Available) onNewUpdate?.invoke()
        }
    }

    /** The button path: always runs, and reports the outcome. */
    fun checkNow(context: Context, callback: (Result) -> Unit) {
        if (!check(context, callback)) {
            callback(Result.Failed("正在检查中"))
        }
    }

    /** Returns false when a check is already running. */
    private fun check(context: Context, callback: (Result) -> Unit): Boolean {
        if (!inFlight.compareAndSet(false, true)) return false
        val app = context.applicationContext
        // Stamp before the request, so a failing feed is retried tomorrow
        // rather than on every keyboard show.
        prefs(app).edit().putLong(PREF_LAST_CHECK, System.currentTimeMillis()).apply()
        val current = currentVersion(app)
        executor.execute {
            val result = try {
                val latest = fetchLatest("ime-jd-android/${current ?: "0.0.0"}")
                record(app, latest)
                when {
                    current == null -> Result.Failed("无法读取当前版本")
                    latest.version > current -> Result.Available(availableUpdate(app)!!)
                    else -> Result.UpToDate(current)
                }
            } catch (e: Exception) {
                Result.Failed(e.localizedMessage ?: e.javaClass.simpleName)
            }
            inFlight.set(false)
            main.post { callback(result) }
        }
        return true
    }

    private fun fetchLatest(userAgent: String): LatestRelease {
        val conn = URL(UpdateFeed.LATEST_RELEASE_URL).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 15_000
            conn.setRequestProperty("User-Agent", userAgent)
            conn.setRequestProperty("Accept", "application/vnd.github+json")
            conn.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            val code = conn.responseCode
            if (code != HttpURLConnection.HTTP_OK) throw IOException("HTTP $code")
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            return LatestRelease.parse(body) ?: throw IOException("服务器没有返回可用的版本信息")
        } finally {
            conn.disconnect()
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
