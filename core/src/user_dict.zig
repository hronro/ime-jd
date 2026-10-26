//! Runtime-built user dictionary: blob format, builder, validator, lookups.
//!
//! The embedded trie is generated at build time and lives in rodata. A user
//! dictionary is the host's: it builds a *blob* with `build` from
//! `value<TAB>keys` lines (the same line format as `tables/*.txt`), caches
//! the bytes wherever it likes, and hands them to `jd_init`, keeping that
//! memory alive and unmoved until `jd_deinit`. Nothing in this file
//! allocates — `build` works entirely inside the host's output buffer, and
//! `fromBytes` is a view over the host's bytes.
//!
//! Layout — one flat, 4-byte-aligned buffer:
//!
//!   [Header][Entry × entry_count][strings pool]
//!
//! Entries are sorted by key length, then by the keys themselves in
//! `trie.keyRank` order (keys are stored as rank bytes 0..25, so a plain
//! byte comparison *is* keyRank order), then by position in the source
//! text. That is exactly the order `pagination.NodePagination` enumerates a
//! trie subtree in — shorter completions first, ties by key rank — so the
//! two sources merge with a two-way merge and no re-sorting. The entries of
//! length L occupy `[length_starts[L-1], length_starts[L])`, which turns
//! "every entry below prefix P" into one binary search per length and
//! needs no per-context buffer at all; swapping dictionaries is therefore
//! just creating a context with a different blob.
//!
//! `fromBytes` validates everything a corrupt or stale cache could get
//! wrong — sizes, offsets, sort order, key alphabet, NUL terminators,
//! UTF-8 — in one linear pass, so the engine never trusts host bytes.
//! The header also records which built-in dictionary the blob was built
//! against: `build` drops phrases that duplicate a built-in word, so a blob
//! is only valid for the dictionary it was deduplicated against, and a
//! fingerprint mismatch is reported as `stale` (rebuild from the phrases).
//! A host-defined 64-bit `source_tag` travels in the header too, so a host
//! can tell whether a cached blob still matches the phrases it has — a
//! file's modification time, a content hash, a database revision — without
//! a sidecar file. The engine never interprets it.

const std = @import("std");
const testing = std.testing;
const trie_mod = @import("trie");
const Trie = trie_mod.Trie;

/// Longest key sequence, shared with the trie (`Context.pressed_keys` is
/// sized to it).
pub const MAX_KEYS_LEN: usize = trie_mod.MAX_KEYS_LEN;

/// Hard cap on phrases per dictionary. Mirrors `JD_USER_DICT_MAX_ENTRIES`
/// in `include/jd.h`; reported through `jd_abi_layout`.
pub const MAX_ENTRIES: u32 = 10_000;

/// Longest phrase value in bytes, excluding the NUL. Mirrors
/// `JD_USER_DICT_VALUE_MAX`. Independent of the built-in tables so the
/// commit-length bound (`JD_ABI_MAX_COMMIT_LEN`) is stable across releases.
pub const VALUE_MAX: u32 = 255;

/// Hard cap on the input text handed to `build`. Mirrors
/// `JD_USER_DICT_TEXT_MAX`. Source offsets and line numbers are tracked in
/// 32-bit fields during the build (see `Entry`); a real dictionary is far
/// below this.
pub const TEXT_MAX: usize = 8 * 1024 * 1024;

/// Bumped whenever the blob layout changes; an older blob then validates
/// as `stale` and the host rebuilds it from the phrases it persisted.
pub const FORMAT_VERSION: u32 = 1;

const MAGIC: [4]u8 = "JDUD".*;
/// Written natively; reads back wrong on a blob from the other endianness.
const ENDIAN_TAG: u32 = 0x0102_0304;
/// User keys are letters only, so every stored rank is below this; ';'
/// (rank 26) is the built-in symbol codes' key — see `parseLine`.
const LETTERS: u8 = 26;

/// Mirrors the `JD_USER_DICT_*` status codes in `include/jd.h`. These are
/// failures of a call as a whole; a line that does not parse is not one —
/// `build` skips it and leaves a `Note` saying why.
pub const Status = enum(u32) {
    ok = 0,
    /// `build`: the output buffer is smaller than `blobBound` requires.
    buffer_too_small = 1,
    /// `build`: more than `MAX_ENTRIES` phrases.
    too_many_entries = 2,
    /// `check`/`jd_init`: built by a different libjd (format version,
    /// endianness, or built-in dictionary differ). Rebuild it.
    stale = 3,
    /// `check`/`jd_init`: structurally invalid. Rebuild it.
    corrupt = 4,
    /// `check`/`jd_init`/`build`: the blob pointer is not 4-byte aligned.
    misaligned = 5,
    /// `build`: the input text exceeds `TEXT_MAX`.
    text_too_long = 6,
};

/// Mirrors `jd_user_dict_report` in `include/jd.h`.
pub const Report = extern struct {
    /// A `Status` value.
    status: u32,
    /// 1-based line of the input the status refers to; 0 when it refers
    /// to the whole call.
    line: u32,
    /// Phrases that made it into the blob.
    entries: u32,
    /// Phrases dropped as exact duplicates — of an earlier line with the
    /// same keys and value, or of a built-in word on the same code.
    dropped: u32,
    /// Kept phrases on a shared code (重码): a built-in word, another kept
    /// phrase, or both already sit on it.
    shared: u32,
    /// Lines skipped because they do not parse: no TAB, bad keys, or a bad
    /// value.
    invalid: u32,
    /// Notes `build` left past the blob — one per dropped, shared or
    /// skipped line, so `dropped + shared + invalid` — ascending by line.
    notes: u32,
    /// Byte offset of the notes in the host's buffer, 4-byte aligned.
    notes_offset: u32,

    pub const empty: Report = .{
        .status = 0,
        .line = 0,
        .entries = 0,
        .dropped = 0,
        .shared = 0,
        .invalid = 0,
        .notes = 0,
        .notes_offset = 0,
    };
};

/// Mirrors `jd_user_dict_note` in `include/jd.h`: one thing `build` has
/// to say about an input line. A skipped line — it does not parse —
/// carries exactly one of `malformed`, `bad_keys` and `bad_value`, and
/// nothing else; a dropped line carries a `repeats_*` flag; a kept line
/// whose code is already taken carries `code_in_*` flags.
pub const Note = extern struct {
    /// 1-based input line.
    line: u32,
    /// `NoteFlag` bits.
    flags: u32,
    /// A kept line this one relates to: for a repeat, the line it repeats
    /// (0 for a built-in word); for a shared code, the first kept line on
    /// that code — and for that first line, the second. 0 otherwise.
    other: u32,
    /// Built-in words on exactly this code; 0 on a skipped line.
    builtin: u32,
    /// Other kept lines on exactly this code; 0 on a dropped or skipped
    /// line.
    peers: u32,
};

