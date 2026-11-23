//! Trie API, paired with `blob_format.zig`.
//!
//! A dictionary blob — the embedded one, generated at build time by
//! `scripts/gen_trie.zig`, or one a host built at runtime — is
//! reinterpreted in place with `Trie.fromBytes`, and the resulting `Node`s
//! are walked via `getChild`/`values()`/etc. The builder and the check
//! that makes a host's blob safe to view live in `dict.zig`.

const std = @import("std");
const testing = std.testing;
const fmt = @import("./blob_format.zig");
pub const dict = @import("./dict.zig");

/// The blob's header, for the generator's log line.
pub const Header = fmt.Header;

const ALPHA: usize = 27;

/// Domain invariant: the longest key sequence a dictionary entry may have.
/// `Context.pressed_keys` in query.zig is sized to exactly this, so
/// `buildBlob` rejects longer entries as a hard error (it runs in the
/// generator's `fast` build, where `std.debug.assert` would vanish).
pub const MAX_KEYS_LEN: usize = 6;

/// Position of a key byte in the alphabet: a-z → 0-25, ';' → 26, anything
/// else → 27 (= ALPHA, "not a key"). The order children are stored in, and
/// the byte encoding `user_dict.zig` keeps keys in so a plain byte compare
/// is this order.
pub fn keyRank(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 'a';
    if (c == ';') return 26;
    return 27;
}

/// Inverse of `keyRank` for ranks below ALPHA.
pub fn keyOfRank(rank: u8) u8 {
    std.debug.assert(rank < ALPHA);
    return if (rank == 26) ';' else 'a' + rank;
}

/// The exact key alphabet: a-z plus ';' (the ALPHA = 27 ranks above).
/// Everything downstream assumes it — keyRank ordering, `buildBlob`'s
/// fixed-size insertion buffers, the packed u8 width field — so `buildBlob`
/// hard-errors on anything else. Exposed for the generator's parser, which
/// rejects bad bytes with file/line context before they reach the builder.
pub fn isValidKeyByte(c: u8) bool {
    return keyRank(c) < ALPHA;
}

/// One input row: key string + value string. The value will be null-terminated
/// in the on-disk strings pool so `Values.at(i)` can hand out `[:0]const u8`.
pub const Entry = struct {
    keys: []const u8,
    value: []const u8,
};

