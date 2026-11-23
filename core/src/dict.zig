//! Dictionaries from text: the line rules every dictionary shares, the
//! builder that turns `value<TAB>keys` lines into a dictionary blob, and
//! the check that lets the engine read a blob a host hands it.
//!
//! The embedded dictionary is built here too, by `scripts/gen_trie.zig` at
//! build time; a host builds its own the same way at runtime and passes
//! it to `jd_init` in place of the embedded one. A user dictionary
//! (`user_dict.zig`) follows the same line rules and sits on top of
//! whichever dictionary it was built against.
//!
//! Nothing in this file allocates. `build` works entirely inside the
//! host's buffer, sized beforehand by `blobBound`; `open` is a view over
//! the host's bytes, checked whole first, so the engine never trusts them.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const fmt = @import("./blob_format.zig");
const trie_mod = @import("./trie.zig");
const Trie = trie_mod.Trie;

pub const MAX_KEYS_LEN: usize = trie_mod.MAX_KEYS_LEN;

/// Most entries in one dictionary: a node's subtree count is 24 bits, and
/// the root's counts them all. Mirrors `JD_DICT_MAX_ENTRIES`.
pub const MAX_ENTRIES: u32 = 0x00FF_FFFF;

/// Longest value in bytes, excluding its NUL, in any dictionary — a user
/// dictionary too. Mirrors `JD_DICT_VALUE_MAX` and `JD_USER_DICT_VALUE_MAX`.
/// A constant rather than the longest value in whichever dictionary is
/// loaded, so the commit-length bound (`JD_ABI_MAX_COMMIT_LEN`) is too.
pub const VALUE_MAX: u32 = 1023;

/// Longest text `build` takes: offsets into it and its line numbers are
/// tracked in 32 bits. Mirrors `JD_DICT_TEXT_MAX`.
pub const TEXT_MAX: usize = std.math.maxInt(u32);

/// Key ranks run a-z (0-25), then ';' (26). See `trie.keyRank`.
pub const KEY_RANKS: u8 = 27;
pub const SEMICOLON_RANK: u8 = 26;

comptime {
    // The lexicographic code packing below: six keys, 5 bits each.
    std.debug.assert(MAX_KEYS_LEN == 6);
    std.debug.assert(KEY_RANKS + 1 <= 32);
    std.debug.assert(VALUE_MAX < std.math.maxInt(u32));
}

// =========================================================================
// What a build reports, and the status codes every dictionary call shares.
// =========================================================================

/// Mirrors the `JD_USER_DICT_*` status codes in `include/jd.h`, which the
/// `jd_dict_*` calls return too. These are failures of a call as a whole;
/// a line that does not parse is not one — a build skips it and leaves a
/// `Note` saying why.
pub const Status = enum(u32) {
    ok = 0,
    /// build: the output buffer is smaller than the bound requires.
    buffer_too_small = 1,
    /// build: more entries than the dictionary's cap.
    too_many_entries = 2,
    /// check/init: built by a different libjd (format version or
    /// endianness), or — a user dictionary — against another dictionary.
    stale = 3,
    /// check/init: structurally invalid.
    corrupt = 4,
    /// check/init/build: a blob or buffer is not 4-byte aligned.
    misaligned = 5,
    /// build: the input text exceeds the dictionary's text cap.
    text_too_long = 6,
    /// No dictionary was given, and this libjd has none of its own
    /// (libjd-engine).
    no_builtin = 7,
};