/// Mirrors the `JD_USER_DICT_LINE_*` flags.
pub const NoteFlag = struct {
    /// Dropped: same keys and value as the kept line `other`.
    pub const repeats_line: u32 = 0x1;
    /// Dropped: same keys and value as a built-in word.
    pub const repeats_builtin: u32 = 0x2;
    /// Kept: a built-in word sits on exactly this code; the phrase is
    /// listed ahead of it.
    pub const code_in_builtin: u32 = 0x4;
    /// Kept: the kept line `other` sits on this code too; file order
    /// decides between them.
    pub const code_in_line: u32 = 0x8;
    /// Skipped: neither blank nor a comment, and no TAB.
    pub const malformed: u32 = 0x10;
    /// Skipped: keys empty, longer than `MAX_KEYS_LEN`, or not all a-z.
    pub const bad_keys: u32 = 0x20;
    /// Skipped: value empty, longer than `VALUE_MAX`, not UTF-8, or
    /// containing control bytes.
    pub const bad_value: u32 = 0x40;
};

/// Mirrors `jd_user_dict_info` in `include/jd.h`: what `check` can tell
/// about a valid blob without the host re-parsing anything.
pub const Info = extern struct {
    /// The host-defined tag `build` was given.
    source_tag: u64,
    /// Phrases in the blob.
    entries: u32,
};

/// Fixed header at offset 0 of the blob. Every multi-byte field is in the
/// building machine's native byte order; `endian_tag` catches a blob that
/// crossed over from the other endianness.
pub const Header = extern struct {
    magic: [4]u8,
    format_version: u32,
    endian_tag: u32,
    /// `tables.blob_fingerprint` of the built-in trie this blob was
    /// deduplicated against.
    base_fingerprint: u32,
    entry_count: u32,
    /// Bytes in the strings pool, NULs included.
    strings_total: u32,
    /// Whole blob length — what `build` returned.
    total_len: u32,
    /// Longest value in bytes, excluding its NUL.
    max_value_len: u32,
    /// The host's `source_tag`, split so the header stays 4-byte aligned.
    source_tag_lo: u32,
    source_tag_hi: u32,
    /// Entries of key length L occupy `[length_starts[L-1], length_starts[L])`.
    /// `length_starts[0]` is 0 and `length_starts[MAX_KEYS_LEN]` is
    /// `entry_count`.
    length_starts: [MAX_KEYS_LEN + 1]u32,
};

/// 16-byte entry. Keys are rank bytes (see `trie.keyRank`), zero-padded
/// beyond `keys_len`.
///
/// While `build` runs — between its second pass and its third — the two
/// value fields describe the *source text* instead: `value_off` is the
/// value's offset in the input, and `value_len` packs the 1-based line
/// number above the byte length (`line << 8 | len`), which is what lets
/// dropped phrases be reported by line without a second scan of the text.
/// `VALUE_MAX` fits in 8 bits and `TEXT_MAX` keeps line numbers below 2^24,
/// so the packing is lossless; the third pass writes the final fields.
pub const Entry = extern struct {
    keys: [MAX_KEYS_LEN]u8,
    keys_len: u8,
    _pad: u8,
    /// Offset into the strings pool; the value is NUL-terminated there.
    value_off: u32,
    /// Value length in bytes, excluding the NUL.
    value_len: u32,

    inline fn ranks(self: *const Entry) []const u8 {
        return self.keys[0..self.keys_len];
    }

    // Build-time views of the packed `value_len` (see the struct docs).
    inline fn srcLen(self: Entry) u32 {
        return self.value_len & 0xFF;
    }

    inline fn srcLine(self: Entry) u32 {
        return self.value_len >> 8;
    }
};

comptime {
    // Entries follow the header directly, so the header must keep them
    // 4-aligned; the per-entry size is part of the on-disk format.
    std.debug.assert(@sizeOf(Header) % @alignOf(Entry) == 0);
    std.debug.assert(@alignOf(Header) == 4);
    std.debug.assert(@sizeOf(Entry) == 16);
    // Notes are part of the ABI too, and are laid out 4-aligned past the blob.
    std.debug.assert(@sizeOf(Note) == 20);
    std.debug.assert(@alignOf(Note) == 4);
    std.debug.assert(MAX_KEYS_LEN <= 255);
    // The build-time packing in `Entry.value_len`.
    std.debug.assert(VALUE_MAX <= 0xFF);
    std.debug.assert(TEXT_MAX + 1 < (1 << 24));
}

/// A half-open range of entry indices.
pub const Range = struct {
    start: u32,
    end: u32,

    pub inline fn len(self: Range) u32 {
        return self.end - self.start;
    }
};

pub const Error = error{ Misaligned, Corrupt, Stale };

fn statusOf(err: Error) Status {
    return switch (err) {
        error.Misaligned => .misaligned,
        error.Corrupt => .corrupt,
        error.Stale => .stale,
    };
}

