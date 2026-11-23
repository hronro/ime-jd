//! Reverse lookup: the codes a value is typed with.
//!
//! The built-in half is the trie's `by_value` index — one binary search,
//! then each hit's node walked back to the root (`Trie.codeOf`). The user
//! half is a linear scan of the context's user dictionary, which is capped
//! at `user_dict.MAX_ENTRIES`. Both come out shortest code first, ties by
//! key rank — the order the trie enumerates candidates in — so they merge
//! like the candidate lists do, with a user phrase ahead of a built-in word
//! on the same code. Nothing here allocates or touches a context's
//! composition: it reads the dictionaries and writes into caller memory.

const std = @import("std");
const testing = std.testing;
const trie_mod = @import("trie");
const Trie = trie_mod.Trie;
const user_dict = @import("./user_dict.zig");
const UserDict = user_dict.UserDict;

const MAX_KEYS_LEN: usize = trie_mod.MAX_KEYS_LEN;

/// Inline key capacity of a `Code`, including the NUL terminator. Mirrors
/// `JD_CODE_CAP` in `include/jd.h`; reported through `jd_abi_layout`.
pub const CODE_CAP: usize = 8;

comptime {
    // `jd.h` hard-codes `char keys[8]`: a code and its NUL must fit.
    if (MAX_KEYS_LEN + 1 > CODE_CAP) {
        @compileError("MAX_KEYS_LEN outgrew the inline code capacity declared in jd.h (char keys[8])");
    }
    std.debug.assert(@sizeOf(Code) == 16);
}

/// Mirrors `jd_code` in `include/jd.h`: one code a value is typed with.
pub const Code = extern struct {
    /// The keys, NUL-terminated.
    keys: [CODE_CAP]u8,
    /// The value's candidate index after typing exactly `keys`: 0 is what
    /// space commits, 1 what `;` commits. Counts the user phrases on the
    /// same code, which lead the built-in words.
    index: u32,
    /// `CodeFlag` bits.
    flags: u32,
};

/// Mirrors the `JD_CODE_*` flags.
pub const CodeFlag = struct {
    /// The code comes from the context's user dictionary, not the built-in
    /// tables.
    pub const user: u32 = 0x1;
};

const Hit = struct {
    keys: [MAX_KEYS_LEN]u8,
    len: u8,
    index: u32,
    flags: u32,

    fn slice(self: *const Hit) []const u8 {
        return self.keys[0..self.len];
    }

    fn toCode(self: *const Hit) Code {
        var out: Code = .{ .keys = @splat(0), .index = self.index, .flags = self.flags };
        @memcpy(out.keys[0..self.len], self.slice());
        return out;
    }
};

/// Candidate order between two codes: shorter first, then key by key in
/// `keyRank` order (a-z, then ';').
fn codeOrder(a: []const u8, b: []const u8) std.math.Order {
    if (a.len != b.len) return std.math.order(a.len, b.len);
    for (a, b) |x, y| {
        const o = std.math.order(trie_mod.keyRank(x), trie_mod.keyRank(y));
        if (o != .eq) return o;
    }
    return .eq;
}

const BuiltinHits = struct {
    trie: *const Trie,
    dict: ?*const UserDict,
    hits: []const u32,
    pos: usize = 0,
    last_node: ?u32 = null,

    fn next(self: *BuiltinHits) ?Hit {
        while (self.pos < self.hits.len) {
            const v = self.hits[self.pos];
            self.pos += 1;
            const node = self.trie.nodeOfValue(v);
            // The same value twice on one code is one code; the first is
            // the candidate a user reaches first. (Hits come in node order,
            // so repeats are adjacent.)
            if (self.last_node == node) continue;
            self.last_node = node;
            var hit: Hit = undefined;
            const keys = self.trie.codeOf(node, &hit.keys);
            hit.len = @intCast(keys.len);
            const ahead = if (self.dict) |d| d.countOn(keys) else 0;
            hit.index = ahead + (v - self.trie.nodes[node].values_start);
            hit.flags = 0;
            return hit;
        }
        return null;
    }
};

