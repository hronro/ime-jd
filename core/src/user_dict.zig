//! Runtime-built user dictionary: blob format, builder, validator, lookups.
//!
//! A dictionary (`dict.zig`) — the embedded one, or one a host built — is a
//! trie. A user dictionary sits on top of one: the host builds a *blob*
//! with `build` from `value<TAB>keys` lines (the same line rules as every
//! dictionary, `dict.parseLine`), caches
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
//! `trie.keyRank` order (keys are stored as rank bytes 0..26, so a plain
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
//! The header also records which dictionary the blob was built against:
//! `build` drops phrases that duplicate a word of that dictionary, so a
//! blob is only valid on top of it, and a fingerprint mismatch is reported
//! as `stale` (rebuild from the phrases).
//! A host-defined 64-bit `source_tag` travels in the header too, so a host
//! can tell whether a cached blob still matches the phrases it has — a
//! file's modification time, a content hash, a database revision — without
//! a sidecar file. The engine never interprets it.

const std = @import("std");
const testing = std.testing;
const trie_mod = @import("trie");
const Trie = trie_mod.Trie;
const dict = trie_mod.dict;

/// Longest key sequence, shared with the trie (`Context.pressed_keys` is
/// sized to it).
pub const MAX_KEYS_LEN: usize = trie_mod.MAX_KEYS_LEN;

/// Hard cap on phrases per dictionary. Mirrors `JD_USER_DICT_MAX_ENTRIES`
/// in `include/jd.h`; reported through `jd_abi_layout`. Sized for the
/// tightest host, an iOS keyboard extension: at the cap a blob is about
/// 12 MB and a build's buffer about 26 MB.
pub const MAX_ENTRIES: u32 = 500_000;

/// Longest phrase value in bytes, excluding the NUL: the same as any
/// dictionary's. Mirrors `JD_USER_DICT_VALUE_MAX`.
pub const VALUE_MAX: u32 = dict.VALUE_MAX;

/// Hard cap on the input text handed to `build`. Mirrors
/// `JD_USER_DICT_TEXT_MAX`. Room for `MAX_ENTRIES` phrases at over 30
/// bytes a line. Source offsets and line numbers are tracked in 32-bit
/// fields during the build (see `Entry`).
pub const TEXT_MAX: usize = 16 * 1024 * 1024;

/// Bumped whenever the blob layout changes; an older blob then validates
/// as `stale` and the host rebuilds it from the phrases it persisted.
pub const FORMAT_VERSION: u32 = 2;

const MAGIC: [4]u8 = "JDUD".*;
/// Written natively; reads back wrong on a blob from the other endianness.
const ENDIAN_TAG: u32 = 0x0102_0304;

/// `Entry.code`'s packing: a code's length, then 5 bits per key.
const RANK_BITS = 5;
const LEN_BITS = 3;
const CODE_BITS = LEN_BITS + RANK_BITS * MAX_KEYS_LEN;

// What a build reports — shared with dictionaries (see `dict.zig`).
pub const Status = dict.Status;
pub const Report = dict.Report;
pub const Note = dict.Note;
pub const NoteFlag = dict.NoteFlag;
pub const Info = dict.Info;

/// Fixed header at offset 0 of the blob. Every multi-byte field is in the
/// building machine's native byte order; `endian_tag` catches a blob that
/// crossed over from the other endianness.
pub const Header = extern struct {
    magic: [4]u8,
    format_version: u32,
    endian_tag: u32,
    /// The fingerprint of the dictionary this blob was deduplicated
    /// against, split so the header stays 4-byte aligned.
    base_fingerprint_lo: u32,
    base_fingerprint_hi: u32,
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
/// While `build` runs — between its first pass and its last — the value
/// fields describe the *source text* instead: `value_off` is the value's
/// offset in the input, and the 1-based line number rides above the byte
/// length — its low 22 bits in `value_len` (`line << 10 | len`), its high
/// 8 in `_pad` — which is what lets dropped phrases be reported by line
/// without a second scan of the text. `VALUE_MAX` fits in 10 bits and the
/// line in 30, so the packing is lossless; the last pass writes the final
/// fields and zeroes `_pad`.
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
        return self.value_len & LEN_MASK;
    }

    inline fn srcLine(self: Entry) u32 {
        return (self.value_len >> LEN_BITS_PACKED) | (@as(u32, self._pad) << (32 - LEN_BITS_PACKED));
    }

    /// The value's bytes in the source text (build time only).
    inline fn srcValue(self: Entry, phrases: []const u8) []const u8 {
        return phrases[self.value_off..][0..self.srcLen()];
    }

    /// Key length, then the keys in rank order, packed `CODE_BITS` wide:
    /// the order candidates enumerate codes in, as an integer.
    inline fn code(self: Entry) u64 {
        var c: u64 = self.keys_len;
        inline for (self.keys) |r| c = (c << RANK_BITS) | r;
        return c;
    }
};