/// Runtime view over a validated blob. Plain slices into the host's
/// bytes — copy it freely, it owns nothing.
pub const UserDict = struct {
    entries: []const Entry,
    strings: []const u8,
    length_starts: [MAX_KEYS_LEN + 1]u32,
    max_value_len: u32,
    source_tag: u64,

    /// Validate `bytes` as a blob built against the trie whose fingerprint
    /// is `expected_fingerprint`, and view it. One linear pass; allocates
    /// nothing. The returned view points into `bytes`.
    pub fn fromBytes(bytes: []const u8, expected_fingerprint: u32) Error!UserDict {
        if (!std.mem.isAligned(@intFromPtr(bytes.ptr), 4)) return error.Misaligned;
        if (bytes.len < @sizeOf(Header)) return error.Corrupt;
        const aligned: []align(4) const u8 = @alignCast(bytes);
        const h: *const Header = @ptrCast(aligned.ptr);

        if (!std.mem.eql(u8, &h.magic, &MAGIC)) return error.Corrupt;
        if (h.format_version != FORMAT_VERSION or h.endian_tag != ENDIAN_TAG) return error.Stale;
        if (h.base_fingerprint != expected_fingerprint) return error.Stale;
        if (h.entry_count > MAX_ENTRIES) return error.Corrupt;

        const n: usize = h.entry_count;
        const strings_start: usize = @sizeOf(Header) + n * @sizeOf(Entry);
        const total: usize = strings_start + @as(usize, h.strings_total);
        if (@as(usize, h.total_len) != total or total > bytes.len) return error.Corrupt;

        const entries: []const Entry = std.mem.bytesAsSlice(
            Entry,
            @as([]align(4) const u8, @alignCast(aligned[@sizeOf(Header)..strings_start])),
        );
        const strings = bytes[strings_start..total];

        const starts = h.length_starts;
        if (starts[0] != 0 or starts[MAX_KEYS_LEN] != h.entry_count) return error.Corrupt;
        var max_value_len: u32 = 0;
        for (1..MAX_KEYS_LEN + 1) |len| {
            const lo = starts[len - 1];
            const hi = starts[len];
            if (hi < lo) return error.Corrupt;
            var i = lo;
            while (i < hi) : (i += 1) {
                const e = &entries[i];
                if (e.keys_len != len or e._pad != 0) return error.Corrupt;
                for (e.keys[0..len]) |r| if (r >= LETTERS) return error.Corrupt;
                for (e.keys[len..]) |r| if (r != 0) return error.Corrupt;
                if (e.value_len == 0 or e.value_len > VALUE_MAX) return error.Corrupt;
                const end = @as(u64, e.value_off) + e.value_len;
                if (end >= strings.len) return error.Corrupt;
                const v = strings[e.value_off..][0..e.value_len];
                if (strings[@intCast(end)] != 0) return error.Corrupt;
                if (!isCleanValue(v)) return error.Corrupt;
                if (i > lo and std.mem.order(u8, entries[i - 1].keys[0..len], e.keys[0..len]) == .gt) {
                    return error.Corrupt;
                }
                max_value_len = @max(max_value_len, e.value_len);
            }
        }
        if (h.max_value_len != max_value_len) return error.Corrupt;

        return .{
            .entries = entries,
            .strings = strings,
            .length_starts = starts,
            .max_value_len = max_value_len,
            .source_tag = (@as(u64, h.source_tag_hi) << 32) | h.source_tag_lo,
        };
    }

    /// `fromBytes` as a status code, for the C ABI, filling `info` when the
    /// blob is valid.
    pub fn check(bytes: []const u8, expected_fingerprint: u32, info: ?*Info) Status {
        const d = fromBytes(bytes, expected_fingerprint) catch |err| return statusOf(err);
        if (info) |out| out.* = .{ .source_tag = d.source_tag, .entries = d.count() };
        return .ok;
    }

    pub inline fn count(self: *const UserDict) u32 {
        return @intCast(self.entries.len);
    }

    /// NUL-terminated pointer to an entry's value, inside the host's blob.
    pub fn valuePtr(self: *const UserDict, entry: *const Entry) [*:0]const u8 {
        return @ptrCast(&self.strings[entry.value_off]);
    }

    fn bucket(self: *const UserDict, length: usize) []const Entry {
        return self.entries[self.length_starts[length - 1]..self.length_starts[length]];
    }

    fn cmpPrefix(prefix_ranks: []const u8, item: Entry) std.math.Order {
        return std.mem.order(u8, prefix_ranks, item.keys[0..prefix_ranks.len]);
    }

    /// The entries of exactly `length` keys whose keys start with
    /// `prefix_ranks` (rank-encoded), as absolute entry indices. Empty when
    /// the prefix is longer than `length`.
    pub fn rangeFor(self: *const UserDict, length: usize, prefix_ranks: []const u8) Range {
        const base = self.length_starts[length - 1];
        if (prefix_ranks.len > length) return .{ .start = base, .end = base };
        const lo, const hi = std.sort.equalRange(Entry, self.bucket(length), prefix_ranks, cmpPrefix);
        return .{ .start = base + @as(u32, @intCast(lo)), .end = base + @as(u32, @intCast(hi)) };
    }

    /// How many entries sit at or below the key-byte prefix.
    pub fn countUnder(self: *const UserDict, prefix_keys: []const u8) u32 {
        if (prefix_keys.len > MAX_KEYS_LEN) return 0;
        var buf: [MAX_KEYS_LEN]u8 = undefined;
        const ranks = ranksOf(prefix_keys, &buf);
        var total: u32 = 0;
        var len: usize = @max(ranks.len, 1);
        while (len <= MAX_KEYS_LEN) : (len += 1) total += self.rangeFor(len, ranks).len();
        return total;
    }

    /// Whether any entry sits at or below the key-byte prefix — the user
    /// dictionary's half of "does this node have a child".
    pub fn hasPath(self: *const UserDict, prefix_keys: []const u8) bool {
        if (prefix_keys.len > MAX_KEYS_LEN) return false;
        var buf: [MAX_KEYS_LEN]u8 = undefined;
        const ranks = ranksOf(prefix_keys, &buf);
        var len: usize = @max(ranks.len, 1);
        while (len <= MAX_KEYS_LEN) : (len += 1) {
            if (self.rangeFor(len, ranks).len() != 0) return true;
        }
        return false;
    }
};

/// Rank-encode a key-byte prefix (a-z, ';') into `buf`. The caller
/// guarantees the bytes are in the alphabet and fit. A prefix with ';'
/// in it matches no entry: user keys are letters only.
pub fn ranksOf(keys: []const u8, buf: *[MAX_KEYS_LEN]u8) []const u8 {
    for (keys, 0..) |k, i| buf[i] = trie_mod.keyRank(k);
    return buf[0..keys.len];
}

/// One pass over `v`: well-formed UTF-8 (the Unicode byte-sequence table,
/// so no overlong forms, no surrogates, nothing above U+10FFFF) with no C0
/// control byte and no DEL. Values are checked on every build and on every
/// load, so this is validation's hot loop; it stays a single pass.
fn isCleanValue(v: []const u8) bool {
    var i: usize = 0;
    while (i < v.len) {
        const b = v[i];
        if (b < 0x80) {
            if (b < 0x20 or b == 0x7f) return false;
            i += 1;
            continue;
        }
        // Lead byte → sequence length and the range its second byte may
        // take; every later continuation byte is 80..BF.
        var len: usize = undefined;
        var lo: u8 = 0x80;
        var hi: u8 = 0xBF;
        switch (b) {
            0xC2...0xDF => len = 2,
            0xE0 => {
                len = 3;
                lo = 0xA0;
            },
            0xE1...0xEC, 0xEE...0xEF => len = 3,
            0xED => {
                len = 3;
                hi = 0x9F;
            },
            0xF0 => {
                len = 4;
                lo = 0x90;
            },
            0xF1...0xF3 => len = 4,
            0xF4 => {
                len = 4;
                hi = 0x8F;
            },
            else => return false,
        }
        if (v.len - i < len) return false;
        const b1 = v[i + 1];
        if (b1 < lo or b1 > hi) return false;
        var j: usize = 2;
        while (j < len) : (j += 1) {
            const c = v[i + j];
            if (c < 0x80 or c > 0xBF) return false;
        }
        i += len;
    }
    return true;
}

// =========================================================================
// Builder
// =========================================================================

fn lineCount(phrases: []const u8) usize {
    return std.mem.count(u8, phrases, "\n") + 1;
}

/// Where `build` leaves its notes: just past the largest blob the text can
/// produce — one entry and one NUL per line, plus the text itself for the
/// values — rounded up to 4.
fn notesOffset(phrases: []const u8) usize {
    const lines = lineCount(phrases);
    return std.mem.alignForward(usize, @sizeOf(Header) + lines * @sizeOf(Entry) + phrases.len + lines, 4);
}

/// Upper bound on what `build` writes into the host's buffer from
/// `phrases`: the blob, and past it one `Note` per line. Pure arithmetic
/// over a newline count — size the output buffer with it.
pub fn blobBound(phrases: []const u8) usize {
    return notesOffset(phrases) + lineCount(phrases) * @sizeOf(Note);
}

const Line = struct {
    value: []const u8,
    keys: []const u8,
};

const ParseError = error{ MalformedLine, BadKeys, BadValue };

