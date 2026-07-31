//! Flat-index candidate enumeration.
//!
//! Candidates reachable from a trie node (or from a punctuation entry) form
//! a stable, deterministic sequence. This module exposes that sequence by
//! **flat index** — `readRange(start, count, out)` — with no notion of a
//! page. Paging is a frontend concern: a desktop IME asks for
//! `[(n-1)*9, n*9)`, a mobile candidate strip asks for `[fetched, fetched+9)`.
//!
//! Design: the enumeration cursor is a single forward-only BFS walk
//! (shorter completions first, ties broken by `keyRank`). It is *purely
//! internal* — moving it has no observable effect, because every option is
//! written into caller memory and `QueryOption` holds nothing that can
//! dangle (`value` points into the embedded blob; `hint` is inline bytes).
//! Reading forward is amortized O(1) per option; reading backward rewinds
//! and replays, O(start + count).
//!
//! Critically, the cursor is NOT the commit anchor. `query.zig` keeps a
//! separate `anchor_index` for that, so a frontend can enumerate far ahead
//! without changing what space / `;` commit.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const trie_mod = @import("trie");
const Trie = trie_mod.Trie;
const Node = trie_mod.Trie.Node;
const buildTestTrie = @import("./trie_test_data.zig").buildTestTrie;
const punc_fmt = @import("punc_format");
const punc_mod = @import("./punc.zig");

/// Inline hint capacity, including the NUL terminator. A hint is the key
/// sequence remaining below the queried start node, so it is bounded by
/// `MAX_KEYS_LEN - 1` (the start node is never the root — see
/// `NodePagination.init` callers in query.zig). 8 leaves headroom and keeps
/// `QueryOption` 8-byte aligned on 64-bit.
pub const HINT_CAP: usize = 8;

comptime {
    // `jd.h` hard-codes `char hint[8]`. Keep the domain invariant inside
    // it as a hard compile error — `std.debug.assert` compiles to nothing
    // in ReleaseFast, and an overflowing hint would silently truncate.
    if (trie_mod.MAX_KEYS_LEN > HINT_CAP) {
        @compileError("MAX_KEYS_LEN outgrew the inline hint capacity declared in jd.h (char hint[8])");
    }
}

/// One candidate. Both fields are safe to retain indefinitely: `value`
/// always points into an embedded blob (rodata, immortal for the process),
/// and `hint` is inline bytes owned by whoever owns this struct. There is
/// no invalidation rule.
pub const QueryOption = extern struct {
    value: [*:0]const u8,
    /// NUL-terminated; `hint[0] == 0` means "no hint".
    hint: [HINT_CAP]u8,

    pub fn hintSlice(self: *const QueryOption) ?[]const u8 {
        if (self.hint[0] == 0) return null;
        return std.mem.sliceTo(&self.hint, 0);
    }

    pub fn setHint(self: *QueryOption, bytes: []const u8) void {
        std.debug.assert(bytes.len < HINT_CAP);
        @memcpy(self.hint[0..bytes.len], bytes);
        @memset(self.hint[bytes.len..], 0);
    }

    pub fn clearHint(self: *QueryOption) void {
        @memset(&self.hint, 0);
    }
};

/// Test-only instrumentation: counts consumed values so a test can prove a
/// forward scan touches each candidate exactly once (i.e. that the cursor
/// never replays). Folded away in non-test builds.
pub var consume_calls: usize = 0;

/// One entry in the BFS frontier. `path_start`/`path_len` index into the
/// shared `path_buf`, giving the key sequence from the queried start node
/// down to this entry's node. Hints are materialized from this path when a
/// value is emitted.
pub const FrontierEntry = struct {
    node: *const Node,
    path_start: u32,
    path_len: u8,
};

/// Pre-allocated buffers a `NodePagination` borrows. The caller owns the
/// memory and keeps it valid for the paginator's lifetime. Sizes come from
/// `Trie.frontier_cap` / `Trie.path_buf_cap`; in production they are carved
/// by `jd_init`.
pub const Buffers = struct {
    frontier: []FrontierEntry,
    path_buf: []u8,
};