const UserHits = struct {
    dict: ?*const UserDict,
    value: []const u8,
    pos: u32 = 0,

    fn next(self: *UserHits) ?Hit {
        const d = self.dict orelse return null;
        const i = d.findValue(self.value, self.pos) orelse {
            self.pos = d.count();
            return null;
        };
        self.pos = i + 1;
        var hit: Hit = undefined;
        hit.len = @intCast(d.keysOf(i, &hit.keys).len);
        hit.index = d.indexOnCode(i);
        hit.flags = CodeFlag.user;
        return hit;
    }
};

/// Write the codes `value` is typed with into `out`, in candidate order —
/// shorter codes first, ties by key rank, a user phrase's code ahead of a
/// built-in word's on the same keys — and return how many there are in
/// all, which may exceed `out.len` (the excess is counted, not written).
/// `value` is compared byte for byte; an empty one has no codes.
pub fn codesOf(trie: *const Trie, dict: ?*const UserDict, value: []const u8, out: []Code) u32 {
    if (value.len == 0) return 0;
    var builtin: BuiltinHits = .{ .trie = trie, .dict = dict, .hits = trie.valuesEqualTo(value) };
    var user: UserHits = .{ .dict = dict, .value = value };
    var b = builtin.next();
    var u = user.next();
    var total: u32 = 0;
    while (true) {
        const hit = if (b) |*bh| blk: {
            if (u) |*uh| if (codeOrder(uh.slice(), bh.slice()) != .gt) {
                const h = uh.*;
                u = user.next();
                break :blk h;
            };
            const h = bh.*;
            b = builtin.next();
            break :blk h;
        } else if (u) |uh| blk: {
            u = user.next();
            break :blk uh;
        } else break;
        if (total < out.len) out[total] = hit.toCode();
        total += 1;
    }
    return total;
}

// =========================================================================
// Tests
// =========================================================================

const TEST_FP: u32 = 0x5EED_0003;

fn keysOf(code: *const Code) []const u8 {
    return std.mem.sliceTo(&code.keys, 0);
}

const Fixture = struct {
    th: trie_mod.TrieHandle,
    blob: ?user_dict.Blob,
    dict: ?UserDict,

    fn init(entries: []const trie_mod.Entry, phrases: ?[]const u8) !Fixture {
        var th = try trie_mod.buildTrie(testing.allocator, entries);
        errdefer th.deinit(testing.allocator);
        var blob: ?user_dict.Blob = null;
        var dict: ?UserDict = null;
        if (phrases) |text| {
            blob = try user_dict.buildAlloc(testing.allocator, text, &th.trie, TEST_FP, null);
            dict = try blob.?.dict(TEST_FP);
        }
        return .{ .th = th, .blob = blob, .dict = dict };
    }

    fn deinit(self: *Fixture) void {
        if (self.blob) |*b| b.deinit(testing.allocator);
        self.th.deinit(testing.allocator);
    }

    fn codes(self: *const Fixture, value: []const u8, out: []Code) u32 {
        const d: ?*const UserDict = if (self.dict) |*d| d else null;
        return codesOf(&self.th.trie, d, value, out);
    }
};

const base_entries = [_]trie_mod.Entry{
    .{ .keys = "zb", .value = "在" },
    .{ .keys = "z", .value = "这" },
    .{ .keys = "z", .value = "在" },
    .{ .keys = "zzzzzz", .value = "在" },
    .{ .keys = "ab", .value = "在" },
    .{ .keys = ";", .value = "；" },
    .{ .keys = ";;", .value = "在" },
};

test "built-in codes come back shortest first, with their candidate index" {
    var f = try Fixture.init(&base_entries, null);
    defer f.deinit();

    var out: [8]Code = undefined;
    try testing.expectEqual(@as(u32, 5), f.codes("在", &out));
    const want = [_]struct { []const u8, u32 }{
        .{ "z", 1 }, // after 这 on the same code
        .{ "ab", 0 },
        .{ "zb", 0 },
        .{ ";;", 0 }, // ';' ranks after the letters
        .{ "zzzzzz", 0 },
    };
    for (want, out[0..want.len]) |w, c| {
        try testing.expectEqualStrings(w[0], keysOf(&c));
        try testing.expectEqual(w[1], c.index);
        try testing.expectEqual(@as(u32, 0), c.flags);
    }
    // The inline keys are NUL-padded.
    try testing.expectEqualSlices(u8, &.{ 'z', 0, 0, 0, 0, 0, 0, 0 }, &out[0].keys);
}