/// Parse one raw line. Null for blank and comment lines. The rules are the
/// table files' (`scripts/gen_trie.zig`), tightened: empty keys and empty
/// values are errors rather than silently skipped, and keys are letters
/// only. In the built-in tables `;` appears only in the symbol codes,
/// which all start with it; users do not define symbols, and a user code
/// with `;` after a prefix would make that key descend there instead of
/// committing the second candidate (`query.zig`, case B).
fn parseLine(raw: []const u8) ParseError!?Line {
    const trimmed = std.mem.trim(u8, raw, " \r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const tab = std.mem.findScalar(u8, trimmed, '\t') orelse return error.MalformedLine;
    const value = std.mem.trim(u8, trimmed[0..tab], " ");
    const keys = std.mem.trim(u8, trimmed[tab + 1 ..], " ");
    if (keys.len == 0 or keys.len > MAX_KEYS_LEN) return error.BadKeys;
    for (keys) |k| if (k < 'a' or k > 'z') return error.BadKeys;
    if (value.len == 0 or value.len > VALUE_MAX or !isCleanValue(value)) return error.BadValue;
    return .{ .value = value, .keys = keys };
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    if (a.keys_len != b.keys_len) return a.keys_len < b.keys_len;
    return switch (std.mem.order(u8, a.ranks(), b.ranks())) {
        .lt => true,
        .gt => false,
        // Same code: keep source order (`value_off` is the source offset
        // at this point, so it is monotonic in line order).
        .eq => a.value_off < b.value_off,
    };
}

fn sameKeys(a: Entry, b: Entry) bool {
    return a.keys_len == b.keys_len and std.mem.eql(u8, a.ranks(), b.ranks());
}

/// Does the built-in trie already carry `value` on exactly this code?
fn baseHas(base: *const Trie, entry: Entry, value: []const u8) bool {
    var node = base.root();
    for (entry.ranks()) |r| {
        node = node.getChild(base, trie_mod.keyOfRank(r)) orelse return false;
    }
    const vals = node.values(base);
    for (0..vals.len()) |i| {
        if (std.mem.eql(u8, vals.at(i), value)) return true;
    }
    return false;
}

/// How many words the built-in trie carries on exactly this code — 0 when
/// it does not even have the path.
fn baseWordCount(base: *const Trie, entry: Entry) u32 {
    var node = base.root();
    for (entry.ranks()) |r| {
        node = node.getChild(base, trie_mod.keyOfRank(r)) orelse return 0;
    }
    return @intCast(node.values(base).len());
}

fn fail(report: *Report, status: Status, line: u32) usize {
    report.status = @backingInt(status);
    report.line = line;
    return 0;
}

fn noteLineLessThan(_: void, a: Note, b: Note) bool {
    return a.line < b.line;
}

/// Build a blob from `phrases` into `out`, which must hold at least
/// `blobBound(phrases)` bytes. Returns the blob's length, or 0 with
/// `report.status` set — for a problem with the call as a whole only: a
/// line that does not parse is skipped, never fatal. Drops exact
/// duplicates — of an earlier line with the same keys and value, and of a
/// built-in word on the same code in `base` — and records `fingerprint` so
/// `fromBytes` can tell the blob was deduplicated against that trie.
/// `source_tag` is stored for the host and never interpreted.
///
/// Past the blob, at `report.notes_offset`, it leaves one `Note` per line
/// that was skipped or dropped and per kept phrase whose code is shared,
/// ascending by line; `report.notes` counts them. Allocates nothing: the
/// sort, the strings pool and the notes are all laid out inside `out`.
pub fn build(
    phrases: []const u8,
    out: []align(4) u8,
    base: *const Trie,
    fingerprint: u32,
    source_tag: u64,
    report: *Report,
) usize {
    report.* = Report.empty;
    if (phrases.len > TEXT_MAX) return fail(report, .text_too_long, 0);
    // The bound is the contract: room for every entry, the whole text as
    // values, and one note per line past the largest possible blob.
    if (out.len < blobBound(phrases)) return fail(report, .buffer_too_small, 0);
    const lines = lineCount(phrases);
    const notes_off = notesOffset(phrases);
    const notes: []Note = std.mem.bytesAsSlice(
        Note,
        @as([]align(4) u8, @alignCast(out[notes_off..][0 .. lines * @sizeOf(Note)])),
    );
    var note_count: u32 = 0;

    // ---- Pass 1: one entry per line that parses, values still referenced
    // by their offset in the source text and their line number (see
    // `Entry`). A line that does not parse is skipped with a note saying
    // why. The entry region is sized for every line; the bound covers it. ----
    const slots: []Entry = std.mem.bytesAsSlice(
        Entry,
        @as([]align(4) u8, @alignCast(out[@sizeOf(Header)..][0 .. lines * @sizeOf(Entry)])),
    );
    var n: u32 = 0;
    var invalid: u32 = 0;
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, phrases, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = (parseLine(raw) catch |err| {
            notes[note_count] = .{
                .line = line_no,
                .flags = switch (err) {
                    error.MalformedLine => NoteFlag.malformed,
                    error.BadKeys => NoteFlag.bad_keys,
                    error.BadValue => NoteFlag.bad_value,
                },
                .other = 0,
                .builtin = 0,
                .peers = 0,
            };
            note_count += 1;
            invalid += 1;
            continue;
        }) orelse continue;
        if (n == MAX_ENTRIES) return fail(report, .too_many_entries, line_no);
        var e: Entry = .{
            .keys = @splat(0),
            .keys_len = @intCast(line.keys.len),
            ._pad = 0,
            .value_off = @intCast(@intFromPtr(line.value.ptr) - @intFromPtr(phrases.ptr)),
            .value_len = (line_no << 8) | @as(u32, @intCast(line.value.len)),
        };
        for (line.keys, 0..) |k, j| e.keys[j] = trie_mod.keyRank(k);
        slots[n] = e;
        n += 1;
    }
    const entries = slots[0..n];

    // ---- Sort into enumeration order, then drop duplicates. The order is
    // total (source offset breaks ties), so the result is deterministic. ----
    std.sort.pdq(Entry, entries, {}, lessThan);
    var kept: u32 = 0;
    var dropped: u32 = 0;
    for (entries) |e| {
        const value = phrases[e.value_off..][0..e.srcLen()];
        // Entries on the same code are adjacent; scan back over the ones
        // already kept for an exact repeat.
        var repeats_line: u32 = 0;
        var j = kept;
        while (j > 0) : (j -= 1) {
            const k = entries[j - 1];
            if (!sameKeys(k, e)) break;
            if (std.mem.eql(u8, phrases[k.value_off..][0..k.srcLen()], value)) {
                repeats_line = k.srcLine();
                break;
            }
        }
        if (repeats_line == 0 and !baseHas(base, e, value)) {
            entries[kept] = e;
            kept += 1;
            continue;
        }
        notes[note_count] = .{
            .line = e.srcLine(),
            .flags = if (repeats_line != 0) NoteFlag.repeats_line else NoteFlag.repeats_builtin,
            .other = repeats_line,
            .builtin = baseWordCount(base, e),
            .peers = 0,
        };
        note_count += 1;
        dropped += 1;
    }

    // ---- Notes for the kept phrases whose code is already taken — by a
    // built-in word, by another kept phrase, or both. Same-code phrases are
    // adjacent, so this is one walk over the groups, one trie walk each. ----
    var shared: u32 = 0;
    var g: usize = 0;
    while (g < kept) {
        var end = g + 1;
        while (end < kept and sameKeys(entries[g], entries[end])) end += 1;
        const builtin = baseWordCount(base, entries[g]);
        const peers: u32 = @intCast(end - g - 1);
        if (builtin != 0 or peers != 0) {
            var flags: u32 = 0;
            if (builtin != 0) flags |= NoteFlag.code_in_builtin;
            if (peers != 0) flags |= NoteFlag.code_in_line;
            for (g..end) |m| {
                const other: u32 = if (peers == 0)
                    0
                else if (m == g)
                    entries[g + 1].srcLine()
                else
                    entries[g].srcLine();
                notes[note_count] = .{
                    .line = entries[m].srcLine(),
                    .flags = flags,
                    .other = other,
                    .builtin = builtin,
                    .peers = peers,
                };
                note_count += 1;
            }
            shared += @intCast(end - g);
        }
        g = end;
    }
    std.sort.pdq(Note, notes[0..note_count], {}, noteLineLessThan);

    // ---- Pass 3: strings pool right after the surviving entries, values
    // now addressed by pool offset ----
    const pool_start = @sizeOf(Header) + @as(usize, kept) * @sizeOf(Entry);
    var pos: usize = pool_start;
    var max_value_len: u32 = 0;
    for (entries[0..kept]) |*e| {
        const value = phrases[e.value_off..][0..e.srcLen()];
        @memcpy(out[pos..][0..value.len], value);
        out[pos + value.len] = 0;
        e.value_off = @intCast(pos - pool_start);
        e.value_len = @intCast(value.len);
        pos += value.len + 1;
        max_value_len = @max(max_value_len, e.value_len);
    }

    var starts: [MAX_KEYS_LEN + 1]u32 = @splat(0);
    {
        var idx: u32 = 0;
        for (1..MAX_KEYS_LEN + 1) |len| {
            while (idx < kept and entries[idx].keys_len == len) idx += 1;
            starts[len] = idx;
        }
    }

    const header: *Header = @ptrCast(out.ptr);
    header.* = .{
        .magic = MAGIC,
        .format_version = FORMAT_VERSION,
        .endian_tag = ENDIAN_TAG,
        .base_fingerprint = fingerprint,
        .entry_count = kept,
        .strings_total = @intCast(pos - pool_start),
        .total_len = @intCast(pos),
        .max_value_len = max_value_len,
        .source_tag_lo = @truncate(source_tag),
        .source_tag_hi = @truncate(source_tag >> 32),
        .length_starts = starts,
    };
    report.* = .{
        .status = 0,
        .line = 0,
        .entries = kept,
        .dropped = dropped,
        .shared = shared,
        .invalid = invalid,
        .notes = note_count,
        .notes_offset = @intCast(notes_off),
    };
    return pos;
}

