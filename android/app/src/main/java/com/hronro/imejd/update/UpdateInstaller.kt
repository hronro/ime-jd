// Update delivery for the Android IME — the counterpart of
// macos/JdIME/Update/UpdateManager.swift's installing half.
//
// Downloads the release APK into the app's cache, verifies it against the
// feed's SHA-256, and hands it to the system PackageInstaller as a session.
// Android then asks the user to confirm (the standard "update this app?"
// sheet) and swaps the package; the signature must match the installed build,
// which the OS enforces — so the release keystore, not this code, is what
// keeps a tampered APK out. Requires REQUEST_INSTALL_PACKAGES, and the user
// once allowing this app to install apps (Settings › Install unknown apps).
package com.hronro.imejd.update

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.IntentCompat
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

object UpdateInstaller {

    sealed class Progress {
        object Downloading : Progress()
        object Verifying : Progress()
        /** Handed to the system installer; its confirmation sheet follows. */
        object Committed : Progress()
        data class Failed(val reason: String) : Progress()
    }

    private val executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "jd-update-install").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    /** Whether the user has allowed this app to install apps (API 26+ gate). */
    fun canRequestInstalls(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()

    /** The Settings screen where the user grants that, opened on this app's row. */
    fun unknownSourcesSettingsIntent(context: Context): Intent =
        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))

    /**
     * Download [apk], verify it, and commit it as a PackageInstaller session.
     * [onProgress] is called on the main thread; after [Progress.Committed]
     * the system takes over (see InstallResultReceiver).
     */
    fun downloadAndInstall(context: Context, apk: ReleaseAsset, onProgress: (Progress) -> Unit) {
        val app = context.applicationContext
        executor.execute {
            try {
                main.post { onProgress(Progress.Downloading) }
                val file = download(app, apk)
                main.post { onProgress(Progress.Verifying) }
                verify(file, apk)
                commit(app, file)
                main.post { onProgress(Progress.Committed) }
            } catch (e: Exception) {
                main.post { onProgress(Progress.Failed(e.localizedMessage ?: e.javaClass.simpleName)) }
            }
        }
    }

    private fun download(context: Context, apk: ReleaseAsset): File {
        val dir = File(context.cacheDir, "updates").apply {
            // One update at a time; stale downloads are just cache.
            listFiles()?.forEach { it.delete() }
            mkdirs()
        }
        val file = File(dir, apk.name)
        val conn = URL(apk.url).openConnection() as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.instanceFollowRedirects = true // github.com → objects.githubusercontent.com
            conn.setRequestProperty("User-Agent", "ime-jd-android")
            val code = conn.responseCode
            if (code != HttpURLConnection.HTTP_OK) throw IOException("HTTP $code")
            conn.inputStream.use { input -> file.outputStream().use { input.copyTo(it) } }
        } finally {
            conn.disconnect()
        }
        return file
    }

    private fun verify(file: File, apk: ReleaseAsset) {
        if (apk.size > 0 && file.length() != apk.size) {
            throw IOException("文件大小不符（${file.length()} ≠ ${apk.size}）")
        }
        val expected = apk.sha256 ?: return
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (actual != expected) throw IOException("SHA-256 校验失败，已放弃安装")
    }

    private fun commit(context: Context, file: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Lets the OS skip the confirmation when it deems that safe
                // (it usually still asks — we are not the installer of record).
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
        }
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            session.openWrite("jd-ime.apk", 0, file.length()).use { out ->
                file.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val intent = Intent(context, InstallResultReceiver::class.java)
                .setAction(InstallResultReceiver.ACTION)
            // MUTABLE: the installer fills the status extras into our intent.
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
            val pending = PendingIntent.getBroadcast(context, 0, intent, flags)
            session.commit(pending.intentSender)
        }
    }
}

/**
 * Receives PackageInstaller's session status. The one case that needs us is
 * PENDING_USER_ACTION: the OS hands back the confirmation activity to start.
 * Success never arrives in practice — the process is replaced by the update.
 */
class InstallResultReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "com.hronro.imejd.INSTALL_STATUS"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java)
                    ?: return
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(confirm)
            }
            PackageInstaller.STATUS_SUCCESS ->
                Toast.makeText(context, "键道输入法已更新", Toast.LENGTH_SHORT).show()
            PackageInstaller.STATUS_FAILURE_ABORTED -> Unit // the user declined
            else -> {
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "未知错误"
                Toast.makeText(context, "安装失败：$message", Toast.LENGTH_LONG).show()
            }
        }
    }
}