pub const NodePagination = struct {
    const Self = @This();

    trie: *const Trie,
    start_node: *const Node,

    /// BFS cursor. `cursor_index` is the flat index of the next value to be
    /// emitted; together with (frontier, frontier_head, skipped) it fully
    /// identifies the cursor position.
    cursor_index: u32,
    frontier: []FrontierEntry,
    frontier_len: usize,
    frontier_head: usize,
    path_buf: []u8,
    path_buf_len: usize,
    skipped: u8,

    pub fn init(buffers: Buffers, trie: *const Trie, node: *const Node) Self {
        buffers.frontier[0] = .{ .node = node, .path_start = 0, .path_len = 0 };
        return .{
            .trie = trie,
            .start_node = node,
            .cursor_index = 0,
            .frontier = buffers.frontier,
            .frontier_len = 1,
            .frontier_head = 0,
            .path_buf = buffers.path_buf,
            .path_buf_len = 0,
            .skipped = 0,
        };
    }

    pub fn totalOptions(self: *const Self) u32 {
        return self.start_node.count();
    }

    fn rewind(self: *Self) void {
        self.frontier[0] = .{ .node = self.start_node, .path_start = 0, .path_len = 0 };
        self.frontier_len = 1;
        self.path_buf_len = 0;
        self.frontier_head = 0;
        self.skipped = 0;
        self.cursor_index = 0;
    }

    /// Write the options at flat indices `[start, start + count)` into
    /// `out`, clipped by `out.len` and by the total option count. Returns
    /// how many were written.
    pub fn readRange(self: *Self, start: u32, count: u32, out: []QueryOption) u32 {
        const total = self.totalOptions();
        if (start >= total) return 0;
        const cap: u32 = @intCast(@min(out.len, @as(usize, std.math.maxInt(u32))));
        const want = @min(@min(count, total - start), cap);
        if (want == 0) return 0;

        if (start < self.cursor_index) self.rewind();
        while (self.cursor_index < start) self.consumeOne(null);

        var i: u32 = 0;
        while (i < want) : (i += 1) self.consumeOne(&out[i]);
        return want;
    }

    /// Consume the value at the cursor, writing it to `out` when non-null.
    fn consumeOne(self: *Self, out: ?*QueryOption) void {
        if (builtin.is_test) consume_calls += 1;
        while (true) {
            const entry = self.frontier[self.frontier_head];
            const values = entry.node.values(self.trie);

            if (self.skipped == 0) {
                self.enqueueChildren(entry);
                if (values.len() == 0) {
                    self.frontier_head += 1;
                    continue;
                }
            }

            if (out) |o| {
                o.value = values.at(self.skipped).ptr;
                if (entry.path_len == 0) {
                    o.clearHint();
                } else {
                    o.setHint(self.path_buf[entry.path_start..][0..entry.path_len]);
                }
            }

            self.skipped += 1;
            if (self.skipped == values.len()) {
                self.frontier_head += 1;
                self.skipped = 0;
            }
            self.cursor_index += 1;
            return;
        }
    }

    fn enqueueChildren(self: *Self, entry: FrontierEntry) void {
        const w = entry.node.getWidth();
        if (w == 0) return;
        for (0..w) |i| {
            const child = entry.node.getChildByIndex(self.trie, i).?;
            const key = entry.node.keyOfChildByIndex(self.trie, i).?;
            const child_path_start: u32 = @intCast(self.path_buf_len);
            const parent_path = self.path_buf[entry.path_start..][0..entry.path_len];
            @memcpy(self.path_buf[self.path_buf_len..][0..entry.path_len], parent_path);
            self.path_buf_len += entry.path_len;
            self.path_buf[self.path_buf_len] = key;
            self.path_buf_len += 1;
            self.frontier[self.frontier_len] = .{
                .node = child,
                .path_start = child_path_start,
                .path_len = entry.path_len + 1,
            };
            self.frontier_len += 1;
        }
    }
};