/// The build-time packing of a value's byte length below its line number.
const LEN_BITS_PACKED = 10;
const LEN_MASK: u32 = (1 << LEN_BITS_PACKED) - 1;

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
    // The build-time packing in `Entry.value_len` and `_pad`: a line
    // number has 30 bits, and the text has fewer lines than bytes.
    std.debug.assert(VALUE_MAX <= LEN_MASK);
    std.debug.assert(TEXT_MAX + 1 <= 1 << (32 - LEN_BITS_PACKED + 8));
    // `Entry.code` packs the keys and their length into a u64.
    std.debug.assert(dict.KEY_RANKS <= 1 << RANK_BITS);
    std.debug.assert(MAX_KEYS_LEN < 1 << LEN_BITS);
    std.debug.assert(CODE_BITS <= 64);
}

/// A half-open range of entry indices.
pub const Range = struct {
    start: u32,
    end: u32,

    pub inline fn len(self: Range) u32 {
        return self.end - self.start;
    }
};

pub const Error = dict.Error;
const statusOf = dict.statusOf;

/// Runtime view over a validated blob. Plain slices into the host's
/// bytes — copy it freely, it owns nothing.
pub const UserDict = struct {
    entries: []const Entry,
    strings: []const u8,
    length_starts: [MAX_KEYS_LEN + 1]u32,
    max_value_len: u32,
    source_tag: u64,

    /// Validate `bytes` as a blob built against the dictionary whose
    /// fingerprint is `expected_fingerprint`, and view it. One linear pass;
    /// allocates nothing. The returned view points into `bytes`.
    pub fn fromBytes(bytes: []const u8, expected_fingerprint: u64) Error!UserDict {
        if (!std.mem.isAligned(@intFromPtr(bytes.ptr), 4)) return error.Misaligned;
        if (bytes.len < @sizeOf(Header)) return error.Corrupt;
        const aligned: []align(4) const u8 = @alignCast(bytes);
        const h: *const Header = @ptrCast(aligned.ptr);

        if (!std.mem.eql(u8, &h.magic, &MAGIC)) return error.Corrupt;
        if (h.format_version != FORMAT_VERSION or h.endian_tag != ENDIAN_TAG) return error.Stale;
        const base: u64 = (@as(u64, h.base_fingerprint_hi) << 32) | h.base_fingerprint_lo;
        if (base != expected_fingerprint) return error.Stale;
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
        // Every entry sits in its length's bucket, holds a code by the code
        // rules with zero padding, comes no earlier than the one before it in code
        // order — which, the length leading, orders the buckets too — and
        // owns the next value in the pool, NUL-terminated.
        var max_value_len: u32 = 0;
        var prev_code: u64 = 0;
        var pos: usize = 0;
        for (1..MAX_KEYS_LEN + 1) |len| {
            const lo = starts[len - 1];
            const hi = starts[len];
            if (hi < lo) return error.Corrupt;
            for (entries[lo..hi]) |*e| {
                if (e.keys_len != len or e._pad != 0 or !validRanks(e.keys, len)) return error.Corrupt;
                const c = e.code();
                if (c < prev_code) return error.Corrupt;
                prev_code = c;
                if (e.value_len == 0 or e.value_len > VALUE_MAX or e.value_off != pos) return error.Corrupt;
                pos += e.value_len;
                if (pos >= strings.len or strings[pos] != 0) return error.Corrupt;
                pos += 1;
                max_value_len = @max(max_value_len, e.value_len);
            }
        }
        if (pos != strings.len or h.max_value_len != max_value_len) return error.Corrupt;
        // The values tile the pool, so the pool is checked whole: its only
        // NULs are the terminators just seen, and around them it is clean
        // UTF-8 — a NUL is ASCII, so no sequence runs across one into the
        // next value.
        if (!dict.isCleanPool(strings, n)) return error.Corrupt;

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
    pub fn check(bytes: []const u8, expected_fingerprint: u64, info: ?*Info) Status {
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

    /// How many entries sit on exactly `keys` (key bytes) — the phrases a
    /// built-in word on that code is listed after.
    pub fn countOn(self: *const UserDict, keys: []const u8) u32 {
        if (keys.len == 0 or keys.len > MAX_KEYS_LEN) return 0;
        var buf: [MAX_KEYS_LEN]u8 = undefined;
        return self.rangeFor(keys.len, ranksOf(keys, &buf)).len();
    }

    /// The first entry at or after `from` whose value is exactly `value`,
    /// in blob order — key length, then key rank, then source order. A
    /// linear scan: the dictionary is capped at `MAX_ENTRIES`.
    pub fn findValue(self: *const UserDict, value: []const u8, from: u32) ?u32 {
        var i = from;
        while (i < self.entries.len) : (i += 1) {
            const e = &self.entries[i];
            if (e.value_len == value.len and
                std.mem.eql(u8, self.strings[e.value_off..][0..e.value_len], value)) return i;
        }
        return null;
    }

    /// Entry `i`'s keys as key bytes, written into `buf`.
    pub fn keysOf(self: *const UserDict, i: u32, buf: *[MAX_KEYS_LEN]u8) []const u8 {
        const ranks = self.entries[i].ranks();
        for (ranks, 0..) |r, j| buf[j] = trie_mod.keyOfRank(r);
        return buf[0..ranks.len];
    }

    /// Entry `i`'s position among the entries on its own code — its
    /// candidate index there, since a user phrase leads the built-in words.
    pub fn indexOnCode(self: *const UserDict, i: u32) u32 {
        const e = &self.entries[i];
        return i - self.rangeFor(e.keys_len, e.ranks()).start;
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
/// guarantees the bytes are in the alphabet and fit.
pub fn ranksOf(keys: []const u8, buf: *[MAX_KEYS_LEN]u8) []const u8 {
    for (keys, 0..) |k, i| buf[i] = trie_mod.keyRank(k);
    return buf[0..keys.len];
}

/// Is a code's `len` key ranks a code by the rules (`dict.isValidRanks`),
/// with zero padding past them? All six bytes at once for the common case
/// — letters only — and the ';' rule only for a code that holds one.
fn validRanks(keys: [MAX_KEYS_LEN]u8, len: usize) bool {
    const Word = @Int(.unsigned, 8 * MAX_KEYS_LEN);
    const ones: Word = std.math.maxInt(Word) / 0xFF; // 0x01 in every byte
    const w = std.mem.readInt(Word, &keys, .little);
    const used: Word = @truncate((@as(u64, 1) << @intCast(8 * len)) - 1);
    // A byte at or above SEMICOLON_RANK sets its high bit once (127 -
    // (SEMICOLON_RANK - 1)) is added to it, or already has it set; no
    // carry can clear one.
    const high = ((w +% ones * (127 - (dict.SEMICOLON_RANK - 1))) | w) & (ones * 0x80);
    if (w & ~used != 0) return false;
    if (high & used == 0) return true;
    return dict.isValidRanks(keys[0..len]);
}

/// The content hash every host uses for a `source_tag` (`dict.hash`).
pub const hash = dict.hash;

// =========================================================================
// Builder
// =========================================================================

/// How `build` lays out the host's buffer for a text, from one count over
/// it: the lines with at least one byte, the only ones that can hold a
/// phrase or earn a note.
const Layout = struct {
    /// Lines with at least one byte: at most one note each.
    filled: usize,
    /// Entry slots: one per filled line, up to `MAX_ENTRIES`.
    slots: usize,
    /// Just past the largest blob the text can produce — one entry and one
    /// NUL per slot, plus the text itself for the values — rounded up to 4.
    notes_offset: usize,
    /// The notes' end: what the host's buffer must hold.
    bound: usize,

    fn of(phrases: []const u8) Layout {
        // A filled line starts at a byte that is not LF and follows LF or
        // the start of the text.
        var filled: usize = @intFromBool(phrases.len != 0 and phrases[0] != '\n');
        if (phrases.len > 1) {
            for (phrases[0 .. phrases.len - 1], phrases[1..]) |prev, b| {
                filled += @intFromBool(prev == '\n' and b != '\n');
            }
        }
        const slots: usize = @min(filled, MAX_ENTRIES);
        const notes_offset = std.mem.alignForward(usize, @sizeOf(Header) + slots * @sizeOf(Entry) + phrases.len + slots, 4);
        return .{
            .filled = filled,
            .slots = slots,
            .notes_offset = notes_offset,
            .bound = notes_offset + filled * @sizeOf(Note),
        };
    }
};

/// Upper bound on what `build` writes into the host's buffer from
/// `phrases`: the blob, and past it one `Note` per line that is not empty.
/// One pass over the text, no parsing — size the output buffer with it.
pub fn blobBound(phrases: []const u8) usize {
    return Layout.of(phrases).bound;
}

fn codeKey(e: Entry) u64 {
    return e.code();
}

/// Sort `entries` by `Entry.code`, stably — entries on one code keep the
/// order they came in — with `scratch` (as long as `entries`) as the other
/// half of each pass.
fn sortByCode(entries: []Entry, scratch: []Entry) void {
    dict.radixSort(Entry, entries, scratch, CODE_BITS, codeKey);
}

/// Value bytes, then source order (`value_off` is the source offset during
/// the build, so it is monotonic in line order), for the entries on one
/// code: every copy of a phrase sits right after its first one.
fn valueOrder(phrases: []const u8, a: Entry, b: Entry) bool {
    return switch (std.mem.order(u8, a.srcValue(phrases), b.srcValue(phrases))) {
        .lt => true,
        .gt => false,
        .eq => a.value_off < b.value_off,
    };
}

/// Source order, for the kept phrases on one code.
fn sourceOrder(_: void, a: Entry, b: Entry) bool {
    return a.value_off < b.value_off;
}

/// The base dictionary's nodes along the last code looked up, so the next
/// code — sorted, it usually shares a prefix with this one — walks only
/// from where the two part.
const BasePath = struct {
    base: *const Trie,
    /// `nodes[i]` is the node for the first `i` keys of `keys`, for every
    /// `i <= depth`.
    nodes: [MAX_KEYS_LEN + 1]*const Trie.Node,
    keys: [MAX_KEYS_LEN]u8 = @splat(0),
    depth: usize = 0,

    fn init(base: *const Trie) BasePath {
        var self: BasePath = .{ .base = base, .nodes = undefined };
        self.nodes[0] = base.root();
        return self;
    }

    /// The node for exactly `ranks`, if the trie has the path.
    fn node(self: *BasePath, ranks: []const u8) ?*const Trie.Node {
        var depth: usize = 0;
        while (depth < self.depth and depth < ranks.len and self.keys[depth] == ranks[depth]) depth += 1;
        while (depth < ranks.len) : (depth += 1) {
            self.keys[depth] = ranks[depth];
            self.nodes[depth + 1] = self.nodes[depth].getChild(self.base, trie_mod.keyOfRank(ranks[depth])) orelse break;
        }
        self.depth = depth;
        return if (depth == ranks.len) self.nodes[depth] else null;
    }
};

/// Does the base dictionary's node carry `value`?
fn nodeHas(values: Trie.Values, value: []const u8) bool {
    for (0..values.len()) |i| {
        if (std.mem.eql(u8, values.at(i), value)) return true;
    }
    return false;
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
    fingerprint: u64,
    source_tag: u64,
    report: *Report,
) usize {
    report.* = Report.empty;
    if (phrases.len > TEXT_MAX) return fail(report, .text_too_long, 0);
    // The bound is the contract: room for every entry, the whole text as
    // values, and one note per non-empty line past the largest possible
    // blob.
    const layout = Layout.of(phrases);
    if (out.len < layout.bound) return fail(report, .buffer_too_small, 0);
    const notes_off = layout.notes_offset;
    const notes: []Note = std.mem.bytesAsSlice(
        Note,
        @as([]align(4) u8, @alignCast(out[notes_off..][0 .. layout.filled * @sizeOf(Note)])),
    );
    var note_count: u32 = 0;

    // ---- Pass 1: one entry per line that parses, values still referenced
    // by their offset in the source text and their line number (see
    // `Entry`). A line that does not parse is skipped with a note saying
    // why. The entry region has a slot for every line that is not empty,
    // up to the cap; the bound covers it. ----
    const slots: []Entry = std.mem.bytesAsSlice(
        Entry,
        @as([]align(4) u8, @alignCast(out[@sizeOf(Header)..][0 .. layout.slots * @sizeOf(Entry)])),
    );
    var n: u32 = 0;
    var invalid: u32 = 0;
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, phrases, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = (dict.parseLine(raw) catch |err| {
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
            ._pad = @truncate(line_no >> (32 - LEN_BITS_PACKED)),
            .value_off = @intCast(@intFromPtr(line.value.ptr) - @intFromPtr(phrases.ptr)),
            .value_len = (line_no << LEN_BITS_PACKED) | @as(u32, @intCast(line.value.len)),
        };
        for (line.keys, 0..) |k, j| e.keys[j] = trie_mod.keyRank(k);
        slots[n] = e;
        n += 1;
    }
    const entries = slots[0..n];

    // ---- Drop duplicates and note shared codes, a code at a time. Sorted
    // by code, stably, the phrases on a code stay in source order; a code
    // with more than one is sorted by value for a moment, so the copies of
    // a phrase follow its first one and a repeat is found without scanning
    // the code's other phrases. One trie walk per code — from where it
    // parts from the code before — answers both "is this a built-in word?"
    // and "how many built-in words share this code?". The radix sort's
    // scratch is the notes region past the notes written so far: every
    // entry and every note so far has a non-empty line of its own, and the
    // region holds a note for each. ----
    {
        const scratch_off = notes_off + note_count * @sizeOf(Note);
        std.debug.assert(scratch_off + entries.len * @sizeOf(Entry) <= layout.bound);
        const scratch: []Entry = std.mem.bytesAsSlice(
            Entry,
            @as([]align(4) u8, @alignCast(out[scratch_off..][0 .. entries.len * @sizeOf(Entry)])),
        );
        sortByCode(entries, scratch);
    }
    var path = BasePath.init(base);
    var kept: u32 = 0;
    var dropped: u32 = 0;
    var shared: u32 = 0;
    var g: usize = 0;
    while (g < n) {
        const group_code = entries[g].code();
        var end = g + 1;
        while (end < n and entries[end].code() == group_code) end += 1;
        const node = path.node(entries[g].ranks());
        const base_values: Trie.Values = if (node) |nd| nd.values(base) else .{ .slice = &.{}, .strings = &.{} };
        const builtin: u32 = @intCast(base_values.len());
        if (end - g > 1) std.sort.pdq(Entry, entries[g..end], phrases, valueOrder);

        // Runs of one value: the first copy is kept unless a built-in word
        // repeats it; every later copy repeats the first.
        const group_start = kept;
        var i = g;
        while (i < end) {
            const first = entries[i];
            const value = first.srcValue(phrases);
            var run_end = i + 1;
            while (run_end < end and std.mem.eql(u8, entries[run_end].srcValue(phrases), value)) run_end += 1;
            const in_base = nodeHas(base_values, value);
            if (!in_base) {
                // `kept <= i`: this never overwrites an entry still to come.
                entries[kept] = first;
                kept += 1;
            }
            for (entries[if (in_base) i else i + 1..run_end]) |e| {
                notes[note_count] = .{
                    .line = e.srcLine(),
                    .flags = if (in_base) NoteFlag.repeats_builtin else NoteFlag.repeats_line,
                    .other = if (in_base) 0 else first.srcLine(),
                    .builtin = builtin,
                    .peers = 0,
                };
                note_count += 1;
                dropped += 1;
            }
            i = run_end;
        }

        // The kept phrases on this code, back in source order, each noted
        // when the code is shared — with a built-in word, another kept
        // phrase, or both.
        const group = entries[group_start..kept];
        if (group.len > 1) std.sort.pdq(Entry, group, {}, sourceOrder);
        const peers: u32 = @intCast(group.len -| 1);
        if (group.len > 0 and (builtin != 0 or peers != 0)) {
            var flags: u32 = 0;
            if (builtin != 0) flags |= NoteFlag.code_in_builtin;
            if (peers != 0) flags |= NoteFlag.code_in_line;
            for (group, 0..) |e, m| {
                const other: u32 = if (peers == 0)
                    0
                else if (m == 0)
                    group[1].srcLine()
                else
                    group[0].srcLine();
                notes[note_count] = .{
                    .line = e.srcLine(),
                    .flags = flags,
                    .other = other,
                    .builtin = builtin,
                    .peers = peers,
                };
                note_count += 1;
            }
            shared += @intCast(group.len);
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
        e._pad = 0;
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
        .base_fingerprint_lo = @truncate(fingerprint),
        .base_fingerprint_hi = @truncate(fingerprint >> 32),
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

    pub fn dict(self: *const Blob, fingerprint: u64) Error!UserDict {
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
    fingerprint: u64,
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
        .{ .text = "甲\ta\n冒号\tb;\n", .flag = NoteFlag.bad_keys, .line = 2, .entries = 1 },
        .{ .text = "：\t;;\n分号\t;a;\n", .flag = NoteFlag.bad_keys, .line = 2, .entries = 1 },
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
    // Entries: "a", "b", "ab".

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
        fn run(src: []align(4) const u8, offset: usize, byte: u8, fp: u64) !Status {
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
    // ';' (rank 26) after a letter: entry 2 ("ab") becomes "a;", still
    // the last of its length, so only the code rule fails.
    try testing.expectEqual(Status.corrupt, try mutate(good, entries_off + 2 * @sizeOf(Entry) + 1, 26, FP));
    // ';' before any letter is a code like any other: entry 1 ("b") as ";".
    try testing.expectEqual(Status.ok, try mutate(good, entries_off + @sizeOf(Entry), 26, FP));
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
    try testing.expectEqual(buf.len, report.notes_offset + 3 * @sizeOf(Note));

    // Empty lines cost nothing; any other line costs an entry slot, its NUL
    // and a note, whether or not it holds a phrase.
    const expected = struct {
        fn bound(t: []const u8, filled: usize) usize {
            return std.mem.alignForward(usize, @sizeOf(Header) + filled * (@sizeOf(Entry) + 1) + t.len, 4) +
                filled * @sizeOf(Note);
        }
    }.bound;
    for ([_]struct { []const u8, usize }{
        .{ "", 0 },
        .{ "\n\n\n\n\n\n\n\n", 0 },
        .{ "x\ta", 1 },
        .{ "\n\nx\ta\n\n\n", 1 },
        .{ " \n#\n\r", 3 },
    }) |c| try testing.expectEqual(expected(c[0], c[1]), blobBound(c[0]));
}

test "every kind of line fits the bound exactly when each one earns a note" {
    // Every line skipped or dropped: the notes region is filled to its end.
    var base = try trie_mod.buildTrie(testing.allocator, &.{.{ .keys = "a", .value = "甲" }});
    defer base.deinit(testing.allocator);
    const text = "\n\n甲\ta\nno tab\n\n乙\tA\n\t\n甲\ta";
    const bound = blobBound(text);
    const buf = try testing.allocator.alignedAlloc(u8, .@"4", bound);
    defer testing.allocator.free(buf);
    var report: Report = undefined;
    _ = build(text, buf, &base.trie, FP, 0, &report);
    try testing.expectEqual(@as(u32, 0), report.status);
    try testing.expectEqual(@as(u32, 5), report.notes);
    try testing.expectEqual(bound, report.notes_offset + 5 * @sizeOf(Note));
    // One byte short is refused.
    _ = build(text, buf[0 .. bound - 1], &base.trie, FP, 0, &report);
    try testing.expectEqual(@backingInt(Status.buffer_too_small), report.status);
}

/// The build's rules, spelled out the slow way — every repeat found by
/// scanning the phrases already kept on its code — for `build` to be
/// checked against.
const Reference = struct {
    const Kept = struct { keys: []const u8, value: []const u8, line: u32 };

    report: Report,
    notes: std.ArrayList(Note),
    /// The blob's order: code (length, then key rank), then source order.
    kept: std.ArrayList(Kept),

    fn wordsOn(base: *const Trie, keys: []const u8) ?Trie.Values {
        var node = base.root();
        for (keys) |k| node = node.getChild(base, k) orelse return null;
        return node.values(base);
    }

    fn codeLess(_: void, a: Kept, b: Kept) bool {
        if (a.keys.len != b.keys.len) return a.keys.len < b.keys.len;
        return switch (std.mem.order(u8, a.keys, b.keys)) {
            .lt => true,
            .gt => false,
            .eq => a.line < b.line,
        };
    }

    fn noteLess(_: void, a: Note, b: Note) bool {
        return a.line < b.line;
    }

    fn init(allocator: std.mem.Allocator, text: []const u8, base: *const Trie) !Reference {
        var self: Reference = .{ .report = Report.empty, .notes = .empty, .kept = .empty };
        var parsed: std.ArrayList(Kept) = .empty;
        defer parsed.deinit(allocator);
        var it = std.mem.splitScalar(u8, text, '\n');
        var line: u32 = 0;
        while (it.next()) |raw| {
            line += 1;
            const l = (dict.parseLine(raw) catch |err| {
                try self.notes.append(allocator, .{
                    .line = line,
                    .flags = switch (err) {
                        error.MalformedLine => NoteFlag.malformed,
                        error.BadKeys => NoteFlag.bad_keys,
                        error.BadValue => NoteFlag.bad_value,
                    },
                    .other = 0,
                    .builtin = 0,
                    .peers = 0,
                });
                self.report.invalid += 1;
                continue;
            }) orelse continue;
            try parsed.append(allocator, .{ .keys = l.keys, .value = l.value, .line = line });
        }
        // a-z sort the same as their ranks, so plain bytes give code order.
        std.sort.pdq(Kept, parsed.items, {}, codeLess);
        for (parsed.items) |p| {
            const words = wordsOn(base, p.keys);
            const builtin: u32 = if (words) |w| @intCast(w.len()) else 0;
            var repeats: u32 = 0;
            for (self.kept.items) |k| {
                if (std.mem.eql(u8, k.keys, p.keys) and std.mem.eql(u8, k.value, p.value)) {
                    repeats = k.line;
                    break;
                }
            }
            const in_base = words != null and nodeHas(words.?, p.value);
            if (repeats == 0 and !in_base) {
                try self.kept.append(allocator, p);
                continue;
            }
            try self.notes.append(allocator, .{
                .line = p.line,
                .flags = if (repeats != 0) NoteFlag.repeats_line else NoteFlag.repeats_builtin,
                .other = repeats,
                .builtin = builtin,
                .peers = 0,
            });
            self.report.dropped += 1;
        }
        for (self.kept.items) |k| {
            var on_code: std.ArrayList(u32) = .empty;
            defer on_code.deinit(allocator);
            for (self.kept.items) |o| if (std.mem.eql(u8, o.keys, k.keys)) try on_code.append(allocator, o.line);
            const builtin: u32 = if (wordsOn(base, k.keys)) |w| @intCast(w.len()) else 0;
            const peers: u32 = @intCast(on_code.items.len - 1);
            if (builtin == 0 and peers == 0) continue;
            var flags: u32 = 0;
            if (builtin != 0) flags |= NoteFlag.code_in_builtin;
            if (peers != 0) flags |= NoteFlag.code_in_line;
            const other: u32 = if (peers == 0) 0 else if (on_code.items[0] == k.line) on_code.items[1] else on_code.items[0];
            try self.notes.append(allocator, .{ .line = k.line, .flags = flags, .other = other, .builtin = builtin, .peers = peers });
            self.report.shared += 1;
        }
        std.sort.pdq(Note, self.notes.items, {}, noteLess);
        self.report.entries = @intCast(self.kept.items.len);
        self.report.notes = @intCast(self.notes.items.len);
        return self;
    }

    fn deinit(self: *Reference, allocator: std.mem.Allocator) void {
        self.notes.deinit(allocator);
        self.kept.deinit(allocator);
    }
};

test "build agrees with the slow reference on random texts" {
    var base = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "甲" },
        .{ .keys = "ab", .value = "乙" },
        .{ .keys = "ab", .value = "丙" },
        .{ .keys = "ba", .value = "丁" },
    });
    defer base.deinit(testing.allocator);

    // Few codes and few values, so repeats, built-in words and shared codes
    // are all common; now and then a line that does not parse.
    const codes = [_][]const u8{ "a", "b", "ab", "ba", "aa", "abc" };
    const values = [_][]const u8{ "甲", "乙", "丙", "丁", "戊" };
    var prng = std.Random.DefaultPrng.init(0xD1C7);
    const r = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..3000) |round| {
        text.clearRetainingCapacity();
        const lines = r.uintLessThan(usize, if (round % 100 == 0) 400 else 30);
        for (0..lines) |_| {
            switch (r.uintLessThan(u8, 20)) {
                0 => try text.appendSlice(testing.allocator, "# note\n"),
                1 => try text.appendSlice(testing.allocator, "\n"),
                2 => try text.appendSlice(testing.allocator, "no tab\n"),
                3 => try text.appendSlice(testing.allocator, "甲\tA\n"),
                else => try text.print(testing.allocator, "{s}\t{s}\n", .{
                    values[r.uintLessThan(usize, values.len)],
                    codes[r.uintLessThan(usize, codes.len)],
                }),
            }
        }
        var want = try Reference.init(testing.allocator, text.items, &base.trie);
        defer want.deinit(testing.allocator);
        var blob = try buildAlloc(testing.allocator, text.items, &base.trie, FP, null);
        defer blob.deinit(testing.allocator);

        try testing.expectEqual(want.report.entries, blob.report.entries);
        try testing.expectEqual(want.report.dropped, blob.report.dropped);
        try testing.expectEqual(want.report.shared, blob.report.shared);
        try testing.expectEqual(want.report.invalid, blob.report.invalid);
        try testing.expectEqualDeep(@as([]const Note, want.notes.items), blob.notes());
        const d = try blob.dict(FP);
        var buf: [MAX_KEYS_LEN]u8 = undefined;
        for (want.kept.items, 0..) |k, i| {
            try testing.expectEqualStrings(k.keys, keysOf(&d, i, &buf));
            try testing.expectEqualStrings(k.value, valueOf(&d, i));
        }
    }
}

test "many phrases on one code: repeats found without a quadratic scan" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);
    // 50 000 distinct phrases on one code, then every one of them again:
    // the old scan back over a code's kept phrases took seconds here.
    const distinct = 50_000;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..2) |_| {
        for (0..distinct) |i| try text.print(testing.allocator, "词{d}\tzzzz\n", .{i});
    }
    var blob = try buildAlloc(testing.allocator, text.items, &base.trie, FP, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, distinct), blob.report.entries);
    try testing.expectEqual(@as(u32, distinct), blob.report.dropped);
    try testing.expectEqual(@as(u32, distinct), blob.report.shared);

    // Kept in file order; each copy names its first line.
    const d = try blob.dict(FP);
    try testing.expectEqualStrings("词0", valueOf(&d, 0));
    try testing.expectEqualStrings("词49999", valueOf(&d, distinct - 1));
    const notes = blob.notes();
    try testing.expectEqual(Note{ .line = 1, .flags = NoteFlag.code_in_line, .other = 2, .builtin = 0, .peers = distinct - 1 }, notes[0]);
    try testing.expectEqual(Note{ .line = distinct + 7, .flags = NoteFlag.repeats_line, .other = 7, .builtin = 0, .peers = 0 }, notes[distinct + 6]);
}