/// Runtime view over a dictionary blob. Construct with `fromBytes` for a
/// blob known to be good (the embedded one), or `dict.open` for any other.
pub const Trie = struct {
    nodes: []const fmt.Node,
    values: []const fmt.Value,
    /// Every value index, sorted by the value's bytes, then by index.
    by_value: []const u32,
    /// Key of node `k + 1` (see `fmt.Header` — nodes are numbered
    /// breadth-first, so child slot `k` is node `k + 1`).
    child_keys: []const u8,
    strings: []const u8,

    /// Worst-case BFS frontier entry count across any non-root start node.
    frontier_cap: u32,
    /// Worst-case BFS path-buffer byte count across any non-root start node.
    path_buf_cap: u32,
    /// Longest value string in bytes (excluding the NUL terminator).
    max_value_len: u32,
    /// Names the dictionary's contents (see `fmt.Header`).
    fingerprint: u64,
    /// The host's tag from the build.
    source_tag: u64,

    pub const Node = NodeView;

    /// View a blob built by `dict.build`. O(1) — a header read and slice
    /// header construction — and it trusts the blob: only the sizes are
    /// checked. `dict.open` checks everything first.
    pub fn fromBytes(bytes: []align(4) const u8) !Trie {
        if (bytes.len < @sizeOf(fmt.Header)) return error.BlobTooSmall;
        const h: *const fmt.Header = @ptrCast(@alignCast(bytes.ptr));
        if (h.node_count == 0) return error.BlobTooSmall;
        if (bytes.len < fmt.blobSize(h.node_count, h.values_count, h.strings_total)) return error.BlobTooSmall;

        const offsets = fmt.PoolOffsets.compute(h.node_count, h.values_count);
        const nodes_bytes = bytes[offsets.nodes..][0 .. h.node_count * @sizeOf(fmt.Node)];
        const values_bytes = bytes[offsets.values..][0 .. h.values_count * @sizeOf(fmt.Value)];
        const by_value_bytes = bytes[offsets.by_value..][0 .. h.values_count * @sizeOf(u32)];

        return .{
            .nodes = std.mem.bytesAsSlice(fmt.Node, @as([]align(4) const u8, @alignCast(nodes_bytes))),
            .values = std.mem.bytesAsSlice(fmt.Value, @as([]align(4) const u8, @alignCast(values_bytes))),
            .by_value = std.mem.bytesAsSlice(u32, @as([]align(4) const u8, @alignCast(by_value_bytes))),
            .child_keys = bytes[offsets.child_keys..][0..fmt.childKeysTotal(h.node_count)],
            .strings = bytes[offsets.strings..][0..h.strings_total],
            .frontier_cap = h.frontier_cap,
            .path_buf_cap = h.path_buf_cap,
            .max_value_len = h.max_value_len,
            .fingerprint = h.fingerprint(),
            .source_tag = h.sourceTag(),
        };
    }

    pub fn root(self: *const Trie) *const Node {
        return self.nodeAt(0);
    }

    pub inline fn nodeAt(self: *const Trie, index: u32) *const Node {
        return @ptrCast(&self.nodes[index]);
    }

    /// The node's index — its position in breadth-first order.
    pub inline fn indexOf(self: *const Trie, node: *const Node) u32 {
        return @intCast(@as([*]const fmt.Node, @ptrCast(node)) - self.nodes.ptr);
    }

    /// The node that holds value `value_index`: the last node whose values
    /// start at or before it. `values_start` never decreases in node order
    /// and every later node starts past this value, so that node owns it.
    pub fn nodeOfValue(self: *const Trie, value_index: u32) u32 {
        return lastAtOrBefore(self.nodes, value_index, valuesStartOf);
    }

    /// The parent of node `index` (not the root): the node whose child
    /// slots hold slot `index - 1`, found the same way as `nodeOfValue`.
    pub fn parentOf(self: *const Trie, index: u32) u32 {
        std.debug.assert(index != 0);
        return lastAtOrBefore(self.nodes, index - 1, childrenStartOf);
    }

    /// The key sequence that reaches node `index`, written into `buf`.
    /// At most `MAX_KEYS_LEN` parent steps.
    pub fn codeOf(self: *const Trie, index: u32, buf: *[MAX_KEYS_LEN]u8) []const u8 {
        var n = index;
        var at: usize = MAX_KEYS_LEN;
        while (n != 0) : (n = self.parentOf(n)) {
            at -= 1;
            buf[at] = self.child_keys[n - 1];
        }
        const len = MAX_KEYS_LEN - at;
        std.mem.copyForwards(u8, buf[0..len], buf[at..]);
        return buf[0..len];
    }

    /// The indices of every value whose bytes are exactly `value`,
    /// ascending — which is node order, so the codes they sit on come out
    /// shortest first, ties by key rank. One binary search.
    pub fn valuesEqualTo(self: *const Trie, value: []const u8) []const u32 {
        const lo, const hi = std.sort.equalRange(u32, self.by_value, ValueKey{ .trie = self, .value = value }, ValueKey.cmp);
        return self.by_value[lo..hi];
    }

    /// `by_value`'s order: a value's bytes, then its index.
    const ValueKey = struct {
        trie: *const Trie,
        value: []const u8,

        fn cmp(key: ValueKey, item: u32) std.math.Order {
            return std.mem.order(u8, key.value, key.trie.values[item].bytes(key.trie.strings));
        }
    };

    fn valuesStartOf(n: fmt.Node) u32 {
        return n.values_start;
    }

    fn childrenStartOf(n: fmt.Node) u32 {
        return n.children_start;
    }

    /// Index of the last node whose `field` is ≤ `target`. `field` must be
    /// non-decreasing in node order and node 0's must be 0.
    fn lastAtOrBefore(nodes: []const fmt.Node, target: u32, comptime field: fn (fmt.Node) u32) u32 {
        var lo: usize = 0; // invariant: field(nodes[lo]) <= target
        var hi: usize = nodes.len; // invariant: everything at or past hi is > target
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (field(nodes[mid]) <= target) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// Wrapper that gives us `count`/`width`/getChild/values/etc. methods on
    /// the raw `fmt.Node`. Identical layout — `@ptrCast` is free.
    ///
    /// Methods that need to follow child indices take the owning `*const Trie`
    /// explicitly. Stashing it on every node would cost an extra pointer per
    /// node (~1 MB at 140K nodes) for no benefit. Threading it through
    /// matches the existing query/pagination state shape (they already carry
    /// a root pointer).
    pub const NodeView = extern struct {
        inner: fmt.Node,

        pub inline fn count(self: *const NodeView) u32 {
            return self.inner.count();
        }

        pub inline fn getWidth(self: *const NodeView) u8 {
            return self.inner.width();
        }

        pub fn values(self: *const NodeView, trie: *const Trie) Values {
            const start = self.inner.values_start;
            const end = start + self.inner.values_len;
            return .{ .slice = trie.values[start..end], .strings = trie.strings };
        }

        pub fn getChild(self: *const NodeView, trie: *const Trie, key: u8) ?*const NodeView {
            return self.getChildByIndex(trie, self.indexOfChild(trie, key) orelse return null);
        }

        pub fn getChildByIndex(self: *const NodeView, trie: *const Trie, index: usize) ?*const NodeView {
            if (index >= self.inner.width()) return null;
            return trie.nodeAt(self.inner.children_start + @as(u32, @intCast(index)) + 1);
        }

        pub fn indexOfChild(self: *const NodeView, trie: *const Trie, key: u8) ?usize {
            const keys = trie.child_keys[self.inner.children_start..][0..self.inner.width()];
            return std.mem.findScalar(u8, keys, key);
        }

        pub fn keyOfChildByIndex(self: *const NodeView, trie: *const Trie, index: usize) ?u8 {
            if (index >= self.inner.width()) return null;
            return trie.child_keys[self.inner.children_start + index];
        }
    };

    /// Iterator over a node's values. Materializes each `[:0]const u8` on
    /// demand against the shared strings pool.
    pub const Values = struct {
        slice: []const fmt.Value,
        strings: []const u8,

        pub inline fn len(self: Values) usize {
            return self.slice.len;
        }

        pub fn at(self: Values, i: usize) [:0]const u8 {
            return self.slice[i].bytes(self.strings);
        }
    };
};

// =========================================================================
// Building from entries — for tests and anything else that has entries in
// hand rather than text. The builder itself is `dict.build`.
// =========================================================================

/// A built blob and the view over it. Caller owns `.bytes` and must call
/// `deinit`.
pub const TrieHandle = struct {
    bytes: []align(4) u8,
    trie: Trie,

    pub fn deinit(self: *TrieHandle, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

/// Build a dictionary from `entries` — written out as `value<TAB>keys`
/// lines and built with `dict.build`, so every rule of a dictionary
/// applies. An entry the build would skip or drop is an error here.
pub fn buildTrie(allocator: std.mem.Allocator, entries: []const Entry) !TrieHandle {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    for (entries) |e| {
        try text.appendSlice(allocator, e.value);
        try text.append(allocator, '\t');
        try text.appendSlice(allocator, e.keys);
        try text.append(allocator, '\n');
    }
    var blob = try dict.buildAlloc(allocator, text.items, 0, null);
    errdefer blob.deinit(allocator);
    if (blob.report.invalid != 0) return error.InvalidEntry;
    if (blob.report.dropped != 0) return error.RepeatedEntry;
    return .{ .bytes = blob.buf, .trie = try dict.open(blob.bytes()) };
}

// =========================================================================
// Tests
// =========================================================================

test {
    _ = dict;
}

test "single-letter keys" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "n", .value = "你" },
        .{ .keys = "i", .value = "上" },
    });
    defer th.deinit(testing.allocator);
    const root = th.trie.root();
    try testing.expectEqualStrings("你", root.getChild(&th.trie, 'n').?.values(&th.trie).at(0));
    try testing.expectEqualStrings("上", root.getChild(&th.trie, 'i').?.values(&th.trie).at(0));
}