/// Enumeration over a single normal-table entry's punctuation candidates.
///
/// Much simpler than `NodePagination`: candidates sit as NUL-separated
/// strings in a flat pool and the count is known up front, so there is no
/// cursor to maintain — every read is random-access via
/// `Punc.candidateAt`. Paired punctuation is NOT handled here (it's a
/// single-press commit, inline in `query.zig` case C); this serves only
/// multi-candidate normal lookups (case D — `[` → `「`/`【`/`〔`/`［`).
pub const PuncPagination = struct {
    const Self = @This();

    entry: *const punc_fmt.NormalEntry,
    punc: *const punc_mod.Punc,

    pub fn init(entry: *const punc_fmt.NormalEntry, punc: *const punc_mod.Punc) Self {
        std.debug.assert(entry.candidates_count > 0);
        return .{ .entry = entry, .punc = punc };
    }

    pub fn totalOptions(self: *const Self) u32 {
        return @as(u32, self.entry.candidates_count);
    }

    pub fn readRange(self: *Self, start: u32, count: u32, out: []QueryOption) u32 {
        const total = self.totalOptions();
        if (start >= total) return 0;
        const cap: u32 = @intCast(@min(out.len, @as(usize, std.math.maxInt(u32))));
        const want = @min(@min(count, total - start), cap);

        var i: u32 = 0;
        while (i < want) : (i += 1) {
            out[i].value = self.punc.candidateAt(self.entry, start + i);
            out[i].clearHint();
        }
        return want;
    }
};

/// Tagged-union enumerator — lets a `Context` be in either a trie
/// composition or a punctuation candidate window without duplicating the
/// branching across every read.
pub const Pager = union(enum) {
    trie: NodePagination,
    punc: PuncPagination,

    pub fn totalOptions(self: *const Pager) u32 {
        return switch (self.*) {
            .trie => |*p| p.totalOptions(),
            .punc => |*p| p.totalOptions(),
        };
    }

    pub fn readRange(self: *Pager, start: u32, count: u32, out: []QueryOption) u32 {
        return switch (self.*) {
            .trie => |*p| p.readRange(start, count, out),
            .punc => |*p| p.readRange(start, count, out),
        };
    }

    /// Read exactly one option by flat index. Returns null when the index
    /// is out of range.
    pub fn optionAt(self: *Pager, index: u32) ?QueryOption {
        var buf: [1]QueryOption = undefined;
        if (self.readRange(index, 1, &buf) == 0) return null;
        return buf[0];
    }
};

// =========================================================================
// Test helpers
// =========================================================================

/// Test-side expectation, written with plain slices.
pub const ExpectedOption = struct {
    value: []const u8,
    hint: ?[]const u8 = null,
};

pub fn expectEqualOption(expected: ExpectedOption, actual: QueryOption) !void {
    try testing.expectEqualStrings(expected.value, std.mem.sliceTo(actual.value, 0));
    if (expected.hint) |want| {
        const got = actual.hintSlice() orelse {
            std.debug.print("expected hint \"{s}\" but the option has none\n", .{want});
            return error.TestExpectedEqual;
        };
        try testing.expectEqualStrings(want, got);
    } else if (actual.hintSlice()) |got| {
        std.debug.print("expected no hint but got \"{s}\"\n", .{got});
        return error.TestExpectedEqual;
    }
}

pub fn expectEqualOptions(expected: []const ExpectedOption, actual: []const QueryOption) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |e, a, i| {
        expectEqualOption(e, a) catch |err| {
            std.debug.print("option {d} differs\n", .{i});
            return err;
        };
    }
}

// =========================================================================
// Tests
// =========================================================================

/// Wraps the two heap regions a `NodePagination` borrows. In production
/// this work is done by `jd_init`.
const TestHarness = struct {
    frontier: []FrontierEntry,
    path_buf: []u8,

    fn init(allocator: std.mem.Allocator, trie: *const Trie) !TestHarness {
        // `+1` so tests that enumerate from the root (whose subtree is one
        // node larger than any non-root node's) still fit.
        const frontier = try allocator.alloc(FrontierEntry, trie.frontier_cap + 1);
        errdefer allocator.free(frontier);
        const path_buf = try allocator.alloc(u8, trie.path_buf_cap + 1);
        return .{ .frontier = frontier, .path_buf = path_buf };
    }

    fn deinit(self: *TestHarness, allocator: std.mem.Allocator) void {
        allocator.free(self.frontier);
        allocator.free(self.path_buf);
    }

    fn buffers(self: *TestHarness) Buffers {
        return .{ .frontier = self.frontier, .path_buf = self.path_buf };
    }
};