/// Mirrors `jd_user_dict_report` (alias `jd_dict_report`).
pub const Report = extern struct {
    /// A `Status` value.
    status: u32,
    /// 1-based line of the input the status refers to; 0 when it refers
    /// to the whole call.
    line: u32,
    /// Entries that made it into the blob.
    entries: u32,
    /// Lines dropped as exact duplicates — of an earlier line with the
    /// same keys and value, or (a user dictionary) of a word on the same
    /// code in the dictionary beneath.
    dropped: u32,
    /// A user dictionary's kept phrases on a shared code (重码); always 0
    /// for a dictionary, where shared codes are the norm.
    shared: u32,
    /// Lines skipped because they do not parse: no TAB, bad keys, or a bad
    /// value.
    invalid: u32,
    /// Notes the build left past the blob — `dropped + shared + invalid` —
    /// ascending by line.
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

/// Mirrors `jd_user_dict_note` (alias `jd_dict_note`): one thing a build
/// has to say about an input line. A skipped line — it does not parse —
/// carries exactly one of `malformed`, `bad_keys` and `bad_value`, and
/// nothing else; a dropped line carries a `repeats_*` flag; a user
/// dictionary's kept line whose code is already taken carries `code_in_*`
/// flags.
pub const Note = extern struct {
    /// 1-based input line.
    line: u32,
    /// `NoteFlag` bits.
    flags: u32,
    /// A kept line this one relates to: for a repeat, the line it repeats
    /// (0 for a word in the dictionary beneath); for a shared code, the
    /// first kept line on that code — and for that first line, the
    /// second. 0 otherwise.
    other: u32,
    /// Words of the dictionary beneath on exactly this code; 0 on a
    /// skipped line, and always for a dictionary.
    builtin: u32,
    /// Other kept lines on exactly this code; 0 on a dropped or skipped
    /// line, and always for a dictionary.
    peers: u32,
};

/// Mirrors the `JD_USER_DICT_LINE_*` flags.
pub const NoteFlag = struct {
    /// Dropped: same keys and value as the kept line `other`.
    pub const repeats_line: u32 = 0x1;
    /// Dropped: same keys and value as a word in the dictionary beneath.
    pub const repeats_builtin: u32 = 0x2;
    /// Kept: a word of the dictionary beneath sits on exactly this code;
    /// the phrase is listed ahead of it.
    pub const code_in_builtin: u32 = 0x4;
    /// Kept: the kept line `other` sits on this code too; file order
    /// decides between them.
    pub const code_in_line: u32 = 0x8;
    /// Skipped: neither blank nor a comment, and no TAB.
    pub const malformed: u32 = 0x10;
    /// Skipped: keys empty, longer than `MAX_KEYS_LEN`, not all a-z and
    /// ';', or a ';' after a letter.
    pub const bad_keys: u32 = 0x20;
    /// Skipped: value empty, longer than `VALUE_MAX`, not UTF-8, or
    /// containing control bytes.
    pub const bad_value: u32 = 0x40;
};

/// Mirrors `jd_user_dict_info` (alias `jd_dict_info`): what a check can
/// tell about a valid blob without the host re-parsing anything.
pub const Info = extern struct {
    /// The host-defined tag the build was given.
    source_tag: u64,
    /// Entries in the blob.
    entries: u32,
};

comptime {
    // Notes are part of the ABI, laid out 4-aligned past a blob.
    std.debug.assert(@sizeOf(Note) == 20);
    std.debug.assert(@alignOf(Note) == 4);
}

pub const Error = error{ Misaligned, Corrupt, Stale };

pub fn statusOf(err: Error) Status {
    return switch (err) {
        error.Misaligned => .misaligned,
        error.Corrupt => .corrupt,
        error.Stale => .stale,
    };
}

// =========================================================================
// Lines
// =========================================================================

pub const Line = struct {
    value: []const u8,
    keys: []const u8,
};

pub const ParseError = error{ MalformedLine, BadKeys, BadValue };

/// Parse one raw line — the rules of every dictionary, the embedded one
/// included. Null for blank and comment lines.
///
///   - The line is trimmed of spaces and CRs at both ends; a line that is
///     then empty is blank, and one that starts with `#` is a comment.
///   - Any other line splits at its first TAB into the value before it and
///     the keys after it, each trimmed of spaces. No TAB: malformed.
///   - Keys: `isValidKeys`.
///   - Value: 1 to `VALUE_MAX` bytes of UTF-8 with no control bytes.
pub fn parseLine(raw: []const u8) ParseError!?Line {
    const trimmed = std.mem.trim(u8, raw, " \r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const tab = std.mem.findScalar(u8, trimmed, '\t') orelse return error.MalformedLine;
    const value = std.mem.trim(u8, trimmed[0..tab], " ");
    const keys = std.mem.trim(u8, trimmed[tab + 1 ..], " ");
    if (!isValidKeys(keys)) return error.BadKeys;
    if (value.len == 0 or value.len > VALUE_MAX or !isCleanValue(value)) return error.BadValue;
    return .{ .value = value, .keys = keys };
}

/// A code: 1 to `MAX_KEYS_LEN` keys, each a-z or ';', and no ';' after a
/// letter. After a letter there are candidates on screen, and ';' commits
/// the second of them (`query.zig`, case B) — a code that went on with
/// ';' there would take the key away from that. Before the first letter
/// there is nothing to pick, so a code may start with ';' — the symbol
/// codes do — and go on with more of them (`;;` is ：).
pub fn isValidKeys(keys: []const u8) bool {
    if (keys.len == 0 or keys.len > MAX_KEYS_LEN) return false;
    var i: usize = 0;
    while (i < keys.len and keys[i] == ';') i += 1;
    for (keys[i..]) |k| if (k < 'a' or k > 'z') return false;
    return true;
}

/// `isValidKeys` over rank bytes (see `trie.keyRank`).
pub fn isValidRanks(ranks: []const u8) bool {
    if (ranks.len == 0 or ranks.len > MAX_KEYS_LEN) return false;
    var i: usize = 0;
    while (i < ranks.len and ranks[i] == SEMICOLON_RANK) i += 1;
    for (ranks[i..]) |r| if (r >= SEMICOLON_RANK) return false;
    return true;
}

// =========================================================================
// Clean values: UTF-8 without control bytes
// =========================================================================

/// One pass over `v`: well-formed UTF-8 (the Unicode byte-sequence table,
/// so no overlong forms, no surrogates, nothing above U+10FFFF) with no C0
/// control byte and no DEL. Values are checked on every build, so this is
/// the build's hot loop; it stays a single pass.
pub fn isCleanValue(v: []const u8) bool {
    return isClean(v, false);
}

/// `isCleanValue`, letting NUL through when `nul_ok` — for a pool of
/// values, whose NULs are counted separately.
inline fn isClean(v: []const u8, comptime nul_ok: bool) bool {
    var i: usize = 0;
    while (i < v.len) {
        const b = v[i];
        if (b < 0x80) {
            if ((b < 0x20 and !(nul_ok and b == 0)) or b == 0x7f) return false;
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

/// A blob's strings pool, which holds `terminators` values back to back,
/// each followed by its NUL: exactly that many NULs, and between them
/// `isCleanValue`'s rules — one pass over the whole pool, in vector
/// registers where the target has them. Every check of a blob runs it over
/// every value, so it is the check's hot loop.
pub fn isCleanPool(pool: []const u8, terminators: usize) bool {
    if (comptime std.simd.suggestVectorLength(u8) != null) return isCleanPoolVector(pool, terminators);
    return isCleanPoolScalar(pool, terminators);
}

pub fn isCleanPoolScalar(pool: []const u8, terminators: usize) bool {
    var nuls: usize = 0;
    for (pool) |b| nuls += @intFromBool(b == 0);
    return nuls == terminators and isClean(pool, true);
}

const POOL_LANES = 16;
const PoolBytes = @Vector(POOL_LANES, u8);
const PoolMask = @Vector(POOL_LANES, bool);

/// A `@shuffle` mask that moves a block `k` bytes later, its first `k`
/// lanes taken from the end of the block before: the byte `k` places back
/// from each lane.
fn backMask(comptime k: usize) [POOL_LANES]i32 {
    var m: [POOL_LANES]i32 = undefined;
    for (0..POOL_LANES) |j| m[j] = if (j >= k) @intCast(j - k) else ~@as(i32, @intCast(POOL_LANES - k + j));
    return m;
}

/// `isCleanPoolScalar`'s rules as lane-wise comparisons: a byte is a
/// continuation exactly when the lead byte one, two or three places back
/// asks for one; the leads that can never start a sequence, and the
/// second bytes that make one overlong, a surrogate or past U+10FFFF, are
/// refused; so are the control bytes other than NUL, which are counted.
pub fn isCleanPoolVector(pool: []const u8, terminators: usize) bool {
    const splat = struct {
        inline fn f(b: u8) PoolBytes {
            return @splat(b);
        }
    }.f;
    var bad: PoolMask = @splat(false);
    var nuls: usize = 0;
    var prev: PoolBytes = splat(0);
    var i: usize = 0;
    // One block past the end, all NUL, so a sequence the pool cuts short
    // is caught; its NULs are not counted.
    const blocks = pool.len / POOL_LANES + 1;
    var tail: [POOL_LANES]u8 = @splat(0);
    @memcpy(tail[0 .. pool.len % POOL_LANES], pool[pool.len - pool.len % POOL_LANES ..]);
    var block: usize = 0;
    while (block <= blocks) : (block += 1) {
        const cur: PoolBytes = if (block < blocks - 1)
            pool[i..][0..POOL_LANES].*
        else if (block == blocks - 1)
            tail
        else
            splat(0);
        i += POOL_LANES;
        const back1 = @shuffle(u8, cur, prev, backMask(1));
        const back2 = @shuffle(u8, cur, prev, backMask(2));
        const back3 = @shuffle(u8, cur, prev, backMask(3));

        const is_cont = (cur & splat(0xC0)) == splat(0x80);
        const wants_cont = (back1 >= splat(0xC0)) | (back2 >= splat(0xE0)) | (back3 >= splat(0xF0));
        bad |= is_cont != wants_cont;
        bad |= (cur == splat(0xC0)) | (cur == splat(0xC1)) | (cur >= splat(0xF5));
        bad |= (back1 == splat(0xE0)) & (cur < splat(0xA0));
        bad |= (back1 == splat(0xED)) & (cur > splat(0x9F));
        bad |= (back1 == splat(0xF0)) & (cur < splat(0x90));
        bad |= (back1 == splat(0xF4)) & (cur > splat(0x8F));
        const nul = cur == splat(0);
        bad |= ((cur < splat(0x20)) & !nul) | (cur == splat(0x7F));
        if (block < blocks) nuls += @popCount(@as(@Int(.unsigned, POOL_LANES), @bitCast(nul)));
        prev = cur;
    }
    // The tail block's padding is NUL too.
    nuls -= POOL_LANES - pool.len % POOL_LANES;
    return !@reduce(.Or, bad) and nuls == terminators;
}

// =========================================================================
// Content hash
// =========================================================================

/// A 64-bit hash of `bytes`: Wyhash (final v4) with seed 0, several
/// gigabytes a second. A host hashes its text with it for a blob's
/// `source_tag`; a build hashes the blob's body with it for the
/// fingerprint. Pinned by test vectors — the same bytes must hash the same
/// in every release, or every host's cache would look stale.
pub fn hash(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0, bytes);
}

// =========================================================================
// Sorting
// =========================================================================

/// 9-bit digits: the counts take 2 KiB of the stack. A frame of over a
/// page gets a stack probe on Windows, and zig's (`___chkstk_ms`) is a
/// compiler-rt symbol that MSVC's linker, which links libjd into the
/// Windows IME, does not have.
const RADIX_BITS = 9;
comptime {
    std.debug.assert(@sizeOf([1 << RADIX_BITS]u32) <= 2048);
}

/// Sort `items` by `keyOf(item)`, a key of `key_bits` bits, stably — items
/// with one key keep the order they came in — with `scratch` (as long as
/// `items`) as the other half of each pass. A least-significant-digit
/// radix sort: a few linear passes, no comparisons, the counts on the
/// stack.
pub fn radixSort(
    comptime T: type,
    items: []T,
    scratch: []T,
    comptime key_bits: comptime_int,
    comptime keyOf: fn (T) u64,
) void {
    std.debug.assert(scratch.len == items.len);
    const passes = (key_bits + RADIX_BITS - 1) / RADIX_BITS;
    var src = items;
    var dst = scratch;
    var counts: [1 << RADIX_BITS]u32 = undefined;
    inline for (0..passes) |pass| {
        const shift = pass * RADIX_BITS;
        const mask = (1 << RADIX_BITS) - 1;
        @memset(&counts, 0);
        for (src) |e| counts[@intCast((keyOf(e) >> shift) & mask)] += 1;
        // A digit every item shares orders nothing: skip the pass.
        if (std.mem.findScalar(u32, &counts, @intCast(src.len)) == null) {
            var sum: u32 = 0;
            for (&counts) |*c| {
                const here = c.*;
                c.* = sum;
                sum += here;
            }
            for (src) |e| {
                const d: usize = @intCast((keyOf(e) >> shift) & mask);
                dst[counts[d]] = e;
                counts[d] += 1;
            }
            std.mem.swap([]T, &src, &dst);
        }
    }
    if (src.ptr != items.ptr) @memcpy(items, src);
}

// =========================================================================
// Builder
// =========================================================================

/// One parsed line while a build runs, in the region past the largest blob
/// the text can make.
const Work = extern struct {
    /// The keys, lexicographically: each key's rank + 1 in 5 bits, the
    /// first key highest, 0 past the end. As an integer, a code sorts
    /// after its prefixes and before everything that follows them — the
    /// order a trie's subtrees lie in, depth first.
    code: u32,
    /// 1-based line in the text.
    line: u32,
    /// The value's bytes in the text.
    value_off: u32,
    value_len: u32,

    fn value(self: Work, text: []const u8) []const u8 {
        return text[self.value_off..][0..self.value_len];
    }

    fn sortKey(self: Work) u64 {
        return self.code;
    }
};

const CODE_BITS = 5 * MAX_KEYS_LEN;

fn packCode(keys: []const u8) u32 {
    var c: u32 = 0;
    for (0..MAX_KEYS_LEN) |i| {
        const r: u32 = if (i < keys.len) @as(u32, trie_mod.keyRank(keys[i])) + 1 else 0;
        c = (c << 5) | r;
    }
    return c;
}

/// Keys in a packed code: its non-zero 5-bit groups, which lead it.
fn codeLen(c: u32) usize {
    if (c == 0) return 0;
    // The last key's group is the lowest non-zero one.
    return MAX_KEYS_LEN - @ctz(c) / 5;
}

/// The key byte at position `i` of a packed code.
fn keyAt(c: u32, i: usize) u8 {
    const shift: u5 = @intCast(5 * (MAX_KEYS_LEN - 1 - i));
    return trie_mod.keyOfRank(@intCast(((c >> shift) & 31) - 1));
}

/// How many leading keys two packed codes share.
fn commonKeys(a: u32, b: u32) usize {
    const x = a ^ b;
    if (x == 0) return codeLen(a);
    // The code sits in the low 30 bits of the u32.
    return (@as(usize, @clz(x)) - (32 - CODE_BITS)) / 5;
}

/// Σ (d − base) for d in (from, to] — the path bytes a run of new depths
/// adds below a node at depth `base`.
fn depthSum(from: usize, to: usize, base: usize) u64 {
    if (to <= from) return 0;
    const hi: u64 = to - base;
    const lo: u64 = from - base;
    return (hi * (hi + 1) - lo * (lo + 1)) / 2;
}

/// How `build` lays out the host's buffer for a text, from one parse of
/// it.
///
///   [largest blob the text can make][Work × entries][Note × filled lines]
///
/// The notes region doubles as the sort's scratch: every entry and every
/// note written so far has a non-empty line of its own, and the region
/// holds 20 bytes for each, more than a `Work`.
const Layout = struct {
    /// Lines with at least one byte: at most one note each.
    filled: usize,
    /// Lines that parse, up to `MAX_ENTRIES`.
    entries: usize,
    work_offset: usize,
    notes_offset: usize,
    bound: usize,

    fn of(text: []const u8) Layout {
        var filled: usize = 0;
        var entries: usize = 0;
        var value_bytes: usize = 0;
        // Entries with a code of at least `d` keys, at `at_least[d - 1]`.
        var at_least: [MAX_KEYS_LEN]usize = @splat(0);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            if (raw.len == 0) continue;
            filled += 1;
            const line = (parseLine(raw) catch continue) orelse continue;
            if (entries == MAX_ENTRIES) continue;
            entries += 1;
            value_bytes += line.value.len;
            for (0..line.keys.len) |d| at_least[d] += 1;
        }
        // A node is a distinct prefix: at depth d, no more than the codes
        // that reach it, nor than there are d-key sequences.
        var nodes: usize = 1;
        var sequences: usize = 1;
        for (at_least) |n| {
            sequences *|= KEY_RANKS;
            nodes += @min(n, sequences);
        }
        const blob_max = fmt.blobSize(nodes, entries, value_bytes + entries);
        const work_offset = std.mem.alignForward(usize, blob_max, 4);
        const notes_offset = work_offset + entries * @sizeOf(Work);
        return .{
            .filled = filled,
            .entries = entries,
            .work_offset = work_offset,
            .notes_offset = notes_offset,
            .bound = notes_offset + filled * @sizeOf(Note),
        };
    }
};

/// Upper bound on what `build` writes into the host's buffer from `text`:
/// the largest blob the text can make, the build's working space, and one
/// `Note` per line that is not empty. One parse of the text; size the
/// output buffer with it.
pub fn blobBound(text: []const u8) usize {
    return Layout.of(text).bound;
}

fn fail(report: *Report, status: Status, line: u32) usize {
    report.status = @backingInt(status);
    report.line = line;
    return 0;
}

fn noteLineLessThan(_: void, a: Note, b: Note) bool {
    return a.line < b.line;
}

/// Value bytes, then line, for the entries on one code: every copy of a
/// value sits right after its first one.
fn valueOrder(text: []const u8, a: Work, b: Work) bool {
    return switch (std.mem.order(u8, a.value(text), b.value(text))) {
        .lt => true,
        .gt => false,
        .eq => a.line < b.line,
    };
}

fn lineOrder(_: void, a: Work, b: Work) bool {
    return a.line < b.line;
}

/// Build a dictionary blob from `text` into `out`, which must hold at
/// least `blobBound(text)` bytes. Returns the blob's length, or 0 with
/// `report.status` set — for a problem with the call as a whole only: a
/// line that does not parse is skipped and noted, never fatal. Drops exact
/// repeats — an earlier line with the same keys and value — with a note.
/// `source_tag` is stored for the host and never interpreted.
///
/// The words on one code keep the order of their lines, and are the
/// candidates on that code in that order.
///
/// Past the blob, at `report.notes_offset`, it leaves one `Note` per line
/// that was skipped or dropped, ascending by line; `report.notes` counts
/// them. Allocates nothing: the sort, the pools and the notes are all laid
/// out inside `out`. The blob is in this machine's byte order.
pub fn build(text: []const u8, out: []align(4) u8, source_tag: u64, report: *Report) usize {
    return buildCapped(text, out, source_tag, report, MAX_ENTRIES);
}

fn buildCapped(text: []const u8, out: []align(4) u8, source_tag: u64, report: *Report, max_entries: u32) usize {
    report.* = Report.empty;
    if (text.len > TEXT_MAX) return fail(report, .text_too_long, 0);
    const layout = Layout.of(text);
    if (out.len < layout.bound) return fail(report, .buffer_too_small, 0);
    const notes: []Note = std.mem.bytesAsSlice(
        Note,
        @as([]align(4) u8, @alignCast(out[layout.notes_offset..][0 .. layout.filled * @sizeOf(Note)])),
    );
    var note_count: u32 = 0;

    // ---- One `Work` per line that parses; a line that does not is
    // skipped with a note saying why. ----
    const slots: []Work = std.mem.bytesAsSlice(
        Work,
        @as([]align(4) u8, @alignCast(out[layout.work_offset..][0 .. layout.entries * @sizeOf(Work)])),
    );
    var n: u32 = 0;
    var invalid: u32 = 0;
    var line_no: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
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
        if (n == max_entries or n == slots.len) return fail(report, .too_many_entries, line_no);
        slots[n] = .{
            .code = packCode(line.keys),
            .line = line_no,
            .value_off = @intCast(@intFromPtr(line.value.ptr) - @intFromPtr(text.ptr)),
            .value_len = @intCast(line.value.len),
        };
        n += 1;
    }
    var entries = slots[0..n];

    // ---- Sort by code, stably, so the entries on one code stay in line
    // order; then drop repeats a code at a time. A code with more than one
    // entry is sorted by value for a moment, so the copies of a value
    // follow its first one and a repeat is found without scanning the
    // code's other entries. ----
    {
        const scratch_off = layout.notes_offset + note_count * @sizeOf(Note);
        std.debug.assert(scratch_off + entries.len * @sizeOf(Work) <= layout.bound);
        const scratch: []Work = std.mem.bytesAsSlice(
            Work,
            @as([]align(4) u8, @alignCast(out[scratch_off..][0 .. entries.len * @sizeOf(Work)])),
        );
        radixSort(Work, entries, scratch, CODE_BITS, Work.sortKey);
    }
    var kept: u32 = 0;
    var dropped: u32 = 0;
    {
        var g: usize = 0;
        while (g < n) {
            const group_code = entries[g].code;
            var end = g + 1;
            while (end < n and entries[end].code == group_code) end += 1;
            if (end - g == 1) {
                entries[kept] = entries[g];
                kept += 1;
                g = end;
                continue;
            }
            std.sort.pdq(Work, entries[g..end], text, valueOrder);
            const group_start = kept;
            var i = g;
            while (i < end) {
                const first = entries[i];
                var run_end = i + 1;
                while (run_end < end and std.mem.eql(u8, entries[run_end].value(text), first.value(text))) run_end += 1;
                // `kept <= i`: this never overwrites an entry still to come.
                entries[kept] = first;
                kept += 1;
                for (entries[i + 1 .. run_end]) |e| {
                    notes[note_count] = .{
                        .line = e.line,
                        .flags = NoteFlag.repeats_line,
                        .other = first.line,
                        .builtin = 0,
                        .peers = 0,
                    };
                    note_count += 1;
                    dropped += 1;
                }
                i = run_end;
            }
            std.sort.pdq(Work, entries[group_start..kept], {}, lineOrder);
            g = end;
        }
    }
    entries = entries[0..kept];
    std.sort.pdq(Note, notes[0..note_count], {}, noteLineLessThan);

    // ---- The trie. Sorted, the entries lie in depth-first order: each
    // node's are one run, its own values first. A node is a distinct
    // prefix, so an entry adds one node for each of its keys past what it
    // shares with the entry before it. ----
    var node_count: usize = 1;
    {
        var prev: u32 = 0;
        for (entries) |e| {
            node_count += codeLen(e.code) - commonKeys(prev, e.code);
            prev = e.code;
        }
    }
    const offsets = fmt.PoolOffsets.compute(node_count, kept);
    const nodes: []fmt.Node = std.mem.bytesAsSlice(
        fmt.Node,
        @as([]align(4) u8, @alignCast(out[offsets.nodes..][0 .. node_count * @sizeOf(fmt.Node)])),
    );
    const values: []fmt.Value = std.mem.bytesAsSlice(
        fmt.Value,
        @as([]align(4) u8, @alignCast(out[offsets.values..][0 .. kept * @sizeOf(fmt.Value)])),
    );
    const by_value: []u32 = std.mem.bytesAsSlice(
        u32,
        @as([]align(4) u8, @alignCast(out[offsets.by_value..][0 .. kept * @sizeOf(u32)])),
    );
    const child_keys = out[offsets.child_keys..][0..fmt.childKeysTotal(node_count)];
    const strings_out = out[offsets.strings..];
    std.debug.assert(offsets.child_keys + std.mem.alignForward(usize, child_keys.len, 4) <= layout.work_offset);

    // Breadth first is depth by depth: the nodes at depth d, in order, are
    // the runs of entries sharing d keys. Each node's values, its children's
    // keys and its counts come from its run; its subtree's node and path
    // totals, which size a context's buffers, from how much each entry in
    // the run shares with the one before.
    var node_idx: usize = 0;
    var child_slot: u32 = 0;
    var value_idx: u32 = 0;
    var str_pos: usize = 0;
    var max_value_len: u32 = 0;
    var frontier_cap: u64 = 0;
    var path_buf_cap: u64 = 0;
    for (0..MAX_KEYS_LEN + 1) |depth| {
        var i: usize = 0;
        while (i < entries.len) {
            if (codeLen(entries[i].code) < depth) {
                i += 1;
                continue;
            }
            const lo = i;
            var hi = lo + 1;
            while (hi < entries.len and commonKeys(entries[hi - 1].code, entries[hi].code) >= depth) hi += 1;

            var own: u32 = 0;
            while (lo + own < hi and codeLen(entries[lo + own].code) == depth) own += 1;
            for (entries[lo..][0..own]) |e| {
                const v = e.value(text);
                @memcpy(strings_out[str_pos..][0..v.len], v);
                strings_out[str_pos + v.len] = 0;
                values[value_idx] = .{ .str_start = @intCast(str_pos), .str_len = e.value_len };
                value_idx += 1;
                str_pos += v.len + 1;
                max_value_len = @max(max_value_len, e.value_len);
            }

            var width: u8 = 0;
            for (lo + own..hi) |j| {
                if (j == lo + own or commonKeys(entries[j - 1].code, entries[j].code) == depth) {
                    child_keys[child_slot + width] = keyAt(entries[j].code, depth);
                    width += 1;
                }
            }

            if (depth > 0) {
                var subtree: u64 = 0;
                var path: u64 = 0;
                for (lo..hi) |j| {
                    const len = codeLen(entries[j].code);
                    const shared = if (j == 0) 0 else commonKeys(entries[j - 1].code, entries[j].code);
                    const from = @max(shared, depth - 1);
                    subtree += len -| from;
                    path += depthSum(@max(from, depth), len, depth);
                }
                frontier_cap = @max(frontier_cap, subtree);
                path_buf_cap = @max(path_buf_cap, path);
            }

            nodes[node_idx] = .{
                .count_and_width = fmt.Node.pack(@intCast(hi - lo), width),
                .values_start = value_idx - own,
                .children_start = child_slot,
                .values_len = own,
            };
            node_idx += 1;
            child_slot += width;
            i = hi;
        }
        // The root is a node with nothing to share.
        if (depth == 0 and entries.len == 0) {
            nodes[0] = .{ .count_and_width = 0, .values_start = 0, .children_start = 0, .values_len = 0 };
            node_idx = 1;
        }
    }
    std.debug.assert(node_idx == node_count);
    std.debug.assert(child_slot == child_keys.len);
    std.debug.assert(value_idx == kept);
    // The padding after the child keys.
    @memset(out[offsets.child_keys + child_keys.len .. offsets.strings], 0);

    // ---- The reverse index: every value, by its bytes and then its
    // index, so equal values sit together in node order. ----
    for (by_value, 0..) |*slot, j| slot.* = @intCast(j);
    std.sort.pdq(u32, by_value, ValueOrder{ .values = values, .strings = strings_out[0..str_pos] }, ValueOrder.lessThan);

    const total = offsets.strings + str_pos;
    const fingerprint = hash(out[@sizeOf(fmt.Header)..total]);
    const header: *fmt.Header = @ptrCast(out.ptr);
    header.* = .{
        .magic = fmt.MAGIC,
        .format_version = fmt.FORMAT_VERSION,
        .endian_tag = fmt.ENDIAN_TAG,
        .node_count = @intCast(node_count),
        .values_count = kept,
        .strings_total = @intCast(str_pos),
        .frontier_cap = @intCast(frontier_cap),
        .path_buf_cap = @intCast(path_buf_cap),
        .max_value_len = max_value_len,
        .fingerprint_lo = @truncate(fingerprint),
        .fingerprint_hi = @truncate(fingerprint >> 32),
        .source_tag_lo = @truncate(source_tag),
        .source_tag_hi = @truncate(source_tag >> 32),
    };
    report.* = .{
        .status = 0,
        .line = 0,
        .entries = kept,
        .dropped = dropped,
        .shared = 0,
        .invalid = invalid,
        .notes = note_count,
        .notes_offset = @intCast(layout.notes_offset),
    };
    return total;
}

/// `by_value`'s order: a value's bytes, then its index.
const ValueOrder = struct {
    values: []const fmt.Value,
    strings: []const u8,

    fn lessThan(self: ValueOrder, a: u32, b: u32) bool {
        return switch (std.mem.order(u8, self.values[a].bytes(self.strings), self.values[b].bytes(self.strings))) {
            .lt => true,
            .gt => false,
            .eq => a < b,
        };
    }
};

// =========================================================================
// Checking a blob from outside
// =========================================================================

/// Validate `bytes` as a dictionary blob and view it. Bytes past the
/// blob's own length are ignored. Checks everything the engine relies on,
/// so a corrupt blob is refused rather than read out of bounds:
///
///   - the header: magic, format version, byte order, sizes;
///   - the tree: breadth-first numbering, child keys in rank order under
///     the code rules (`isValidRanks`), at most `MAX_KEYS_LEN` deep,
///     subtree counts, and the BFS buffer sizes the header claims;
///   - the values: they tile the strings pool, each 1 to `VALUE_MAX`
///     bytes of clean UTF-8 with its NUL;
///   - the reverse index: every value once, in order.
///
/// One pass over the nodes, one over the values and the pool, one over the
/// index; allocates nothing. The fingerprint is not recomputed: it names
/// the contents, it does not protect them.
pub fn open(bytes: []const u8) Error!Trie {
    if (!std.mem.isAligned(@intFromPtr(bytes.ptr), 4)) return error.Misaligned;
    if (bytes.len < @sizeOf(fmt.Header)) return error.Corrupt;
    const aligned: []align(4) const u8 = @alignCast(bytes);
    const h: *const fmt.Header = @ptrCast(aligned.ptr);
    if (!std.mem.eql(u8, &h.magic, &fmt.MAGIC)) return error.Corrupt;
    if (h.format_version != fmt.FORMAT_VERSION or h.endian_tag != fmt.ENDIAN_TAG) return error.Stale;

    const nc: usize = h.node_count;
    const vc: usize = h.values_count;
    if (nc == 0 or vc > MAX_ENTRIES) return error.Corrupt;
    // In 64 bits, so a 32-bit host cannot overflow on a hostile header.
    const total64: u64 = @as(u64, @sizeOf(fmt.Header)) +
        @as(u64, nc) * @sizeOf(fmt.Node) +
        @as(u64, vc) * (@sizeOf(fmt.Value) + @sizeOf(u32)) +
        std.mem.alignForward(u64, nc - 1, 4) +
        h.strings_total;
    if (total64 > bytes.len) return error.Corrupt;
    const total: usize = @intCast(total64);
    std.debug.assert(total == fmt.blobSize(nc, vc, h.strings_total));
    const t = Trie.fromBytes(aligned[0..total]) catch return error.Corrupt;

    try checkNodes(&t, nc, vc);
    try checkValues(&t, h.max_value_len);
    try checkReverseIndex(&t);
    try checkCaps(&t, h.frontier_cap, h.path_buf_cap);
    return t;
}

/// `open` as a status code, for the C ABI, filling `info` when the blob is
/// valid.
pub fn check(bytes: []const u8, info: ?*Info) Status {
    const t = open(bytes) catch |err| return statusOf(err);
    if (info) |out| out.* = .{ .source_tag = t.source_tag, .entries = @intCast(t.values.len) };
    return .ok;
}

fn checkNodes(t: *const Trie, nc: usize, vc: usize) Error!void {
    // Children are numbered in node order, so node i's start where the
    // nodes before it left off; values likewise.
    var child_slot: usize = 0;
    var value_pos: usize = 0;
    // The nodes at the current depth end before `level_end`; the next
    // depth's are the children of every node up to there.
    var depth: usize = 0;
    var level_end: usize = 1;
    // The nodes reached by ';' alone — the root, `;`, `;;`, … — the only
    // ones a ';' child may hang from.
    var semis: [MAX_KEYS_LEN + 1]usize = undefined;
    semis[0] = 0;
    var semis_len: usize = 1;
    for (t.nodes, 0..) |*n, i| {
        if (i == level_end) {
            depth += 1;
            if (depth > MAX_KEYS_LEN or child_slot + 1 <= i) return error.Corrupt;
            level_end = child_slot + 1;
        }
        if (n.children_start != child_slot or n.values_start != value_pos) return error.Corrupt;
        const w: usize = n.width();
        if (w > KEY_RANKS or (depth == MAX_KEYS_LEN and w != 0)) return error.Corrupt;
        if (i == 0 and n.values_len != 0) return error.Corrupt;
        child_slot += w;
        value_pos += n.values_len;
        if (child_slot > nc - 1 or value_pos > vc) return error.Corrupt;

        const keys = t.child_keys[n.children_start..][0..w];
        var count: usize = n.values_len;
        for (keys, 0..) |k, j| {
            const r = trie_mod.keyRank(k);
            if (r >= KEY_RANKS) return error.Corrupt;
            if (j > 0 and r <= trie_mod.keyRank(keys[j - 1])) return error.Corrupt;
            count += t.nodes[n.children_start + 1 + j].count();
        }
        if (count != n.count() or (i != 0 and count == 0)) return error.Corrupt;
        // ';' ranks last, so it is the last child when there is one.
        if (w > 0 and keys[w - 1] == ';') {
            if (depth >= semis_len or semis[depth] != i) return error.Corrupt;
            semis[depth + 1] = n.children_start + w;
            semis_len = depth + 2;
        }
    }
    if (child_slot != nc - 1 or value_pos != vc) return error.Corrupt;
}

fn checkValues(t: *const Trie, max_value_len: u32) Error!void {
    var pos: usize = 0;
    var longest: u32 = 0;
    for (t.values) |v| {
        if (v.str_start != pos or v.str_len == 0 or v.str_len > VALUE_MAX) return error.Corrupt;
        pos += v.str_len;
        if (pos >= t.strings.len or t.strings[pos] != 0) return error.Corrupt;
        pos += 1;
        longest = @max(longest, v.str_len);
    }
    if (pos != t.strings.len or longest != max_value_len) return error.Corrupt;
    // The values tile the pool, so the pool is checked whole: its only
    // NULs are the terminators just seen, and around them it is clean
    // UTF-8 — a NUL is ASCII, so no sequence runs across one.
    if (!isCleanPool(t.strings, t.values.len)) return error.Corrupt;
}

fn checkReverseIndex(t: *const Trie) Error!void {
    // Strictly ascending by (bytes, index) with every index in range is
    // every index exactly once.
    const order: ValueOrder = .{ .values = t.values, .strings = t.strings };
    for (t.by_value, 0..) |v, j| {
        if (v >= t.values.len) return error.Corrupt;
        if (j > 0 and !order.lessThan(t.by_value[j - 1], v)) return error.Corrupt;
    }
}

fn checkCaps(t: *const Trie, frontier_cap: u32, path_buf_cap: u32) Error!void {
    // A subtree is one run of nodes per depth below its root: the children
    // of a run of nodes are a run themselves.
    var most_nodes: u64 = 0;
    var most_path: u64 = 0;
    for (1..t.nodes.len) |i| {
        var a: usize = i;
        var b: usize = i + 1;
        var below: u64 = 0;
        var subtree: u64 = 0;
        var path: u64 = 0;
        while (a < b) : (below += 1) {
            subtree += b - a;
            path += (b - a) * below;
            const first = &t.nodes[a];
            const last = &t.nodes[b - 1];
            a = first.children_start + 1;
            b = last.children_start + last.width() + 1;
        }
        most_nodes = @max(most_nodes, subtree);
        most_path = @max(most_path, path);
    }
    if (most_nodes != frontier_cap or most_path != path_buf_cap) return error.Corrupt;
}

// =========================================================================
// Cross-endian builds
// =========================================================================

/// Byte-swap every u32 field of a blob in place, for a target of the other
/// endianness. Reads the header's counts in `current_endian` to find the
/// pools; afterwards the blob is in the other byte order. Only u32 fields
/// are touched: the magic, child keys and strings are bytes.
pub fn byteSwapBlob(buf: []align(4) u8, current_endian: std.lang.Endian) void {
    const node_count = std.mem.readInt(u32, buf[@offsetOf(fmt.Header, "node_count")..][0..4], current_endian);
    const values_count = std.mem.readInt(u32, buf[@offsetOf(fmt.Header, "values_count")..][0..4], current_endian);
    const offsets = fmt.PoolOffsets.compute(node_count, values_count);
    for (0..fmt.HEADER_WORDS) |i| swap32At(buf, 4 + i * 4);
    for (0..node_count * @sizeOf(fmt.Node) / 4) |i| swap32At(buf, offsets.nodes + i * 4);
    for (0..values_count * @sizeOf(fmt.Value) / 4) |i| swap32At(buf, offsets.values + i * 4);
    for (0..values_count) |i| swap32At(buf, offsets.by_value + i * 4);
}

inline fn swap32At(buf: []align(4) u8, offset: usize) void {
    const slot: *align(4) u32 = @ptrCast(@alignCast(buf[offset..].ptr));
    slot.* = @byteSwap(slot.*);
}

// =========================================================================
// Host-side convenience: build into a fresh aligned allocation.
// =========================================================================

pub const Blob = struct {
    buf: []align(4) u8,
    len: usize,
    report: Report,

    pub fn bytes(self: *const Blob) []align(4) const u8 {
        return self.buf[0..self.len];
    }

    /// The notes the build left past the blob.
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

/// `build` into an allocation sized by `blobBound`. Fails with
/// `error.BuildFailed` when the report carries a non-ok status; the report
/// is still returned through `err_report` when given.
pub fn buildAlloc(allocator: std.mem.Allocator, text: []const u8, source_tag: u64, err_report: ?*Report) !Blob {
    const buf = try allocator.alignedAlloc(u8, .@"4", blobBound(text));
    errdefer allocator.free(buf);
    var report: Report = undefined;
    const len = build(text, buf, source_tag, &report);
    if (report.status != 0) {
        if (err_report) |r| r.* = report;
        return error.BuildFailed;
    }
    return .{ .buf = buf, .len = len, .report = report };
}

// =========================================================================
// Tests
// =========================================================================

/// `s` repeated `n` times (Zig 0.17 has no `**` on arrays).
fn repeat(comptime s: []const u8, comptime n: usize) *const [n * s.len]u8 {
    const buf: [n][s.len]u8 = @splat(s[0..s.len].*);
    return @ptrCast(&buf);
}

/// Every code a blob holds, with its values, by walking the trie depth
/// first — written as `value<TAB>keys` lines, a code's values in order, the
/// codes in key-rank order.
fn dump(allocator: std.mem.Allocator, t: *const Trie) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var path: [MAX_KEYS_LEN]u8 = undefined;
    try dumpNode(allocator, &out, t, t.root(), &path, 0);
    return out.toOwnedSlice(allocator);
}

fn dumpNode(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    t: *const Trie,
    node: *const Trie.Node,
    path: *[MAX_KEYS_LEN]u8,
    depth: usize,
) !void {
    const vals = node.values(t);
    for (0..vals.len()) |i| {
        try out.appendSlice(allocator, vals.at(i));
        try out.append(allocator, '\t');
        try out.appendSlice(allocator, path[0..depth]);
        try out.append(allocator, '\n');
    }
    for (0..node.getWidth()) |c| {
        path[depth] = node.keyOfChildByIndex(t, c).?;
        try dumpNode(allocator, out, t, node.getChildByIndex(t, c).?, path, depth + 1);
    }
}

/// The same, from the text: what a build should keep, in the same order —
/// valid lines, repeats dropped, codes in key-rank order, each code's
/// values in line order.
fn reference(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const Kept = struct {
        rank_code: [MAX_KEYS_LEN + 1]u8,
        keys: []const u8,
        value: []const u8,
        line: usize,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return switch (std.mem.order(u8, &a.rank_code, &b.rank_code)) {
                .lt => true,
                .gt => false,
                .eq => a.line < b.line,
            };
        }
    };
    var kept: std.ArrayList(Kept) = .empty;
    defer kept.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (it.next()) |raw| {
        line_no += 1;
        const line = (parseLine(raw) catch continue) orelse continue;
        var repeated = false;
        for (kept.items) |k| {
            if (std.mem.eql(u8, k.keys, line.keys) and std.mem.eql(u8, k.value, line.value)) repeated = true;
        }
        if (repeated) continue;
        var rc: [MAX_KEYS_LEN + 1]u8 = @splat(0);
        // Depth first: a code before its extensions, siblings by rank.
        for (line.keys, 0..) |k, i| rc[i] = trie_mod.keyRank(k) + 1;
        try kept.append(allocator, .{ .rank_code = rc, .keys = line.keys, .value = line.value, .line = line_no });
    }
    std.sort.pdq(Kept, kept.items, {}, Kept.lessThan);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (kept.items) |k| {
        try out.appendSlice(allocator, k.value);
        try out.append(allocator, '\t');
        try out.appendSlice(allocator, k.keys);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn expectBuildsLikeReference(text: []const u8) !void {
    var blob = try buildAlloc(testing.allocator, text, 0, null);
    defer blob.deinit(testing.allocator);
    const t = try open(blob.bytes());
    const got = try dump(testing.allocator, &t);
    defer testing.allocator.free(got);
    const want = try reference(testing.allocator, text);
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, got);
    try testing.expect(blob.len <= blobBound(text));
}

test "a build keeps every valid line, a code's words in line order" {
    const text =
        "# comment\n" ++
        "丁\tacd\n" ++
        "\n" ++
        "乙\tab\n" ++
        "末尾\taz\r\n" ++
        "甲\ta\n" ++
        "乙2\tab\n" ++
        "  戊  \t  b  \n" ++
        "；\t;\n" ++
        "：\t;;\n" ++
        "@\t;a\n";
    try expectBuildsLikeReference(text);

    var blob = try buildAlloc(testing.allocator, text, 0x1234_5678_9ABC_DEF0, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 9), blob.report.entries);
    const t = try open(blob.bytes());
    try testing.expectEqual(@as(u64, 0x1234_5678_9ABC_DEF0), t.source_tag);
    const ab = t.root().getChild(&t, 'a').?.getChild(&t, 'b').?;
    try testing.expectEqual(@as(usize, 2), ab.values(&t).len());
    try testing.expectEqualStrings("乙", ab.values(&t).at(0));
    try testing.expectEqualStrings("乙2", ab.values(&t).at(1));
    // ';' ranks after the letters.
    try testing.expectEqual(@as(?u8, ';'), t.root().keyOfChildByIndex(&t, t.root().getWidth() - 1));
    try testing.expectEqual(@as(u32, "末尾".len), t.max_value_len);
}

test "a build drops exact repeats and skips lines that do not parse, with notes" {
    const long_value = repeat("长", 341) ++ "x"; // 1024 bytes
    const text =
        "甲\ta\n" ++ // 1
        "甲\ta\n" ++ // 2: repeat of 1
        "no tab here\n" ++ // 3: malformed
        "乙\tA\n" ++ // 4: bad keys
        "乙\ta;\n" ++ // 5: ';' after a letter
        "乙\tabcdefg\n" ++ // 6: too long
        "\tab\n" ++ // 7: empty value
        long_value ++ "\tab\n" ++ // 8: value too long
        "丙\ta\n" ++ // 9
        "甲\ta\n" ++ // 10: repeat of 1
        "乙\t\n"; // 11: no keys
    var blob = try buildAlloc(testing.allocator, text, 0, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), blob.report.entries);
    try testing.expectEqual(@as(u32, 2), blob.report.dropped);
    try testing.expectEqual(@as(u32, 7), blob.report.invalid);
    try testing.expectEqual(@as(u32, 0), blob.report.shared);
    const want = [_]Note{
        .{ .line = 2, .flags = NoteFlag.repeats_line, .other = 1, .builtin = 0, .peers = 0 },
        .{ .line = 3, .flags = NoteFlag.malformed, .other = 0, .builtin = 0, .peers = 0 },
        .{ .line = 4, .flags = NoteFlag.bad_keys, .other = 0, .builtin = 0, .peers = 0 },
        .{ .line = 5, .flags = NoteFlag.bad_keys, .other = 0, .builtin = 0, .peers = 0 },
        .{ .line = 6, .flags = NoteFlag.bad_keys, .other = 0, .builtin = 0, .peers = 0 },
        .{ .line = 7, .flags = NoteFlag.bad_value, .other = 0, .builtin = 0, .peers = 0 },
        .{ .line = 8, .flags = NoteFlag.bad_value, .other = 0, .builtin = 0, .peers = 0 },
        .{ .line = 10, .flags = NoteFlag.repeats_line, .other = 1, .builtin = 0, .peers = 0 },
        .{ .line = 11, .flags = NoteFlag.bad_keys, .other = 0, .builtin = 0, .peers = 0 },
    };
    try testing.expectEqualDeep(@as([]const Note, &want), blob.notes());
    try expectBuildsLikeReference(text);
}