test "multi-letter keys" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "nkiuai", .value = "你" },
        .{ .keys = "hzauai", .value = "好" },
    });
    defer th.deinit(testing.allocator);
    const root = th.trie.root();
    const n_path = root.getChild(&th.trie, 'n').?.getChild(&th.trie, 'k').?.getChild(&th.trie, 'i').?.getChild(&th.trie, 'u').?.getChild(&th.trie, 'a').?.getChild(&th.trie, 'i').?;
    try testing.expectEqualStrings("你", n_path.values(&th.trie).at(0));
    const h_path = root.getChild(&th.trie, 'h').?.getChild(&th.trie, 'z').?.getChild(&th.trie, 'a').?.getChild(&th.trie, 'u').?.getChild(&th.trie, 'a').?.getChild(&th.trie, 'i').?;
    try testing.expectEqualStrings("好", h_path.values(&th.trie).at(0));
}

test "same key multiple values, order preserved" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "i", .value = "上" },
        .{ .keys = "i", .value = "打" },
        .{ .keys = "i", .value = "龵" },
    });
    defer th.deinit(testing.allocator);
    const i = th.trie.root().getChild(&th.trie, 'i').?;
    const vs = i.values(&th.trie);
    try testing.expectEqual(@as(usize, 3), vs.len());
    try testing.expectEqualStrings("上", vs.at(0));
    try testing.expectEqualStrings("打", vs.at(1));
    try testing.expectEqualStrings("龵", vs.at(2));
}