/// The full flat enumeration of node "a" in the shared test trie: BFS
/// order, shorter completions first, ties by `keyRank`.
const expected_a = [_]ExpectedOption{
    .{ .value = "甲" },
    .{ .value = "乙", .hint = "b" },
    .{ .value = "丙1", .hint = "c" },
    .{ .value = "丙2", .hint = "c" },
    .{ .value = "Foo", .hint = "e" },
    .{ .value = "Bar", .hint = "f" },
    .{ .value = "丁1", .hint = "cd" },
    .{ .value = "丁2", .hint = "cd" },
    .{ .value = "丁3", .hint = "cd" },
    .{ .value = "丁4", .hint = "ce" },
    .{ .value = "FooBar", .hint = "c;" },
};

test "totalOptions counts the whole subtree" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var p = NodePagination.init(harness.buffers(), &th.trie, node);
    try testing.expectEqual(@as(u32, 11), p.totalOptions());
}

test "readRange from 0 yields the full BFS order" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var p = NodePagination.init(harness.buffers(), &th.trie, node);

    var out: [16]QueryOption = undefined;
    const n = p.readRange(0, 16, &out);
    try testing.expectEqual(@as(u32, 11), n);
    try expectEqualOptions(&expected_a, out[0..n]);
}

test "readRange reads an arbitrary window" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var p = NodePagination.init(harness.buffers(), &th.trie, node);

    var out: [3]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 3), p.readRange(3, 3, &out));
    try expectEqualOptions(expected_a[3..6], out[0..3]);
}

test "sequential forward reads never replay" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var p = NodePagination.init(harness.buffers(), &th.trie, node);

    // Walk the whole list in windows of 3, exactly as a candidate strip
    // would. The cursor must consume each option once and only once.
    consume_calls = 0;
    var out: [3]QueryOption = undefined;
    var start: u32 = 0;
    var seen: usize = 0;
    while (true) {
        const n = p.readRange(start, 3, &out);
        if (n == 0) break;
        try expectEqualOptions(expected_a[start..][0..n], out[0..n]);
        seen += n;
        start += n;
    }
    try testing.expectEqual(@as(usize, 11), seen);
    try testing.expectEqual(@as(usize, 11), consume_calls);
}

test "backward reads rewind and replay correctly" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var p = NodePagination.init(harness.buffers(), &th.trie, node);

    var out: [4]QueryOption = undefined;

    // Jump deep, then walk back to the front and out again.
    try testing.expectEqual(@as(u32, 2), p.readRange(9, 4, &out));
    try expectEqualOptions(expected_a[9..11], out[0..2]);

    try testing.expectEqual(@as(u32, 4), p.readRange(0, 4, &out));
    try expectEqualOptions(expected_a[0..4], out[0..4]);

    try testing.expectEqual(@as(u32, 4), p.readRange(6, 4, &out));
    try expectEqualOptions(expected_a[6..10], out[0..4]);

    try testing.expectEqual(@as(u32, 1), p.readRange(1, 1, &out));
    try expectEqualOptions(expected_a[1..2], out[0..1]);
}

test "readRange clips to out_cap and to the total" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var p = NodePagination.init(harness.buffers(), &th.trie, node);

    // out_cap is the binding constraint: asked for 9, buffer holds 2.
    var small: [2]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 2), p.readRange(0, 9, &small));
    try expectEqualOptions(expected_a[0..2], small[0..2]);

    // The total is the binding constraint: only 2 options remain from 9.
    var big: [16]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 2), p.readRange(9, 16, &big));

    // Fully out of range, and a zero-width request.
    try testing.expectEqual(@as(u32, 0), p.readRange(11, 4, &big));
    try testing.expectEqual(@as(u32, 0), p.readRange(999, 4, &big));
    try testing.expectEqual(@as(u32, 0), p.readRange(0, 0, &big));
}

test "single-option node has no hint" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "甲" },
    });
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var p = NodePagination.init(harness.buffers(), &th.trie, node);

    var out: [1]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 1), p.readRange(0, 1, &out));
    try testing.expectEqual(@as(u8, 0), out[0].hint[0]);
    try testing.expect(out[0].hintSlice() == null);
}

test "hints are inline and NUL-terminated at max depth" {
    // Longest possible hint: a 6-key entry read from its depth-1 node
    // leaves 5 hint bytes — the bound `HINT_CAP` is sized against.
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "abcdef", .value = "X" },
    });
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var p = NodePagination.init(harness.buffers(), &th.trie, node);

    var out: [1]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 1), p.readRange(0, 1, &out));
    try expectEqualOption(.{ .value = "X", .hint = "bcdef" }, out[0]);
    try testing.expectEqual(@as(u8, 0), out[0].hint[5]);
}