test "values up to VALUE_MAX bytes go in" {
    const v = repeat("长", 341); // 1023 bytes
    try testing.expectEqual(@as(usize, VALUE_MAX), v.len);
    var blob = try buildAlloc(testing.allocator, v ++ "\tab\n", 0, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), blob.report.entries);
    const t = try open(blob.bytes());
    try testing.expectEqual(VALUE_MAX, t.max_value_len);
}

test "the code rules: ';' only before the first letter" {
    try testing.expect(isValidKeys(";"));
    try testing.expect(isValidKeys(";;"));
    try testing.expect(isValidKeys(";a"));
    try testing.expect(isValidKeys(";;abcd"));
    try testing.expect(isValidKeys("abcdef"));
    try testing.expect(!isValidKeys(""));
    try testing.expect(!isValidKeys("abcdefg"));
    try testing.expect(!isValidKeys("a;"));
    try testing.expect(!isValidKeys(";a;"));
    try testing.expect(!isValidKeys("aB"));
    try testing.expect(!isValidKeys("a b"));
    try testing.expect(!isValidKeys("a1"));
    var buf: [MAX_KEYS_LEN]u8 = undefined;
    for ([_][]const u8{ ";", ";;", ";a", ";;abcd", "abcdef", "a;", ";a;", "z;" }) |keys| {
        for (keys, 0..) |k, i| buf[i] = trie_mod.keyRank(k);
        try testing.expectEqual(isValidKeys(keys), isValidRanks(buf[0..keys.len]));
    }
}