test "subtree counts" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "nk", .value = "你" },
        .{ .keys = "nkhz", .value = "你好" },
        .{ .keys = "i", .value = "上" },
    });
    defer th.deinit(testing.allocator);
    const t = &th.trie;
    const root = t.root();
    try testing.expectEqual(@as(u32, 3), root.count());
    try testing.expectEqual(@as(u32, 2), root.getChild(t, 'n').?.count());
    try testing.expectEqual(@as(u32, 2), root.getChild(t, 'n').?.getChild(t, 'k').?.count());
    try testing.expectEqual(@as(u32, 1), root.getChild(t, 'n').?.getChild(t, 'k').?.getChild(t, 'h').?.count());
    try testing.expectEqual(@as(u32, 1), root.getChild(t, 'n').?.getChild(t, 'k').?.getChild(t, 'h').?.getChild(t, 'z').?.count());
    try testing.expectEqual(@as(u32, 1), root.getChild(t, 'i').?.count());
}

test "child keys ordered a..z then ';'" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "abc", .value = "1" },
        .{ .keys = "abd", .value = "2" },
        .{ .keys = "aba", .value = "3" },
        .{ .keys = "abb", .value = "4" },
    });
    defer th.deinit(testing.allocator);
    const ab = th.trie.root().getChild(&th.trie, 'a').?.getChild(&th.trie, 'b').?;
    try testing.expectEqual(@as(u8, 4), ab.getWidth());
    inline for ([_]u8{ 'a', 'b', 'c', 'd' }, 0..) |k, i| {
        try testing.expectEqual(k, ab.keyOfChildByIndex(&th.trie, i).?);
    }
}

test "pointer equality across getChild calls" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "ab", .value = "x" },
        .{ .keys = "ac", .value = "y" },
    });
    defer th.deinit(testing.allocator);
    const root = th.trie.root();
    const a1 = root.getChild(&th.trie, 'a').?;
    const a2 = root.getChild(&th.trie, 'a').?;
    try testing.expect(a1 == a2);
}

test "indexOfChild round-trip" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "x" },
        .{ .keys = "z", .value = "y" },
        .{ .keys = ";", .value = "z" },
    });
    defer th.deinit(testing.allocator);
    const t = &th.trie;
    const root = t.root();
    inline for ([_]u8{ 'a', 'z', ';' }) |k| {
        const idx = root.indexOfChild(t, k).?;
        try testing.expectEqual(k, root.keyOfChildByIndex(t, idx).?);
        try testing.expect(root.getChild(t, k) != null);
    }
    try testing.expect(root.getChild(t, 'b') == null);
}

test "many values on one code" {
    // A node's values_len was a byte once; it is a u32 now.
    var entries: [300]Entry = undefined;
    var names: [300][8]u8 = undefined;
    for (&entries, &names, 0..) |*e, *name, i| {
        const v = std.fmt.bufPrint(name, "v{d}", .{i}) catch unreachable;
        e.* = .{ .keys = "a", .value = v };
    }
    var th = try buildTrie(testing.allocator, &entries);
    defer th.deinit(testing.allocator);
    const a = th.trie.root().getChild(&th.trie, 'a').?;
    try testing.expectEqual(@as(usize, 300), a.values(&th.trie).len());
    try testing.expectEqualStrings("v299", a.values(&th.trie).at(299));
}

test "max_value_len is computed and round-trips through the blob" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "甲" }, // 3 bytes
        .{ .keys = "ab", .value = "abcdefghij" }, // 10 bytes — the max
        .{ .keys = "c", .value = "xy" },
    });
    defer th.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 10), th.trie.max_value_len);
}

test "keyOfRank inverts keyRank over the whole alphabet" {
    var c: u8 = 'a';
    while (c <= 'z') : (c += 1) try testing.expectEqual(c, keyOfRank(keyRank(c)));
    try testing.expectEqual(@as(u8, ';'), keyOfRank(keyRank(';')));
    try testing.expectEqual(@as(u8, 26), keyRank(keyOfRank(26)));
}

test "isValidKeyByte matches the a-z ';' alphabet exactly" {
    var valid_count: usize = 0;
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        const b: u8 = @intCast(c);
        const expected = (b >= 'a' and b <= 'z') or b == ';';
        try testing.expectEqual(expected, isValidKeyByte(b));
        if (isValidKeyByte(b)) valid_count += 1;
    }
    try testing.expectEqual(ALPHA, valid_count);
}