test "the text cap, and line numbers up to it" {
    var base = try emptyBase(testing.allocator);
    defer base.deinit(testing.allocator);

    // At the cap: a phrase on line 1 and its repeat on the last line, past
    // 2^23 lines of blanks.
    const text = try testing.allocator.alloc(u8, TEXT_MAX);
    defer testing.allocator.free(text);
    @memset(text, '\n');
    @memcpy(text[0..4], "x\ta\n");
    @memcpy(text[TEXT_MAX - 3 ..], "x\ta");
    var blob = try buildAlloc(testing.allocator, text, &base.trie, FP, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), blob.report.entries);
    // Line 1 is 4 bytes, the last line 3, and every byte between is a line.
    const last: u32 = @intCast(1 + (TEXT_MAX - 7) + 1);
    try testing.expectEqualDeep(
        @as([]const Note, &.{.{ .line = last, .flags = NoteFlag.repeats_line, .other = 1, .builtin = 0, .peers = 0 }}),
        blob.notes(),
    );

    // One byte more is refused before anything is read.
    const over = try testing.allocator.alloc(u8, TEXT_MAX + 1);
    defer testing.allocator.free(over);
    @memset(over, '\n');
    var report: Report = undefined;
    try testing.expectError(error.BuildFailed, buildAlloc(testing.allocator, over, &base.trie, FP, &report));
    try testing.expectEqual(@backingInt(Status.text_too_long), report.status);
    try testing.expectEqual(@as(u32, 0), report.line);
}