test "an empty text builds an empty dictionary" {
    for ([_][]const u8{ "", "\n\n", "# only a comment\n", "bad line\n" }) |text| {
        var blob = try buildAlloc(testing.allocator, text, 0, null);
        defer blob.deinit(testing.allocator);
        const t = try open(blob.bytes());
        try testing.expectEqual(@as(usize, 1), t.nodes.len);
        try testing.expectEqual(@as(usize, 0), t.values.len);
        try testing.expectEqual(@as(u32, 0), t.frontier_cap);
        try testing.expectEqual(@as(u32, 0), t.path_buf_cap);
        try testing.expect(t.root().getChild(&t, 'a') == null);
    }
    // Every empty dictionary is the same dictionary.
    var a = try buildAlloc(testing.allocator, "", 1, null);
    defer a.deinit(testing.allocator);
    var b = try buildAlloc(testing.allocator, "# nothing\n", 2, null);
    defer b.deinit(testing.allocator);
    try testing.expectEqual((try open(a.bytes())).fingerprint, (try open(b.bytes())).fingerprint);
}

test "the fingerprint follows the contents, not the source tag" {
    var a = try buildAlloc(testing.allocator, "甲\ta\n乙\tb\n", 1, null);
    defer a.deinit(testing.allocator);
    var b = try buildAlloc(testing.allocator, "# reordered\n乙\tb\n甲\ta\n", 2, null);
    defer b.deinit(testing.allocator);
    var c = try buildAlloc(testing.allocator, "甲\ta\n丙\tb\n", 1, null);
    defer c.deinit(testing.allocator);
    const fa = (try open(a.bytes())).fingerprint;
    try testing.expectEqual(fa, (try open(b.bytes())).fingerprint);
    try testing.expect(fa != (try open(c.bytes())).fingerprint);
}

