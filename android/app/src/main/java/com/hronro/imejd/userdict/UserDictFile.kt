// The phrases file behind the user dictionary — libjd's own table format —
// and how its lines are read and written. Port of bindings/swift/UserDictFile.swift
// (shared by the macOS and iOS clients). No rules of its own: libjd is the
// authority on what a line means — it parses the whole file on every build,
// skips the lines that do not parse and says why, by line number — so the
// app never validates a cell; it writes what the user typed and shows the
// engine's verdict (UserDictProblem). What is mirrored here is only how a
// line is split into cells for display.
//
// One `value<TAB>keys` line per phrase, `#` comments, blank lines ignored.
// The file is read leniently — comments and blank lines are skipped, a line
// without a TAB becomes a row with empty keys so it can be fixed in place —
// and written back as one header comment plus one line per entry.
package com.hronro.imejd.userdict

import androidx.core.util.AtomicFile
import com.hronro.jd.UserDict
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/** One phrase: the committable text and the code that reaches it. */
data class UserDictEntry(val value: String, val keys: String)

/** A parsed row: the entry plus the 1-based line it came from. */
data class UserDictRow(val line: Int, val entry: UserDictEntry)

object UserDictFile {
    const val FILE_NAME = "用户自造词.txt"

    /** The first line of every file the app writes, for whoever opens it in a text editor. */
    const val HEADER =
        "# 键道用户自造词：每行一条，格式为「词<TAB>编码」，编码由 a-z 组成，开头可以有分号（;），1 到 ${UserDict.MAX_KEY_LENGTH} 个字符。"

    /** The file's bytes, or null when there is no file. [decode] makes them text. */
    @Throws(IOException::class)
    fun readBytes(file: File): ByteArray? = try {
        AtomicFile(file).readFully()
    } catch (_: FileNotFoundException) {
        null
    }

    /**
     * The file mapped read-only, or null when there is no file: its bytes
     * without a read into the heap, paged in as they are touched. Safe for
     * the files written here, which an [AtomicFile] replaces by renaming a
     * new file over the old one — a mapping keeps the file it was made from.
     */
    @Throws(IOException::class)
    fun map(file: File): MappedByteBuffer? {
        val input = try {
            AtomicFile(file).openRead()
        } catch (_: FileNotFoundException) {
            return null
        }
        return input.use { it.channel.map(FileChannel.MapMode.READ_ONLY, 0, it.channel.size()) }
    }

    /**
     * Strict UTF-8 — libjd would reject a stray byte line by line; the app
     * says so once. A UTF-8 BOM is dropped: libjd would otherwise take
     * U+FEFF as part of the first value.
     */
    @Throws(CharacterCodingException::class)
    fun decode(bytes: ByteArray): String {
        val bom = bytes.size >= 3 &&
            bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()
        val start = if (bom) 3 else 0
        return Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes, start, bytes.size - start))
            .toString()
    }

    /** Atomic replace: a reader, or a sudden kill, never sees a partial file. */
    @Throws(IOException::class)
    fun write(bytes: ByteArray, file: File) {
        file.parentFile?.mkdirs()
        val atomic = AtomicFile(file)
        val out = atomic.startWrite()
        try {
            out.write(bytes)
            atomic.finishWrite(out)
        } catch (e: IOException) {
            atomic.failWrite(out)
            throw e
        }
    }

    /**
     * Split the way libjd does — on `\n`, counting from 1, `\r` and spaces
     * trimmed from both ends — skipping comments and blank lines. Lenient on
     * purpose: fields are not validated, and a line without a TAB becomes a
     * row whose value is the whole line and whose keys are empty.
     */
    fun parse(text: String): List<UserDictRow> {
        // Indices into the text, and a String only for each field kept: a
        // list of hundreds of thousands of phrases reads in a blink, not in
        // a garbage collector's worth of throwaway lines.
        val rows = ArrayList<UserDictRow>()
        var line = 0
        var start = 0
        while (start <= text.length) {
            line++
            var end = text.indexOf('\n', start)
            if (end < 0) end = text.length
            var lo = start
            var hi = end
            start = end + 1
            while (lo < hi && (text[lo] == ' ' || text[lo] == '\r')) lo++
            while (hi > lo && (text[hi - 1] == ' ' || text[hi - 1] == '\r')) hi--
            if (lo == hi || text[lo] == '#') continue
            var tab = lo
            while (tab < hi && text[tab] != '\t') tab++
            val entry = if (tab == hi) {
                UserDictEntry(text.substring(lo, hi), "")
            } else {
                UserDictEntry(field(text, lo, tab), field(text, tab + 1, hi))
            }
            rows.add(UserDictRow(line, entry))
        }
        return rows
    }

    /** `text[from, to)`, spaces trimmed from both ends. */
    private fun field(text: String, from: Int, to: Int): String {
        var lo = from
        var hi = to
        while (lo < hi && text[lo] == ' ') lo++
        while (hi > lo && text[hi - 1] == ' ') hi--
        return text.substring(lo, hi)
    }

    /** The header plus one `value<TAB>keys` line per entry, LF-terminated. Entry `i` lands on line `i + 2`. */
    fun serialize(entries: List<UserDictEntry>): String = buildString {
        append(HEADER).append('\n')
        for (e in entries) append(e.value).append('\t').append(e.keys).append('\n')
    }
}
