// The user dictionary as the app keeps it — the Android counterpart of the
// iOS app's UserDictStore and keyboard loader in one, because nothing crosses
// a process here: the container app, the embedded preview and the IME service
// all run in this one process (see KeyFeedback), so one store serves them all.
// Main thread only.
//
// The phrases file in the app's private files is the single source of truth.
// Beside it, in no-backup files, the store caches the blob it compiled from
// that text, tagged with the text's hash: building is slow on low-end phones,
// and the keyboard must not pay for it at every start. A load reads the
// file's bytes, hashes them and takes the cached blob when it is that text's
// and this libjd's — no decoding, no parsing, no build; a missing, corrupt,
// stale (an app update) or mismatched blob is rebuilt and rewritten. What only
// the list needs — the text, its rows and the engine's verdict on each, which
// come from a build's notes — is worked out the first time the list asks.
//
// A context's dictionary is fixed for its lifetime, so the store never touches
// an engine: it bumps `generation` and tells its listeners, and each session
// adopts `activeDictionary` at a moment nothing is composing.
package com.hronro.imejd.userdict

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.core.util.AtomicFile
import com.hronro.imejd.engine.UserDict
import com.hronro.imejd.engine.UserDictError
import com.hronro.imejd.engine.UserDictReport
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.charset.CharacterCodingException