test "the BFS caps a build records are what the tree needs" {
    // `open` recomputes them from the tree, independently of the build.
    var blob = try buildAlloc(testing.allocator, "甲\ta\n乙\tab\n丙\tac\n丁\tacd\n戊\tace\n己\tacef\n庚\tb\n辛\tbcdefg\n", 0, null);
    defer blob.deinit(testing.allocator);
    const t = try open(blob.bytes());
    // Under "a": a, ab, ac, acd, ace, acef → 6 nodes; path bytes below a:
    // ab 1 + ac 1 + acd 2 + ace 2 + acef 3 = 9. Under "b": b, bc … bcdefg →
    // 6 nodes, path 1+2+3+4+5 = 15.
    try testing.expectEqual(@as(u32, 6), t.frontier_cap);
    try testing.expectEqual(@as(u32, 15), t.path_buf_cap);
}

test "a build agrees with the slow reference on random texts" {
    var prng = std.Random.DefaultPrng.init(0x5eed_d1c7);
    const rand = prng.random();
    const pieces = [_][]const u8{ "甲", "乙", "丙", "x", "yz", "长长" };
    for (0..200) |_| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        const lines = rand.uintAtMost(usize, 60);
        for (0..lines) |_| {
            switch (rand.uintLessThan(u8, 20)) {
                0 => try text.appendSlice(testing.allocator, "# comment"),
                1 => {},
                2 => try text.appendSlice(testing.allocator, "no tab"),
                else => {
                    try text.appendSlice(testing.allocator, pieces[rand.uintLessThan(usize, pieces.len)]);
                    try text.append(testing.allocator, '\t');
                    const semis = if (rand.uintLessThan(u8, 6) == 0) rand.uintAtMost(usize, 2) else 0;
                    const len = rand.uintAtMost(usize, MAX_KEYS_LEN + 1);
                    for (0..len) |i| {
                        // A small alphabet, so codes share prefixes; now and
                        // then a ';' where it may go, or where it may not.
                        const k: u8 = if (i < semis or rand.uintLessThan(u8, 40) == 0) ';' else "abc"[rand.uintLessThan(usize, 3)];
                        try text.append(testing.allocator, k);
                    }
                },
            }
            try text.append(testing.allocator, '\n');
        }
        try expectBuildsLikeReference(text.items);
    }
}