// =========================================================================
// Test / host-side convenience: build into a fresh aligned allocation.
// =========================================================================

pub const Blob = struct {
    buf: []align(4) u8,
    len: usize,
    report: Report,

    pub fn bytes(self: *const Blob) []align(4) const u8 {
        return self.buf[0..self.len];
    }

    pub fn dict(self: *const Blob, fingerprint: u32) Error!UserDict {
        return UserDict.fromBytes(self.bytes(), fingerprint);
    }

    /// The notes `build` left past the blob.
    pub fn notes(self: *const Blob) []const Note {
        const r = self.report;
        if (r.notes == 0) return &.{};
        return std.mem.bytesAsSlice(
            Note,
            @as([]align(4) const u8, @alignCast(self.buf[r.notes_offset..][0 .. r.notes * @sizeOf(Note)])),
        );
    }

    pub fn deinit(self: *Blob, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }
};

/// `build` into an allocation sized by `blobBound`, with a zero source tag.
/// Fails with `error.BuildFailed` when the report carries a non-ok status;
/// the report is still returned through `err_report` when given.
pub fn buildAlloc(
    allocator: std.mem.Allocator,
    phrases: []const u8,
    base: *const Trie,
    fingerprint: u32,
    err_report: ?*Report,
) !Blob {
    const buf = try allocator.alignedAlloc(u8, .@"4", blobBound(phrases));
    errdefer allocator.free(buf);
    var report: Report = undefined;
    const len = build(phrases, buf, base, fingerprint, 0, &report);
    if (report.status != 0) {
        if (err_report) |r| r.* = report;
        return error.BuildFailed;
    }
    return .{ .buf = buf, .len = len, .report = report };
}

// =========================================================================
// Tests
// =========================================================================

const FP: u32 = 0xC0FF_EE01;

fn emptyBase(allocator: std.mem.Allocator) !trie_mod.TrieHandle {
    return trie_mod.buildTrie(allocator, &.{
        .{ .keys = "zz", .value = "占位" },
    });
}

fn keysOf(d: *const UserDict, i: usize, buf: *[MAX_KEYS_LEN]u8) []const u8 {
    const e = &d.entries[i];
    for (e.ranks(), 0..) |r, j| buf[j] = trie_mod.keyOfRank(r);
    return buf[0..e.keys_len];
}

fn valueOf(d: *const UserDict, i: usize) []const u8 {
    return std.mem.sliceTo(d.valuePtr(&d.entries[i]), 0);
}

test "build + fromBytes round-trip, in enumeration order" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);

    // Deliberately unsorted; same code keeps file order.
    const text =
        "# comment\n" ++
        "丁\tacd\n" ++
        "\n" ++
        "乙\tab\n" ++
        "末尾\taz\r\n" ++
        "甲\ta\n" ++
        "乙2\tab\n" ++
        "  戊  \t  b  \n";
    var blob = try buildAlloc(testing.allocator, text, &base.trie, FP, null);
    defer blob.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 6), blob.report.entries);
    try testing.expectEqual(@as(u32, 0), blob.report.dropped);
    try testing.expectEqual(@as(u32, 0), blob.report.status);
    try testing.expect(blob.len <= blobBound(text));

    const d = try blob.dict(FP);
    try testing.expectEqual(@as(u32, 6), d.count());

    const expected = [_]struct { keys: []const u8, value: []const u8 }{
        .{ .keys = "a", .value = "甲" },
        .{ .keys = "b", .value = "戊" },
        .{ .keys = "ab", .value = "乙" },
        .{ .keys = "ab", .value = "乙2" },
        .{ .keys = "az", .value = "末尾" },
        .{ .keys = "acd", .value = "丁" },
    };
    var buf: [MAX_KEYS_LEN]u8 = undefined;
    for (expected, 0..) |want, i| {
        try testing.expectEqualStrings(want.keys, keysOf(&d, i, &buf));
        try testing.expectEqualStrings(want.value, valueOf(&d, i));
    }
    try testing.expectEqualSlices(u32, &.{ 0, 2, 5, 6, 6, 6, 6 }, &d.length_starts);
    try testing.expectEqual(@as(u32, "末尾".len), d.max_value_len);
}

test "lookups: ranges per length, counts and paths under a prefix" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);
    var blob = try buildAlloc(testing.allocator, "甲\ta\n乙\tab\n丙\tac\n丁\tacd\n戊\tace\n己\tb\n庚\tbcdefg\n", &base.trie, FP, null);
    defer blob.deinit(testing.allocator);
    const d = try blob.dict(FP);

    try testing.expectEqual(@as(u32, 5), d.countUnder("a"));
    try testing.expectEqual(@as(u32, 3), d.countUnder("ac"));
    try testing.expectEqual(@as(u32, 1), d.countUnder("acd"));
    try testing.expectEqual(@as(u32, 0), d.countUnder("acf"));
    try testing.expectEqual(@as(u32, 2), d.countUnder("b"));
    try testing.expectEqual(@as(u32, 7), d.countUnder(""));
    try testing.expectEqual(@as(u32, 0), d.countUnder("abcdefg"));

    try testing.expect(d.hasPath("a"));
    try testing.expect(d.hasPath("ac"));
    try testing.expect(d.hasPath("bcdef"));
    try testing.expect(d.hasPath("bcdefg"));
    try testing.expect(!d.hasPath("c"));
    try testing.expect(!d.hasPath("abc"));
    try testing.expect(!d.hasPath("bcdefgh"));

    var rb: [MAX_KEYS_LEN]u8 = undefined;
    const ac = ranksOf("ac", &rb);
    try testing.expectEqual(@as(u32, 1), d.rangeFor(2, ac).len());
    try testing.expectEqual(@as(u32, 2), d.rangeFor(3, ac).len());
    try testing.expectEqual(@as(u32, 0), d.rangeFor(1, ac).len());
    try testing.expectEqual(@as(u32, 0), d.rangeFor(4, ac).len());
}