class UserDictStore(
    /** The phrases file: `用户自造词.txt` in the app's private files. The truth. */
    val file: File,
    /** The blob compiled from it — derived, tied to this build of libjd, so kept out of backups. */
    private val blobFile: File,
    private val prefs: SharedPreferences,
) {
    /** Why a file could not be loaded or imported. The message is for the user. */
    sealed class LoadError(message: String) : Exception(message) {
        class NotUtf8 : LoadError("文件不是 UTF-8 编码")
        class Unreadable(why: String?) : LoadError("无法读取文件：${why ?: "未知错误"}")

        /** A file picked for import without a single phrase line: not a phrase list. */
        class NoPhrases : LoadError("文件中没有词条")

        /**
         * The engine refused the whole file: too many phrases, too much text.
         * A line that does not parse is never this — it is skipped and
         * flagged on its row.
         */
        class Build(val error: UserDictError) : LoadError(
            when (error.status) {
                UserDictError.Status.TOO_MANY_ENTRIES ->
                    "第 ${error.line} 行起超过 ${UserDict.MAX_ENTRIES} 条上限"
                UserDictError.Status.TEXT_TOO_LONG -> "文件超过 8 MB 上限"
                else -> "无法编译词库（${error.message}）"
            },
        )
    }

    /** Where [dictionary] came from. */
    enum class Source {
        /** The cached blob, as it was. */
        BLOB,
        /** Built from the text: after a save, or because the cache was missing, corrupt, stale or another text's. */
        BUILT,
    }

    /**
     * One version of the file and what the list derives from it, each on
     * first use: the text, its rows, the notes of a build — the cached blob
     * carries none, so a cache hit builds for them only when they are asked
     * for — and the verdict on each row.
     */
    private class Contents(text: () -> String, notes: (String) -> UserDictReport?) {
        val text: String by lazy(text)
        val rows: List<UserDictRow> by lazy { UserDictFile.parse(this.text) }
        val report: UserDictReport? by lazy { notes(this.text) }
        val problems: List<UserDictProblem?> by lazy { UserDictProblem.forRows(rows.map { it.line }, report) }
    }

    /** The dictionary compiled from the file; null when there is no file or it could not be built. */
    var dictionary: UserDict? = null
        private set

    var source: Source? = null
        private set

    var lastError: LoadError? = null
        private set

    /** Bumped whenever [activeDictionary] may differ from what a session was created with. */
    var generation = 0
        private set

    private var contents: Contents? = null
    private val listeners = ArrayList<() -> Unit>()

    init {
        reload()
    }

    /** The file's rows, in file order. */
    val rows: List<UserDictRow> get() = contents?.rows.orEmpty()

    val entries: List<UserDictEntry> get() = rows.map { it.entry }

    /** The engine's verdict on each row; null where the row is fine. */
    val problems: List<UserDictProblem?> get() = contents?.problems.orEmpty()

    /** The notes of a build of the file; null when there is no file or it could not be built. */
    val report: UserDictReport? get() = contents?.report

    /**
     * The user's switch, off until they turn it on. Off means every engine
     * reads the built-in dictionary alone, whatever the file holds; the file
     * is kept either way.
     */
    var isEnabled: Boolean
        get() = prefs.getBoolean(PREF_ENABLED, false)
        set(value) {
            if (value == isEnabled) return
            prefs.edit().putBoolean(PREF_ENABLED, value).apply()
            changed()
        }

    /** What a session created right now should read. */
    val activeDictionary: UserDict? get() = if (isEnabled) dictionary else null

    /** One line for the list's status. */
    val statusText: String
        get() {
            lastError?.let { return "未能加载：${it.message}" }
            val dictionary = dictionary
            if (dictionary == null || rows.isEmpty()) return "尚无词条"
            return buildString {
                append("${dictionary.entries} 条生效")
                report?.let {
                    if (it.invalid > 0) append("，${it.invalid} 条无效")
                    if (it.dropped > 0) append("，${it.dropped} 条重复")
                    if (it.shared > 0) append("，${it.shared} 条同码")
                }
            }
        }

    /** Called on the main thread after anything a session or a screen should react to. */
    fun addListener(listener: () -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    // ---- Loading and saving ----

    /** Re-read the file and load its dictionary, from the cache when it can. The app is the file's only writer, so this runs once per process. */
    fun reload() {
        val started = System.nanoTime()
        try {
            load(UserDictFile.readBytes(file))
        } catch (e: IOException) {
            fail(LoadError.Unreadable(e.message))
        }
        val ms = (System.nanoTime() - started) / 1_000_000
        val dictionary = dictionary
        when {
            dictionary == null -> Log.i(TAG, "user dict: none loaded (${lastError?.message ?: "no file"})")
            source == Source.BLOB -> Log.i(TAG, "user dict: ${dictionary.entries} phrases from the cached blob in $ms ms")
            else -> Log.i(TAG, "user dict: ${dictionary.entries} phrases built from the text in $ms ms")
        }
        changed()
    }

    /**
     * Write [entries] as the whole file, as typed, then the blob built from
     * it. A file the engine refuses as a whole is still written — the rows
     * are the user's — and every session runs on the built-in dictionary
     * alone until it is fixed.
     */
    @Throws(IOException::class)
    fun save(entries: List<UserDictEntry>) {
        val text = UserDictFile.serialize(entries)
        UserDictFile.write(text, file)
        adopt(text, UserDictFile.hash(text), built = null)
        changed()
    }

    /**
     * [save], but only when the engine accepts the whole file; nothing is
     * written otherwise, and the refusal is thrown as [LoadError.Build]. A
     * typed row may push the file over the engine's caps — it is the user's,
     * and they are looking at it — but an import, appended as it is, must
     * not turn a list that works into one that does not. The build that
     * judges it is the one adopted.
     */
    @Throws(IOException::class)
    fun saveIfBuildable(entries: List<UserDictEntry>) {
        val text = UserDictFile.serialize(entries)
        val tag = UserDictFile.hash(text)
        val built = try {
            UserDict.build(text, tag)
        } catch (e: UserDictError) {
            throw LoadError.Build(e)
        }
        UserDictFile.write(text, file)
        adopt(text, tag, built)
        changed()
    }

    // ---- Exporting ----

    /** The phrases file itself, byte for byte, so what one device exports another imports as it is. */
    @Throws(IOException::class)
    fun export(to: OutputStream) {
        file.inputStream().use { it.copyTo(to) }
    }

    // ---- Duplicates ----

    /**
     * The rows libjd dropped as duplicates — of an earlier row, or of a
     * built-in word — by the notes of a build of the file, the only judge of
     * that; empty while the file could not be built, since the engine has no
     * notes then. The list shows them grey; nothing removes them but the user.
     */
    val duplicateRows: List<Int> get() = problems.indices.filter { problems[it]?.isDuplicate == true }

    /** Delete [duplicateRows], keeping the first of each. Returns how many went. */
    @Throws(IOException::class)
    fun removeDuplicates(): Int {
        val doomed = duplicateRows.toHashSet()
        if (doomed.isEmpty()) return 0
        save(entries.filterIndexed { index, _ -> index !in doomed })
        return doomed.size
    }

    /**
     * The file as read: its dictionary from the cache when the cached blob
     * is these bytes', with nothing decoded until the list asks; else the
     * text, decoded and built.
     */
    private fun load(bytes: ByteArray?) {
        if (bytes == null) {
            lastError = null
            contents = null
            dictionary = null
            source = null
            blobFile.delete()
            return
        }
        val tag = UserDictFile.hash(bytes)
        val cached = cachedBlob(tag)
        if (cached != null) {
            lastError = null
            dictionary = cached
            source = Source.BLOB
            // The blob was built from this very text, so it decodes.
            contents = Contents({ UserDictFile.decode(bytes) }) { notesOf(it) }
            return
        }
        val text = try {
            UserDictFile.decode(bytes)
        } catch (_: CharacterCodingException) {
            return fail(LoadError.NotUtf8())
        }
        adopt(text, tag, built = null)
    }

    /** Take [text], tagged [tag], as the file's: its dictionary from [built] or a build, which is then cached. */
    private fun adopt(text: String, tag: Long, built: UserDict.Built?) {
        lastError = null
        try {
            val fresh = built ?: UserDict.build(text, tag)
            dictionary = fresh.dict
            source = Source.BUILT
            contents = Contents({ text }) { fresh.report }
            cache(fresh.dict.blob)
        } catch (e: UserDictError) {
            dictionary = null
            source = null
            lastError = LoadError.Build(e)
            contents = Contents({ text }) { null }
            blobFile.delete()
        }
    }

    /** The cached blob, when this libjd built it from the text tagged [tag]; null means build. */
    private fun cachedBlob(tag: Long): UserDict? {
        val bytes = try {
            AtomicFile(blobFile).readFully()
        } catch (_: IOException) {
            return null
        }
        val dict = try {
            UserDict.fromBlob(bytes)
        } catch (_: UserDictError) {
            return null
        }
        return dict.takeIf { it.sourceTag == tag }
    }

    /** A cache that cannot be written costs the next start a build, nothing more. */
    private fun cache(blob: ByteArray) {
        val atomic = AtomicFile(blobFile)
        try {
            blobFile.parentFile?.mkdirs()
            val out = atomic.startWrite()
            try {
                out.write(blob)
                atomic.finishWrite(out)
            } catch (e: IOException) {
                atomic.failWrite(out)
                throw e
            }
        } catch (e: IOException) {
            Log.w(TAG, "user dict: cannot cache the blob", e)
            blobFile.delete()
        }
    }

    /** The notes the list shows, for a text whose dictionary came from the cache. */
    private fun notesOf(text: String): UserDictReport? = try {
        UserDict.build(text).report
    } catch (_: UserDictError) {
        null
    }

    private fun fail(error: LoadError) {
        contents = null
        dictionary = null
        source = null
        lastError = error
    }

    private fun changed() {
        generation++
        for (listener in listeners.toList()) listener()
    }

    companion object {
        private const val TAG = "JdIME"

        /** The keyboard's preferences file, shared with KeyFeedback's switches. */
        const val PREFS = "keyboard_settings"
        const val PREF_ENABLED = "user_dict_enabled"
        const val BLOB_FILE_NAME = "用户自造词.blob"

        private var shared: UserDictStore? = null

        /** The process's store, created — the file read, its dictionary loaded — on first use. */
        fun get(context: Context): UserDictStore = shared ?: run {
            val app = context.applicationContext
            UserDictStore(
                File(app.filesDir, UserDictFile.FILE_NAME),
                File(app.noBackupFilesDir, BLOB_FILE_NAME),
                app.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
            ).also { shared = it }
        }

        /**
         * A phrases file picked for import — one 键道 wrote on another
         * device, or any text in the same format — read the way the list's
         * own is: comments and blank lines skipped, every other line a row,
         * as it is. Nothing is judged here and nothing is written. A file
         * without a single phrase line is refused ([LoadError.NoPhrases]):
         * it is not a phrase list.
         */
        @Throws(LoadError::class)
        fun entriesFrom(input: InputStream): List<UserDictEntry> {
            val bytes = try {
                input.readBytes()
            } catch (e: IOException) {
                throw LoadError.Unreadable(e.message)
            }
            val text = try {
                UserDictFile.decode(bytes)
            } catch (_: CharacterCodingException) {
                throw LoadError.NotUtf8()
            }
            val entries = UserDictFile.parse(text).map { it.entry }
            if (entries.isEmpty()) throw LoadError.NoPhrases()
            return entries
        }
    }
}