test "a build fits its bound exactly, however the lines go" {
    const texts = [_][]const u8{
        "",
        "甲\ta",
        "a\tabcdef\nb\tbcdefa\nc\tcdefab\n",
        "bad\nbad\nbad\n甲\ta\n",
        "甲\ta\n甲\ta\n甲\ta\n",
        "x\t;\nx\t;;\nx\t;;;\nx\t;;;;\nx\t;;;;;\nx\t;;;;;;\n",
    };
    for (texts) |text| {
        const bound = blobBound(text);
        const buf = try testing.allocator.alignedAlloc(u8, .@"4", bound);
        defer testing.allocator.free(buf);
        var report: Report = undefined;
        const len = build(text, buf, 0, &report);
        try testing.expectEqual(@as(u32, 0), report.status);
        _ = try open(buf[0..len]);
        try testing.expectEqual(@as(u32, @backingInt(Status.buffer_too_small)), blk: {
            _ = build(text, buf[0 .. bound - 1], 0, &report);
            break :blk report.status;
        });
    }
}

test "the entry cap fails the build at the first line past it" {
    const text = "a\ta\nb\tb\n# c\nc\tc\n";
    const buf = try testing.allocator.alignedAlloc(u8, .@"4", blobBound(text));
    defer testing.allocator.free(buf);
    var report: Report = undefined;
    try testing.expectEqual(@as(usize, 0), buildCapped(text, buf, 0, &report, 2));
    try testing.expectEqual(@as(u32, @backingInt(Status.too_many_entries)), report.status);
    try testing.expectEqual(@as(u32, 4), report.line);
}