test "duplicates are dropped: within the text and against the built-in trie" {
    var base = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "nk", .value = "你" },
        .{ .keys = "nk", .value = "拟" },
        .{ .keys = "hz", .value = "好" },
    });
    defer base.deinit(testing.allocator);

    const text =
        "你\tnk\n" ++ // 1: built-in on the same code → dropped
        "泥\tnk\n" ++ // 2: new word on a built-in code → kept
        "你\tnkh\n" ++ // 3: built-in word, different code → kept
        "泥\tnk\n" ++ // 4: exact repeat → dropped
        "# a comment between\n" ++ // 5
        "泥2\tnk\n" ++ // 6
        "泥\tnk\n" ++ // 7: repeat, not adjacent to the first → still dropped
        "好\thz\n"; // 8: built-in → dropped
    var blob = try buildAlloc(testing.allocator, text, &base.trie, FP, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), blob.report.entries);
    try testing.expectEqual(@as(u32, 4), blob.report.dropped);
    // Lines 2 and 6 share nk with each other and with two built-in words;
    // nkh is nobody else's.
    try testing.expectEqual(@as(u32, 2), blob.report.shared);
    try testing.expectEqual(@as(u32, 6), blob.report.notes);

    const d = try blob.dict(FP);
    try testing.expectEqualStrings("泥", valueOf(&d, 0));
    try testing.expectEqualStrings("泥2", valueOf(&d, 1));
    try testing.expectEqualStrings("你", valueOf(&d, 2));

    // Every dropped line gets a note saying what it repeats; the notes come
    // ascending by line, dropped and shared interleaved.
    const want = [_]Note{
        .{ .line = 1, .flags = NoteFlag.repeats_builtin, .other = 0, .builtin = 2, .peers = 0 },
        .{ .line = 2, .flags = NoteFlag.code_in_builtin | NoteFlag.code_in_line, .other = 6, .builtin = 2, .peers = 1 },
        .{ .line = 4, .flags = NoteFlag.repeats_line, .other = 2, .builtin = 2, .peers = 0 },
        .{ .line = 6, .flags = NoteFlag.code_in_builtin | NoteFlag.code_in_line, .other = 2, .builtin = 2, .peers = 1 },
        .{ .line = 7, .flags = NoteFlag.repeats_line, .other = 2, .builtin = 2, .peers = 0 },
        .{ .line = 8, .flags = NoteFlag.repeats_builtin, .other = 0, .builtin = 1, .peers = 0 },
    };
    try testing.expectEqualDeep(@as([]const Note, &want), blob.notes());
}

test "notes name the shared codes of kept phrases" {
    var base = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "nk", .value = "你" },
        .{ .keys = "nk", .value = "拟" },
        .{ .keys = "hz", .value = "好" },
    });
    defer base.deinit(testing.allocator);

    const text =
        "泥\tnk\n" ++ // 1: kept; nk carries two built-in words, and line 3
        "你\tnkh\n" ++ // 2: kept; nkh is nobody else's
        "泥2\tnk\n" ++ // 3: kept; as line 1
        "甲\ta\n" ++ // 4: kept; shares a with line 5 only
        "乙\ta\n" ++ // 5: kept; shares a with line 4 only
        "好\thz\n" ++ // 6: dropped: repeats the built-in 好
        "甲\ta\n"; // 7: dropped: repeats line 4
    var blob = try buildAlloc(testing.allocator, text, &base.trie, FP, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 5), blob.report.entries);
    try testing.expectEqual(@as(u32, 2), blob.report.dropped);
    try testing.expectEqual(@as(u32, 4), blob.report.shared);
    try testing.expectEqual(@as(u32, 6), blob.report.notes);
    try testing.expectEqual(@as(u32, 0), blob.report.notes_offset % 4);
    try testing.expect(blob.report.notes_offset >= blob.len);
    try testing.expect(blob.report.notes_offset + blob.report.notes * @sizeOf(Note) <= blob.buf.len);

    const want = [_]Note{
        .{ .line = 1, .flags = NoteFlag.code_in_builtin | NoteFlag.code_in_line, .other = 3, .builtin = 2, .peers = 1 },
        .{ .line = 3, .flags = NoteFlag.code_in_builtin | NoteFlag.code_in_line, .other = 1, .builtin = 2, .peers = 1 },
        .{ .line = 4, .flags = NoteFlag.code_in_line, .other = 5, .builtin = 0, .peers = 1 },
        .{ .line = 5, .flags = NoteFlag.code_in_line, .other = 4, .builtin = 0, .peers = 1 },
        .{ .line = 6, .flags = NoteFlag.repeats_builtin, .other = 0, .builtin = 1, .peers = 0 },
        .{ .line = 7, .flags = NoteFlag.repeats_line, .other = 4, .builtin = 0, .peers = 0 },
    };
    try testing.expectEqualDeep(@as([]const Note, &want), blob.notes());

    // A phrase alone on a built-in code: one note, no peers, and `other`
    // stays 0.
    var alone = try buildAlloc(testing.allocator, "泥\tnk\n", &base.trie, FP, null);
    defer alone.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), alone.report.shared);
    const alone_want = [_]Note{
        .{ .line = 1, .flags = NoteFlag.code_in_builtin, .other = 0, .builtin = 2, .peers = 0 },
    };
    try testing.expectEqualDeep(@as([]const Note, &alone_want), alone.notes());

    // Three phrases on one free code: everyone names the first, the first
    // names the second.
    var three = try buildAlloc(testing.allocator, "甲\tq\n乙\tq\n\n丙\tq\n", &base.trie, FP, null);
    defer three.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), three.report.shared);
    const three_want = [_]Note{
        .{ .line = 1, .flags = NoteFlag.code_in_line, .other = 2, .builtin = 0, .peers = 2 },
        .{ .line = 2, .flags = NoteFlag.code_in_line, .other = 1, .builtin = 0, .peers = 2 },
        .{ .line = 4, .flags = NoteFlag.code_in_line, .other = 1, .builtin = 0, .peers = 2 },
    };
    try testing.expectEqualDeep(@as([]const Note, &three_want), three.notes());

    // Nothing shared, nothing dropped: no notes at all.
    var clean = try buildAlloc(testing.allocator, "甲\ta\n乙\tb\n", &base.trie, FP, null);
    defer clean.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), clean.report.shared);
    try testing.expectEqual(@as(u32, 0), clean.report.notes);
    try testing.expectEqual(@as(usize, 0), clean.notes().len);
}