test "deep nodes enumerate breadth-first" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "甲" },
        .{ .keys = "ab", .value = "乙" },
        .{ .keys = "ac", .value = "丙" },
        .{ .keys = "ad", .value = "丁" },
        .{ .keys = "ae", .value = "Foo" },
        .{ .keys = "afj", .value = "Bar" },
        .{ .keys = "abcde", .value = "Hello" },
        .{ .keys = "asdfgh", .value = "World" },
    });
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var p = NodePagination.init(harness.buffers(), &th.trie, node);

    var out: [8]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 8), p.readRange(0, 8, &out));
    try expectEqualOptions(&.{
        .{ .value = "甲" },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙", .hint = "c" },
        .{ .value = "丁", .hint = "d" },
        .{ .value = "Foo", .hint = "e" },
        .{ .value = "Bar", .hint = "fj" },
        .{ .value = "Hello", .hint = "bcde" },
        .{ .value = "World", .hint = "sdfgh" },
    }, out[0..8]);
}

// =========================================================================
// Tests — PuncPagination
// =========================================================================

test "PuncPagination reads the whole candidate list in source order" {
    const candidates = [_][]const u8{ "「", "【", "〔", "［" };
    var ph = try punc_mod.buildPunc(testing.allocator, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer ph.deinit(testing.allocator);

    const entry = ph.punc.lookupNormal('[') orelse return error.TestUnexpectedNull;
    var p = PuncPagination.init(entry, &ph.punc);

    try testing.expectEqual(@as(u32, 4), p.totalOptions());
    var out: [4]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 4), p.readRange(0, 4, &out));
    try expectEqualOptions(&.{
        .{ .value = "「" },
        .{ .value = "【" },
        .{ .value = "〔" },
        .{ .value = "［" },
    }, out[0..4]);
}

test "PuncPagination reads a window and clips at the end" {
    const candidates = [_][]const u8{ "「", "【", "〔" };
    var ph = try punc_mod.buildPunc(testing.allocator, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer ph.deinit(testing.allocator);

    const entry = ph.punc.lookupNormal('[') orelse return error.TestUnexpectedNull;
    var p = PuncPagination.init(entry, &ph.punc);

    var out: [4]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 2), p.readRange(1, 4, &out));
    try expectEqualOptions(&.{ .{ .value = "【" }, .{ .value = "〔" } }, out[0..2]);
    try testing.expectEqual(@as(u32, 0), p.readRange(3, 4, &out));
}

test "PuncPagination candidates never carry hints" {
    const candidates = [_][]const u8{ "。", "，" };
    var ph = try punc_mod.buildPunc(testing.allocator, &.{
        .{ .key = '.', .candidates = &candidates },
    }, &.{});
    defer ph.deinit(testing.allocator);

    const entry = ph.punc.lookupNormal('.') orelse return error.TestUnexpectedNull;
    var p = PuncPagination.init(entry, &ph.punc);

    var out: [2]QueryOption = undefined;
    _ = p.readRange(0, 2, &out);
    try testing.expect(out[0].hintSlice() == null);
    try testing.expect(out[1].hintSlice() == null);
}

test "Pager.optionAt bounds-checks both variants" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try TestHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;
    var trie_pager: Pager = .{ .trie = NodePagination.init(harness.buffers(), &th.trie, node) };
    try testing.expectEqualStrings("甲", std.mem.sliceTo(trie_pager.optionAt(0).?.value, 0));
    try testing.expectEqualStrings("FooBar", std.mem.sliceTo(trie_pager.optionAt(10).?.value, 0));
    try testing.expect(trie_pager.optionAt(11) == null);

    const candidates = [_][]const u8{ "「", "【" };
    var ph = try punc_mod.buildPunc(testing.allocator, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer ph.deinit(testing.allocator);
    const entry = ph.punc.lookupNormal('[') orelse return error.TestUnexpectedNull;
    var punc_pager: Pager = .{ .punc = PuncPagination.init(entry, &ph.punc) };
    try testing.expectEqualStrings("【", std.mem.sliceTo(punc_pager.optionAt(1).?.value, 0));
    try testing.expect(punc_pager.optionAt(2) == null);
}