test "open refuses misaligned, stale and corrupt blobs" {
    var blob = try buildAlloc(testing.allocator, "甲\ta\n乙\tab\n丙\tac\n：\t;;\n", 0, null);
    defer blob.deinit(testing.allocator);
    const good = blob.bytes();
    _ = try open(good);

    const copy = try testing.allocator.alignedAlloc(u8, .@"4", good.len + 4);
    defer testing.allocator.free(copy);

    // Misaligned.
    @memcpy(copy[1..][0..good.len], good);
    try testing.expectError(error.Misaligned, open(copy[1..][0..good.len]));

    const Case = struct { offset: usize, xor: u8, err: Error };
    const offsets = fmt.PoolOffsets.compute(
        @as(*const fmt.Header, @ptrCast(good.ptr)).node_count,
        @as(*const fmt.Header, @ptrCast(good.ptr)).values_count,
    );
    const cases = [_]Case{
        .{ .offset = 0, .xor = 1, .err = error.Corrupt }, // magic
        .{ .offset = @offsetOf(fmt.Header, "format_version"), .xor = 1, .err = error.Stale },
        .{ .offset = @offsetOf(fmt.Header, "endian_tag"), .xor = 1, .err = error.Stale },
        .{ .offset = @offsetOf(fmt.Header, "node_count"), .xor = 1, .err = error.Corrupt },
        .{ .offset = @offsetOf(fmt.Header, "values_count"), .xor = 1, .err = error.Corrupt },
        .{ .offset = @offsetOf(fmt.Header, "strings_total"), .xor = 4, .err = error.Corrupt },
        .{ .offset = @offsetOf(fmt.Header, "frontier_cap"), .xor = 1, .err = error.Corrupt },
        .{ .offset = @offsetOf(fmt.Header, "path_buf_cap"), .xor = 1, .err = error.Corrupt },
        .{ .offset = @offsetOf(fmt.Header, "max_value_len"), .xor = 1, .err = error.Corrupt },
        .{ .offset = offsets.nodes + 0, .xor = 1, .err = error.Corrupt }, // root count
        .{ .offset = offsets.nodes + 3, .xor = 1, .err = error.Corrupt }, // root width
        .{ .offset = offsets.nodes + 16 + 4, .xor = 1, .err = error.Corrupt }, // values_start
        .{ .offset = offsets.nodes + 16 + 8, .xor = 1, .err = error.Corrupt }, // children_start
        .{ .offset = offsets.nodes + 16 + 12, .xor = 1, .err = error.Corrupt }, // values_len
        .{ .offset = offsets.values, .xor = 1, .err = error.Corrupt }, // str_start
        .{ .offset = offsets.values + 4, .xor = 1, .err = error.Corrupt }, // str_len
        .{ .offset = offsets.by_value, .xor = 1, .err = error.Corrupt },
        .{ .offset = offsets.child_keys, .xor = 'a' ^ ';', .err = error.Corrupt }, // ';' before a letter sibling
        .{ .offset = offsets.child_keys, .xor = 0x20, .err = error.Corrupt }, // 'A'
        .{ .offset = offsets.strings + 3, .xor = 0xFF, .err = error.Corrupt }, // a NUL turned to 0xFF
        .{ .offset = offsets.strings, .xor = 0x40, .err = error.Corrupt }, // broken UTF-8
    };
    for (cases) |c| {
        @memcpy(copy[0..good.len], good);
        copy[c.offset] ^= c.xor;
        _ = open(copy[0..good.len]) catch |err| {
            try testing.expectEqual(c.err, err);
            continue;
        };
        std.debug.print("corruption at {d} went unnoticed\n", .{c.offset});
        return error.TestUnexpectedResult;
    }
    // Too short for what the header says.
    @memcpy(copy[0..good.len], good);
    try testing.expectError(error.Corrupt, open(copy[0 .. good.len - 1]));
    // Bytes past the blob are ignored.
    try testing.expect((try open(copy[0 .. good.len + 4])).values.len == 4);
}