test "the source tag round-trips through the header and check reports it" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);
    const text = "甲\ta\n乙\tab\n";
    const buf = try testing.allocator.alignedAlloc(u8, .@"4", blobBound(text));
    defer testing.allocator.free(buf);
    var report: Report = undefined;

    const tag: u64 = 0x0123_4567_89AB_CDEF;
    const len = build(text, buf, &base.trie, FP, tag, &report);
    const d = try UserDict.fromBytes(buf[0..len], FP);
    try testing.expectEqual(tag, d.source_tag);

    var info: Info = undefined;
    try testing.expectEqual(Status.ok, UserDict.check(buf[0..len], FP, &info));
    try testing.expectEqual(tag, info.source_tag);
    try testing.expectEqual(@as(u32, 2), info.entries);
    // Without an info struct, and on failure (info untouched).
    try testing.expectEqual(Status.ok, UserDict.check(buf[0..len], FP, null));
    info.entries = 99;
    try testing.expectEqual(Status.stale, UserDict.check(buf[0..len], FP + 1, &info));
    try testing.expectEqual(@as(u32, 99), info.entries);
}

test "lines that do not parse are skipped and noted" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);
    const cases = [_]struct { text: []const u8, flag: u32, line: u32, entries: u32 }{
        .{ .text = "甲\ta\nno tab here\n", .flag = NoteFlag.malformed, .line = 2, .entries = 1 },
        .{ .text = "甲\ta\n乙\tA\n", .flag = NoteFlag.bad_keys, .line = 2, .entries = 1 },
        .{ .text = "甲\ta\n乙\t\n", .flag = NoteFlag.bad_keys, .line = 2, .entries = 1 },
        .{ .text = "乙\tabcdefg\n", .flag = NoteFlag.bad_keys, .line = 1, .entries = 0 },
        .{ .text = "甲\ta\n\n\n\tb\n", .flag = NoteFlag.bad_value, .line = 4, .entries = 1 },
        .{ .text = "a\tb\tc\n", .flag = NoteFlag.bad_keys, .line = 1, .entries = 0 },
        .{ .text = "甲\ta\n冒号\t;;\n", .flag = NoteFlag.bad_keys, .line = 2, .entries = 1 },
        .{ .text = "分号\ta;\n", .flag = NoteFlag.bad_keys, .line = 1, .entries = 0 },
        .{ .text = "\xff\xfe\ta\n", .flag = NoteFlag.bad_value, .line = 1, .entries = 0 },
        .{ .text = "x\x01y\ta\n", .flag = NoteFlag.bad_value, .line = 1, .entries = 0 },
        .{ .text = "x\x7fy\ta\n", .flag = NoteFlag.bad_value, .line = 1, .entries = 0 },
    };
    for (cases) |c| {
        var blob = try buildAlloc(testing.allocator, c.text, &base.trie, FP, null);
        defer blob.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 0), blob.report.status);
        try testing.expectEqual(c.entries, blob.report.entries);
        try testing.expectEqual(@as(u32, 1), blob.report.invalid);
        try testing.expectEqual(@as(u32, 0), blob.report.dropped);
        const want = [_]Note{.{ .line = c.line, .flags = c.flag, .other = 0, .builtin = 0, .peers = 0 }};
        try testing.expectEqualDeep(@as([]const Note, &want), blob.notes());
        const d = try blob.dict(FP);
        try testing.expectEqual(c.entries, d.count());
    }

    // A value of exactly VALUE_MAX bytes is fine; one more is not.
    var long_ok: [VALUE_MAX + 3]u8 = undefined;
    @memset(long_ok[0..VALUE_MAX], 'x');
    long_ok[VALUE_MAX..][0..3].* = "\ta\n".*;
    var ok = try buildAlloc(testing.allocator, &long_ok, &base.trie, FP, null);
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), ok.report.entries);
    try testing.expectEqual(@as(u32, 0), ok.report.invalid);

    var long_bad: [VALUE_MAX + 4]u8 = undefined;
    @memset(long_bad[0 .. VALUE_MAX + 1], 'x');
    long_bad[VALUE_MAX + 1 ..][0..3].* = "\ta\n".*;
    var bad = try buildAlloc(testing.allocator, &long_bad, &base.trie, FP, null);
    defer bad.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), bad.report.entries);
    try testing.expectEqual(@as(u32, 1), bad.report.invalid);
    try testing.expectEqual(NoteFlag.bad_value, bad.notes()[0].flags);
}

test "skipped lines are noted alongside dropped and shared ones" {
    var base = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "nk", .value = "你" },
        .{ .keys = "nk", .value = "拟" },
    });
    defer base.deinit(testing.allocator);

    const text =
        "泥\tnk\n" ++ // 1: kept; nk carries two built-in words
        "oops\n" ++ // 2: skipped: no TAB
        "你\tnk\n" ++ // 3: dropped: repeats a built-in word
        "乙\tA\n" ++ // 4: skipped: bad keys
        "泥\tnk\n" ++ // 5: dropped: repeats line 1
        "\tq\n" ++ // 6: skipped: empty value
        "甲\tq\n"; // 7: kept; alone on q
    var blob = try buildAlloc(testing.allocator, text, &base.trie, FP, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), blob.report.entries);
    try testing.expectEqual(@as(u32, 2), blob.report.dropped);
    try testing.expectEqual(@as(u32, 1), blob.report.shared);
    try testing.expectEqual(@as(u32, 3), blob.report.invalid);
    try testing.expectEqual(@as(u32, 6), blob.report.notes);

    // A skipped line is nobody's peer or repeat, and the notes still come
    // ascending by line.
    const want = [_]Note{
        .{ .line = 1, .flags = NoteFlag.code_in_builtin, .other = 0, .builtin = 2, .peers = 0 },
        .{ .line = 2, .flags = NoteFlag.malformed, .other = 0, .builtin = 0, .peers = 0 },
        .{ .line = 3, .flags = NoteFlag.repeats_builtin, .other = 0, .builtin = 2, .peers = 0 },
        .{ .line = 4, .flags = NoteFlag.bad_keys, .other = 0, .builtin = 0, .peers = 0 },
        .{ .line = 5, .flags = NoteFlag.repeats_line, .other = 1, .builtin = 2, .peers = 0 },
        .{ .line = 6, .flags = NoteFlag.bad_value, .other = 0, .builtin = 0, .peers = 0 },
    };
    try testing.expectEqualDeep(@as([]const Note, &want), blob.notes());

    const d = try blob.dict(FP);
    try testing.expectEqualStrings("甲", valueOf(&d, 0));
    try testing.expectEqualStrings("泥", valueOf(&d, 1));
}