test "a short buffer still gets the total, and only what fits is written" {
    var f = try Fixture.init(&base_entries, null);
    defer f.deinit();

    var out: [2]Code = undefined;
    out[1].index = 0xDEAD;
    try testing.expectEqual(@as(u32, 5), f.codes("在", out[0..1]));
    try testing.expectEqualStrings("z", keysOf(&out[0]));
    try testing.expectEqual(@as(u32, 0xDEAD), out[1].index);
    try testing.expectEqual(@as(u32, 5), f.codes("在", &.{}));
}

test "unknown, empty and partial values have no codes" {
    var f = try Fixture.init(&base_entries, "在这\tq\n");
    defer f.deinit();

    var out: [4]Code = undefined;
    try testing.expectEqual(@as(u32, 0), f.codes("", &out));
    try testing.expectEqual(@as(u32, 0), f.codes("不", &out));
    try testing.expectEqual(@as(u32, 0), f.codes("在这在", &out));
    // Byte for byte: a value is not trimmed.
    try testing.expectEqual(@as(u32, 0), f.codes(" 在", &out));
    try testing.expectEqual(@as(u32, 1), f.codes("这", &out));
}

test "user phrases merge in by code, ahead of the built-in words on theirs" {
    var f = try Fixture.init(&base_entries, "在\tzzzz\n" ++
        "在\tb\n" ++
        "别\tz\n" ++
        "在\tz\n" ++
        "在\tzb\n" ++
        "在\tab\n");
    defer f.deinit();
    // Lines 4-6 repeat built-in words on the same code and are dropped, so
    // they must not show up twice; 别 on `z` pushes 这 and 在 down by one.

    var out: [8]Code = undefined;
    try testing.expectEqual(@as(u32, 7), f.codes("在", &out));
    const want = [_]struct { []const u8, u32, u32 }{
        .{ "b", 0, CodeFlag.user },
        .{ "z", 2, 0 },
        .{ "ab", 0, 0 },
        .{ "zb", 0, 0 },
        .{ ";;", 0, 0 },
        .{ "zzzz", 0, CodeFlag.user },
        .{ "zzzzzz", 0, 0 },
    };
    for (want, out[0..want.len]) |w, c| {
        try testing.expectEqualStrings(w[0], keysOf(&c));
        try testing.expectEqual(w[1], c.index);
        try testing.expectEqual(w[2], c.flags);
    }

    try testing.expectEqual(@as(u32, 1), f.codes("别", &out));
    try testing.expectEqualStrings("z", keysOf(&out[0]));
    try testing.expectEqual(@as(u32, 0), out[0].index);
    try testing.expectEqual(CodeFlag.user, out[0].flags);
}

test "user phrases on one code are indexed in file order" {
    var f = try Fixture.init(&base_entries, "甲\tqq\n" ++
        "乙\tqq\n" ++
        "乙\tqqq\n" ++
        "丙\tqq\n");
    defer f.deinit();

    var out: [4]Code = undefined;
    try testing.expectEqual(@as(u32, 2), f.codes("乙", &out));
    try testing.expectEqualStrings("qq", keysOf(&out[0]));
    try testing.expectEqual(@as(u32, 1), out[0].index);
    try testing.expectEqualStrings("qqq", keysOf(&out[1]));
    try testing.expectEqual(@as(u32, 0), out[1].index);
    try testing.expectEqual(@as(u32, 1), f.codes("丙", &out));
    try testing.expectEqual(@as(u32, 2), out[0].index);
}

test "a value repeated on one code is reported once, at its first index" {
    // A dictionary build drops the repeat (`dict.build`), so the second 甲
    // on "a" never reaches the trie: one hit on "a", at index 0.
    var f = try Fixture.init(&.{
        .{ .keys = "a", .value = "甲" },
        .{ .keys = "a", .value = "乙" },
        .{ .keys = "b", .value = "甲" },
    }, null);
    defer f.deinit();
    try testing.expectError(error.RepeatedEntry, trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "甲" },
        .{ .keys = "a", .value = "甲" },
    }));

    var out: [4]Code = undefined;
    try testing.expectEqual(@as(u32, 2), f.codes("甲", &out));
    try testing.expectEqualStrings("a", keysOf(&out[0]));
    try testing.expectEqual(@as(u32, 0), out[0].index);
    try testing.expectEqualStrings("b", keysOf(&out[1]));
}