test "nodes are numbered breadth-first, children in key-rank order" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "ba", .value = "1" },
        .{ .keys = ";", .value = "2" },
        .{ .keys = "a", .value = "3" },
        .{ .keys = "b", .value = "4" },
        .{ .keys = "abc", .value = "5" },
    });
    defer th.deinit(testing.allocator);
    const t = &th.trie;
    // Depth 1 in rank order (a, b, ';'), then depth 2 (ab, ba), then abc —
    // and every non-root node's own key is the child slot just before it.
    const want = [_][]const u8{ "", "a", "b", ";", "ab", "ba", "abc" };
    try testing.expectEqual(want.len, t.nodes.len);
    for (want, 0..) |keys, i| {
        var node = t.root();
        for (keys) |k| node = node.getChild(t, k).?;
        try testing.expectEqual(@as(u32, @intCast(i)), t.indexOf(node));
        var buf: [MAX_KEYS_LEN]u8 = undefined;
        try testing.expectEqualStrings(keys, t.codeOf(@intCast(i), &buf));
    }
}

test "codeOf and nodeOfValue invert the trie for every value" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "nkhz", .value = "你好" },
        .{ .keys = "nk", .value = "你" },
        .{ .keys = "nk", .value = "您" },
        .{ .keys = "z", .value = "在" },
        .{ .keys = "zzzzzz", .value = "在" },
        .{ .keys = ";;", .value = "：" },
        .{ .keys = "nkh", .value = "你会" },
    });
    defer th.deinit(testing.allocator);
    const t = &th.trie;
    // Walk the trie depth-first and check every value maps back to the
    // path that reached it.
    const Walk = struct {
        fn go(trie: *const Trie, node: *const Trie.Node, path: []u8, depth: usize) !void {
            const vs = node.values(trie);
            for (0..vs.len()) |i| {
                const v: u32 = node.inner.values_start + @as(u32, @intCast(i));
                try testing.expectEqual(trie.indexOf(node), trie.nodeOfValue(v));
                var buf: [MAX_KEYS_LEN]u8 = undefined;
                try testing.expectEqualStrings(path[0..depth], trie.codeOf(trie.nodeOfValue(v), &buf));
            }
            for (0..node.getWidth()) |i| {
                path[depth] = node.keyOfChildByIndex(trie, i).?;
                try go(trie, node.getChildByIndex(trie, i).?, path, depth + 1);
            }
        }
    };
    var path: [MAX_KEYS_LEN]u8 = undefined;
    try Walk.go(t, t.root(), &path, 0);
}

test "valuesEqualTo finds every code of a value, shortest first" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "zzzzzz", .value = "在" },
        .{ .keys = "nk", .value = "你" },
        .{ .keys = "zb", .value = "在" },
        .{ .keys = "z", .value = "在" },
        .{ .keys = "ab", .value = "在" },
        .{ .keys = "zb", .value = "在在" }, // a longer value with the same prefix
        .{ .keys = "y", .value = "圧" }, // a value sorting right after 在
    });
    defer th.deinit(testing.allocator);
    const t = &th.trie;

    const hits = t.valuesEqualTo("在");
    var codes: [4][]const u8 = undefined;
    var bufs: [4][MAX_KEYS_LEN]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), hits.len);
    for (hits, 0..) |v, i| {
        try testing.expectEqualStrings("在", t.values[v].bytes(t.strings));
        codes[i] = t.codeOf(t.nodeOfValue(v), &bufs[i]);
    }
    try testing.expectEqualStrings("z", codes[0]);
    try testing.expectEqualStrings("ab", codes[1]);
    try testing.expectEqualStrings("zb", codes[2]);
    try testing.expectEqualStrings("zzzzzz", codes[3]);

    try testing.expectEqual(@as(usize, 1), t.valuesEqualTo("在在").len);
    try testing.expectEqual(@as(usize, 0), t.valuesEqualTo("").len);
    try testing.expectEqual(@as(usize, 0), t.valuesEqualTo("在在在").len);
    try testing.expectEqual(@as(usize, 0), t.valuesEqualTo("不").len);
}

test "an empty trie has just the root" {
    var th = try buildTrie(testing.allocator, &.{});
    defer th.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), th.trie.nodes.len);
    try testing.expectEqual(@as(usize, 0), th.trie.child_keys.len);
    try testing.expectEqual(@as(usize, 0), th.trie.valuesEqualTo("x").len);
    try testing.expect(th.trie.root().getChild(&th.trie, 'a') == null);
}