test "isCleanValue agrees with std's UTF-8 validation plus the control-byte rule" {
    // Fixed edge cases: overlong forms, surrogates, the U+10FFFF ceiling,
    // truncated sequences, stray continuation bytes.
    const good = [_][]const u8{ "", "a", "你好", "\u{7F}"[0..0], "\xC2\x80", "\xDF\xBF", "\xE0\xA0\x80", "\xED\x9F\xBF", "\xEE\x80\x80", "\xEF\xBF\xBF", "\xF0\x90\x80\x80", "\xF3\xBF\xBF\xBF", "\xF4\x8F\xBF\xBF", "mixed 混合 \xF0\x9F\x98\x80 ok" };
    for (good) |g| try testing.expect(isCleanValue(g));
    const bad = [_][]const u8{ "\x00", "\x1f", "\x7f", "a\nb", "\t", "\xC0\x80", "\xC1\xBF", "\xE0\x9F\xBF", "\xED\xA0\x80", "\xF0\x8F\xBF\xBF", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80", "\x80", "\xBF", "\xC2", "\xE4\xBD", "\xF0\x90\x80", "\xE4\x41\xA0", "\xFF" };
    for (bad) |b| try testing.expect(!isCleanValue(b));

    // Random byte strings, biased toward the interesting ranges, against
    // the reference: std's validator plus a separate control-byte scan.
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const r = prng.random();
    var buf: [12]u8 = undefined;
    for (0..20_000) |_| {
        const len = r.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| {
            b.* = switch (r.uintLessThan(u8, 6)) {
                0 => r.int(u8),
                1 => r.uintLessThan(u8, 0x20),
                2 => 0x20 + r.uintLessThan(u8, 0x60),
                3 => 0x80 + r.uintLessThan(u8, 0x40),
                4 => 0xC0 + r.uintLessThan(u8, 0x20),
                else => 0xE0 + r.uintLessThan(u8, 0x20),
            };
        }
        const s = buf[0..len];
        var no_control = true;
        for (s) |b| if (b < 0x20 or b == 0x7f) {
            no_control = false;
        };
        const want = no_control and std.unicode.utf8ValidateSlice(s);
        try testing.expectEqual(want, isCleanValue(s));
    }
}

test "build enforces the entry cap and the buffer size" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);

    // MAX_ENTRIES + 1 distinct lines; the cap is reported on the first
    // line past it.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..MAX_ENTRIES + 1) |i| {
        try text.print(testing.allocator, "w{d}\t{c}{c}{c}{c}\n", .{
            i,
            'a' + @as(u8, @intCast(i % 26)),
            'a' + @as(u8, @intCast((i / 26) % 26)),
            'a' + @as(u8, @intCast((i / 676) % 26)),
            'a' + @as(u8, @intCast((i / 17576) % 26)),
        });
    }
    var report: Report = undefined;
    try testing.expectError(error.BuildFailed, buildAlloc(testing.allocator, text.items, &base.trie, FP, &report));
    try testing.expectEqual(@backingInt(Status.too_many_entries), report.status);
    try testing.expectEqual(MAX_ENTRIES + 1, report.line);

    // Exactly MAX_ENTRIES builds.
    const last_nl = std.mem.findScalarLast(u8, text.items[0 .. text.items.len - 1], '\n').?;
    var blob = try buildAlloc(testing.allocator, text.items[0 .. last_nl + 1], &base.trie, FP, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(MAX_ENTRIES, blob.report.entries);
    const d = try blob.dict(FP);
    try testing.expectEqual(MAX_ENTRIES, d.count());

    // A buffer below the bound is refused up front.
    var small: [@sizeOf(Header) + 4]u8 align(4) = undefined;
    try testing.expectEqual(@as(usize, 0), build("甲\ta\n", &small, &base.trie, FP, 0, &report));
    try testing.expectEqual(@backingInt(Status.buffer_too_small), report.status);
}

test "an empty text builds an empty, valid dictionary" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);
    var blob = try buildAlloc(testing.allocator, "", &base.trie, FP, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@sizeOf(Header), blob.len);
    const d = try blob.dict(FP);
    try testing.expectEqual(@as(u32, 0), d.count());
    try testing.expect(!d.hasPath("a"));
    try testing.expectEqual(@as(u32, 0), d.countUnder("a"));
}

test "fromBytes rejects stale, misaligned and corrupt blobs" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);
    var blob = try buildAlloc(testing.allocator, "甲\ta\n乙\tab\n丙\tb\n", &base.trie, FP, null);
    defer blob.deinit(testing.allocator);
    const good = blob.bytes();

    try testing.expectEqual(Status.ok, UserDict.check(good, FP, null));
    // Wrong built-in dictionary.
    try testing.expectEqual(Status.stale, UserDict.check(good, FP + 1, null));
    // Not 4-aligned.
    try testing.expectEqual(Status.misaligned, UserDict.check(@as([]const u8, good)[1..], FP, null));
    // Truncated.
    try testing.expectEqual(Status.corrupt, UserDict.check(good[0 .. good.len - 1], FP, null));
    try testing.expectEqual(Status.corrupt, UserDict.check(good[0..8], FP, null));
    // Trailing bytes beyond total_len are tolerated (a host may pass its
    // whole buffer).
    try testing.expectEqual(Status.ok, UserDict.check(blob.buf, FP, null));

    const mutate = struct {
        fn run(src: []align(4) const u8, offset: usize, byte: u8, fp: u32) !Status {
            const copy = try testing.allocator.alignedAlloc(u8, .@"4", src.len);
            defer testing.allocator.free(copy);
            @memcpy(copy, src);
            copy[offset] = byte;
            return UserDict.check(copy, fp, null);
        }
    }.run;

    // Magic, version, endianness.
    try testing.expectEqual(Status.corrupt, try mutate(good, 0, 'X', FP));
    try testing.expectEqual(Status.stale, try mutate(good, 4, 0xFF, FP));
    try testing.expectEqual(Status.stale, try mutate(good, 8, 0xFF, FP));

    const entries_off = @sizeOf(Header);
    // keys_len that disagrees with its length bucket.
    try testing.expectEqual(Status.corrupt, try mutate(good, entries_off + 6, 2, FP));
    // A rank outside the alphabet.
    try testing.expectEqual(Status.corrupt, try mutate(good, entries_off + 0, 27, FP));
    // ';' (rank 26), which no user key holds. Entry 1 ("b") is the last
    // of its length, so it stays sorted and only the alphabet check fails.
    try testing.expectEqual(Status.corrupt, try mutate(good, entries_off + @sizeOf(Entry), 26, FP));
    // Non-zero key padding.
    try testing.expectEqual(Status.corrupt, try mutate(good, entries_off + 1, 1, FP));
    // Unsorted: entries 0 and 1 are "a" and "b" (both length 1); turn
    // entry 0 into "c" so it no longer precedes entry 1.
    try testing.expectEqual(Status.corrupt, try mutate(good, entries_off + 0, 2, FP));
    // A value offset past the pool.
    try testing.expectEqual(Status.corrupt, try mutate(good, entries_off + 8, 0xFF, FP));
    // A NUL terminator overwritten.
    const pool_start = @sizeOf(Header) + 3 * @sizeOf(Entry);
    try testing.expectEqual(Status.corrupt, try mutate(good, pool_start + "甲".len, 'x', FP));
    // Invalid UTF-8 inside a value.
    try testing.expectEqual(Status.corrupt, try mutate(good, pool_start, 0xFF, FP));
}

test "blobBound covers the worst case" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);
    // Every line is a minimal entry: the bound's per-line cost is exact.
    const text = "x\ta\ny\tb\nz\tc\n";
    var report: Report = undefined;
    const buf = try testing.allocator.alignedAlloc(u8, .@"4", blobBound(text));
    defer testing.allocator.free(buf);
    const len = build(text, buf, &base.trie, FP, 0, &report);
    try testing.expect(len > 0);
    try testing.expect(len <= buf.len);
    try testing.expectEqual(@as(u32, 3), report.entries);
    // The notes region starts past any blob the text can produce and ends
    // within the bound even when every line gets a note.
    try testing.expect(report.notes_offset >= len);
    try testing.expectEqual(@as(u32, 0), report.notes_offset % 4);
    try testing.expectEqual(buf.len, report.notes_offset + 4 * @sizeOf(Note));
}
