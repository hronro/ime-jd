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
import com.hronro.imejd.engine.UserDict
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.nio.ByteBuffer
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
        "# 键道用户自造词：每行一条，格式为「词<TAB>编码」，编码由 a-z 和 ; 组成，1 到 ${UserDict.MAX_KEY_LENGTH} 个字符。"

    /** The file's bytes, or null when there is no file. [decode] makes them text. */
    @Throws(IOException::class)
    fun readBytes(file: File): ByteArray? = try {
        AtomicFile(file).readFully()
    } catch (_: FileNotFoundException) {
        null
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
    fun write(text: String, file: File) {
        file.parentFile?.mkdirs()
        val atomic = AtomicFile(file)
        val out = atomic.startWrite()
        try {
            out.write(text.toByteArray(Charsets.UTF_8))
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
        val rows = ArrayList<UserDictRow>()
        text.split('\n').forEachIndexed { index, raw ->
            val line = raw.trim { it == ' ' || it == '\r' }
            if (line.isEmpty() || line.startsWith("#")) return@forEachIndexed
            val tab = line.indexOf('\t')
            val entry = if (tab < 0) {
                UserDictEntry(line, "")
            } else {
                UserDictEntry(line.substring(0, tab).trim(' '), line.substring(tab + 1).trim(' '))
            }
            rows.add(UserDictRow(index + 1, entry))
        }
        return rows
    }

    /** The header plus one `value<TAB>keys` line per entry, LF-terminated. Entry `i` lands on line `i + 2`. */
    fun serialize(entries: List<UserDictEntry>): String = buildString {
        append(HEADER).append('\n')
        for (e in entries) append(e.value).append('\t').append(e.keys).append('\n')
    }

    /**
     * FNV-1a, 64-bit, over UTF-8 — the same function as the Swift clients'.
     * It is the cached blob's source tag: a blob tagged with another hash
     * was built from another text. Taken over the file's bytes as read, so
     * a load whose cache is good never decodes the text at all; a file the
     * app wrote has no BOM, so its bytes are its text's.
     */
    fun hash(bytes: ByteArray): Long {
        var hash = -0x340d631b7bdddcdbL // 0xcbf29ce484222325
        for (byte in bytes) {
            hash = hash xor (byte.toLong() and 0xFF)
            hash *= 0x100000001b3L
        }
        return hash
    }

    fun hash(text: String): Long = hash(text.toByteArray(Charsets.UTF_8))
}