test "a ';' child under a letter is refused" {
    var blob = try buildAlloc(testing.allocator, "甲\tab\n乙\ta\n", 0, null);
    defer blob.deinit(testing.allocator);
    const copy = try testing.allocator.alignedAlloc(u8, .@"4", blob.len);
    defer testing.allocator.free(copy);
    @memcpy(copy, blob.bytes());
    const h: *const fmt.Header = @ptrCast(copy.ptr);
    const offsets = fmt.PoolOffsets.compute(h.node_count, h.values_count);
    // Child slot 1 is node 2, "ab": make its key ';', so "a;" — under a
    // letter.
    copy[offsets.child_keys + 1] = ';';
    try testing.expectError(error.Corrupt, open(copy));
}

test "a cross-endian blob checks as stale, and swapping back restores it" {
    var blob = try buildAlloc(testing.allocator, "甲\ta\n乙\tab\n：\t;;\n", 0, null);
    defer blob.deinit(testing.allocator);
    const copy = try testing.allocator.alignedAlloc(u8, .@"4", blob.len);
    defer testing.allocator.free(copy);
    @memcpy(copy, blob.bytes());
    const native = builtin.target.cpu.arch.endian();
    byteSwapBlob(copy, native);
    try testing.expectError(error.Stale, open(copy));
    const other: std.lang.Endian = if (native == .little) .big else .little;
    byteSwapBlob(copy, other);
    try testing.expectEqualSlices(u8, blob.bytes(), copy);
}

test "packed codes: length, keys, shared prefixes" {
    try testing.expectEqual(@as(usize, 0), codeLen(packCode("")));
    try testing.expectEqual(@as(usize, 1), codeLen(packCode("a")));
    try testing.expectEqual(@as(usize, 6), codeLen(packCode("abcdef")));
    try testing.expectEqual(@as(usize, 2), codeLen(packCode(";;")));
    try testing.expectEqual(@as(u8, ';'), keyAt(packCode("a;"), 1));
    try testing.expectEqual(@as(u8, 'z'), keyAt(packCode("zzzzzz"), 5));
    try testing.expectEqual(@as(usize, 2), commonKeys(packCode("abc"), packCode("abd")));
    try testing.expectEqual(@as(usize, 2), commonKeys(packCode("ab"), packCode("abd")));
    try testing.expectEqual(@as(usize, 3), commonKeys(packCode("abc"), packCode("abc")));
    try testing.expectEqual(@as(usize, 0), commonKeys(packCode("a"), packCode("b")));
    try testing.expectEqual(@as(usize, 0), commonKeys(0, packCode("b")));
    // A code sorts after its prefixes, before its next sibling.
    try testing.expect(packCode("a") < packCode("ab"));
    try testing.expect(packCode("ab") < packCode("abz"));
    try testing.expect(packCode("abz") < packCode("ab;"));
    try testing.expect(packCode("ab;") < packCode("ac"));
    try testing.expect(packCode("z") < packCode(";"));
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

test "the vector pool check agrees with the scalar one" {
    // Random pools, biased toward the bytes that matter — NULs, controls,
    // lead and continuation bytes — at every length across a few blocks,
    // so sequences straddle block edges and the tail.
    var prng = std.Random.DefaultPrng.init(0xB10C);
    const r = prng.random();
    var buf: [5 * POOL_LANES + 7]u8 = undefined;
    var agreed_clean: usize = 0;
    for (0..200_000) |round| {
        const len = r.uintLessThan(usize, buf.len + 1);
        for (buf[0..len]) |*b| {
            b.* = switch (r.uintLessThan(u8, 12)) {
                0 => r.int(u8),
                1 => 0,
                2 => r.uintLessThan(u8, 0x20),
                3, 4 => 0x20 + r.uintLessThan(u8, 0x60),
                5, 6 => 0x80 + r.uintLessThan(u8, 0x40),
                7 => 0xC0 + r.uintLessThan(u8, 0x20),
                8 => 0xE0 + r.uintLessThan(u8, 0x10),
                9 => 0xF0 + r.uintLessThan(u8, 0x10),
                else => "a\x00"[r.uintLessThan(usize, 2)],
            };
        }
        // Splice in whole sequences at random spots, half the time.
        if (round % 2 == 0 and len >= 4) {
            const at = r.uintLessThan(usize, len - 3);
            @memcpy(buf[at..][0..3], "你");
        }
        const pool = buf[0..len];
        var nuls: usize = 0;
        for (pool) |b| nuls += @intFromBool(b == 0);
        const want = isCleanPoolScalar(pool, nuls);
        try testing.expectEqual(want, isCleanPoolVector(pool, nuls));
        if (want) agreed_clean += 1;
        // A wrong terminator count is refused either way.
        try testing.expect(!isCleanPoolVector(pool, nuls + 1));
    }
    try testing.expect(agreed_clean > 1000);

    // Clean text of every length, cut and uncut.
    const text = "键道\x00a\x00\xF0\x9F\x98\x80\x00©x\x00中文输入法\x00";
    for (0..text.len + 1) |cut| {
        const pool = text[0..cut];
        var nuls: usize = 0;
        for (pool) |b| nuls += @intFromBool(b == 0);
        try testing.expectEqual(isCleanPoolScalar(pool, nuls), isCleanPoolVector(pool, nuls));
    }
}

test "hash: pinned values, and a different value for any change" {
    // Pinned: a host's cached blobs are tagged with these, so a change in
    // the function (a Zig upgrade swapping its Wyhash) must not go unseen.
    try testing.expectEqual(@as(u64, 0x0409638EE2BDE459), hash(""));
    try testing.expectEqual(@as(u64, 0xB5F6C3766F38E694), hash("键道\tjd\n"));
    var long: [1000]u8 = undefined;
    for (&long, 0..) |*b, i| b.* = @truncate(i *% 31);
    try testing.expectEqual(@as(u64, 0xA1C52CEC77FCE62F), hash(&long));

    var copy = long;
    copy[999] ^= 1;
    try testing.expect(hash(&copy) != hash(&long));
    try testing.expect(hash(long[0..999]) != hash(&long));
}
