//! Trie API + builder, paired with `blob_format.zig`.
//!
//! At runtime the library reads an on-disk blob produced at build time (see
//! `scripts/gen_trie.zig`), reinterprets it with `Trie.fromBytes`, and walks
//! the resulting `Node`s via `getChild`/`values()`/etc. The blob layout is
//! defined in `blob_format.zig` and is the only thing the two ends share.
//!
//! `buildBlob` is exposed as well so callers — the generator, tests, and
//! anyone who needs a trie from in-memory entries — can build a blob
//! programmatically.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const fmt = @import("./blob_format.zig");

const ALPHA: usize = 27;

fn keyRank(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 'a';
    if (c == ';') return 26;
    return 27;
}

/// One input row: key string + value string. The value will be null-terminated
/// in the on-disk strings pool so `Values.at(i)` can hand out `[:0]const u8`.
pub const Entry = struct {
    keys: []const u8,
    value: []const u8,
};

/// Runtime view over an embedded trie blob. Construct with `fromBytes`.
pub const Trie = struct {
    nodes: []const fmt.Node,
    values: []const fmt.Value,
    child_indices: []const u32,
    child_keys: []const u8,
    strings: []const u8,

    /// Worst-case BFS frontier entry count across any non-root start node.
    frontier_cap: u32,
    /// Worst-case BFS path-buffer byte count across any non-root start node.
    path_buf_cap: u32,

    pub const Node = NodeView;

    /// Parse a blob produced by `buildBlob` (or by `scripts/gen_trie.zig`).
    /// O(1) — just header read + slice header construction.
    pub fn fromBytes(bytes: []align(4) const u8) !Trie {
        if (bytes.len < @sizeOf(fmt.Header)) return error.BlobTooSmall;
        const header_ptr: *const fmt.Header = @ptrCast(@alignCast(bytes.ptr));

        const offsets = fmt.PoolOffsets.compute(
            header_ptr.node_count,
            header_ptr.values_count,
            header_ptr.child_indices_total,
            header_ptr.child_keys_total,
        );

        const nodes_bytes = bytes[offsets.nodes..][0 .. header_ptr.node_count * @sizeOf(fmt.Node)];
        const values_bytes = bytes[offsets.values..][0 .. header_ptr.values_count * @sizeOf(fmt.Value)];
        const child_idx_bytes = bytes[offsets.child_indices..][0 .. header_ptr.child_indices_total * @sizeOf(u32)];
        const child_keys = bytes[offsets.child_keys..][0..header_ptr.child_keys_total];
        const strings = bytes[offsets.strings..][0..header_ptr.strings_total];

        return .{
            .nodes = std.mem.bytesAsSlice(fmt.Node, @as([]align(4) const u8, @alignCast(nodes_bytes))),
            .values = std.mem.bytesAsSlice(fmt.Value, @as([]align(4) const u8, @alignCast(values_bytes))),
            .child_indices = std.mem.bytesAsSlice(u32, @as([]align(4) const u8, @alignCast(child_idx_bytes))),
            .child_keys = child_keys,
            .strings = strings,
            .frontier_cap = header_ptr.frontier_cap,
            .path_buf_cap = header_ptr.path_buf_cap,
        };
    }

    pub fn root(self: *const Trie) *const Node {
        return @ptrCast(&self.nodes[0]);
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
            const w = self.inner.width();
            const start = self.inner.children_start;
            var i: usize = 0;
            while (i < w) : (i += 1) {
                if (trie.child_keys[start + i] == key) {
                    const node_idx = trie.child_indices[start + i];
                    return @ptrCast(&trie.nodes[node_idx]);
                }
            }
            return null;
        }

        pub fn getChildByIndex(self: *const NodeView, trie: *const Trie, index: usize) ?*const NodeView {
            if (index >= self.inner.width()) return null;
            const node_idx = trie.child_indices[self.inner.children_start + index];
            return @ptrCast(&trie.nodes[node_idx]);
        }

        pub fn indexOfChild(self: *const NodeView, trie: *const Trie, key: u8) ?usize {
            const w = self.inner.width();
            const start = self.inner.children_start;
            var i: usize = 0;
            while (i < w) : (i += 1) {
                if (trie.child_keys[start + i] == key) return i;
            }
            return null;
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
// Builder — produces a blob from `[]const Entry`.
// Used by the generator (scripts/gen_trie.zig), by tests, and by anything
// else that needs a trie at runtime without going through a file.
// =========================================================================

const BuildNode = struct {
    /// Index into `records`. 0 = no children (record 0 is reserved as a sentinel).
    first_child: u32,
    value_count: u32,
};

const ChildRecord = struct {
    key: u8,
    /// 0 = end of list.
    next_sibling: u32,
    child_node: u32,
};

/// Build a complete blob from `entries`. Caller owns the returned slice and
/// must free it with `allocator.free`. The slice is `align(4)` so it can
/// be passed straight to `Trie.fromBytes`.
///
/// The resulting blob is in `target_endian` byte order. If the host (where
/// this code runs) and the target differ, every u32 field is byte-swapped
/// after construction so the consumer can `@ptrCast` the bytes in its own
/// native endianness without further translation.
pub fn buildBlob(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    target_endian: std.builtin.Endian,
) ![]align(4) u8 {
    // ---- size the work arrays ----
    var max_nodes: usize = 1;
    for (entries) |e| max_nodes += e.keys.len;

    var nodes = try allocator.alloc(BuildNode, max_nodes);
    defer allocator.free(nodes);
    nodes[0] = .{ .first_child = 0, .value_count = 0 };
    var node_count: u32 = 1;

    var records = try allocator.alloc(ChildRecord, max_nodes);
    defer allocator.free(records);
    records[0] = .{ .key = 0, .next_sibling = 0, .child_node = 0 };
    var record_count: u32 = 1;

    // ---- Phase 1: walk entries, build trie shape, count values ----
    for (entries) |e| {
        // Domain invariants the consumer relies on:
        // - Key sequences fit in `Context.pressed_keys: [MAX_PRESSED_KEYS]usize`
        //   in main.zig (currently 6).
        // - Any commit composition (worst case: two values concatenated)
        //   fits in `Context.commit_scratch: [128]u8`.
        std.debug.assert(e.keys.len <= 6);
        std.debug.assert(e.value.len * 2 + 1 <= 128);
        var cur: u32 = 0;
        for (e.keys) |k| {
            var rec_idx = nodes[cur].first_child;
            var found: u32 = 0;
            while (rec_idx != 0) : (rec_idx = records[rec_idx].next_sibling) {
                if (records[rec_idx].key == k) {
                    found = records[rec_idx].child_node;
                    break;
                }
            }
            if (found == 0) {
                nodes[node_count] = .{ .first_child = 0, .value_count = 0 };
                const new_node = node_count;
                node_count += 1;

                records[record_count] = .{
                    .key = k,
                    .next_sibling = nodes[cur].first_child,
                    .child_node = new_node,
                };
                nodes[cur].first_child = record_count;
                record_count += 1;

                cur = new_node;
            } else cur = found;
        }
        nodes[cur].value_count += 1;
    }
    const NC: u32 = node_count;

    // ---- Phase 2: subtree counts (children always have higher index than
    // their parent, so a reverse pass is post-order) ----
    var counts = try allocator.alloc(u32, NC);
    defer allocator.free(counts);
    {
        var i: usize = 0;
        while (i < NC) : (i += 1) counts[i] = nodes[i].value_count;
    }
    {
        var i: usize = NC;
        while (i > 0) {
            i -= 1;
            var rec_idx = nodes[i].first_child;
            while (rec_idx != 0) : (rec_idx = records[rec_idx].next_sibling) {
                counts[i] += counts[records[rec_idx].child_node];
            }
        }
    }

    // ---- Phase 2b: subtree node count + path bytes, for sizing the per-
    // context BFS buffers in `jd_init`. Same reverse-pass shape as Phase 2:
    //   node_count[i] = 1 + Σ node_count[child]
    //   path_bytes[i] = Σ (node_count[child] + path_bytes[child])
    // We then take the max over non-root indices — `NodePagination.init` is
    // never called on the root, so the root's totals (which sum the whole
    // trie) don't enter the bound. ----
    var subtree_node_count = try allocator.alloc(u32, NC);
    defer allocator.free(subtree_node_count);
    var subtree_path_bytes = try allocator.alloc(u32, NC);
    defer allocator.free(subtree_path_bytes);
    {
        var i: usize = 0;
        while (i < NC) : (i += 1) {
            subtree_node_count[i] = 1;
            subtree_path_bytes[i] = 0;
        }
    }
    {
        var i: usize = NC;
        while (i > 0) {
            i -= 1;
            var rec_idx = nodes[i].first_child;
            while (rec_idx != 0) : (rec_idx = records[rec_idx].next_sibling) {
                const c = records[rec_idx].child_node;
                subtree_node_count[i] += subtree_node_count[c];
                subtree_path_bytes[i] += subtree_node_count[c] + subtree_path_bytes[c];
            }
        }
    }
    var frontier_cap: u32 = 0;
    var path_buf_cap: u32 = 0;
    {
        var i: usize = 1; // skip root
        while (i < NC) : (i += 1) {
            if (subtree_node_count[i] > frontier_cap) frontier_cap = subtree_node_count[i];
            if (subtree_path_bytes[i] > path_buf_cap) path_buf_cap = subtree_path_bytes[i];
        }
    }

    // ---- Phase 3: per-node widths + child pool offsets ----
    var widths = try allocator.alloc(u8, NC);
    defer allocator.free(widths);
    var child_off = try allocator.alloc(u32, NC);
    defer allocator.free(child_off);
    var child_total: u32 = 0;
    {
        var i: u32 = 0;
        while (i < NC) : (i += 1) {
            child_off[i] = child_total;
            var w: u8 = 0;
            var rec_idx = nodes[i].first_child;
            while (rec_idx != 0) : (rec_idx = records[rec_idx].next_sibling) {
                w += 1;
            }
            widths[i] = w;
            child_total += w;
        }
    }

    // ---- Phase 4: emit sorted child keys + indices (sorted by keyRank) ----
    var child_keys = try allocator.alloc(u8, child_total);
    defer allocator.free(child_keys);
    var child_indices = try allocator.alloc(u32, child_total);
    defer allocator.free(child_indices);
    {
        var i: u32 = 0;
        while (i < NC) : (i += 1) {
            var keys_tmp: [ALPHA]u8 = undefined;
            var nodes_tmp: [ALPHA]u32 = undefined;
            var w: usize = 0;
            var rec_idx = nodes[i].first_child;
            while (rec_idx != 0) : (rec_idx = records[rec_idx].next_sibling) {
                const k = records[rec_idx].key;
                const cn = records[rec_idx].child_node;
                const kr = keyRank(k);
                var ins = w;
                while (ins > 0 and keyRank(keys_tmp[ins - 1]) > kr) : (ins -= 1) {
                    keys_tmp[ins] = keys_tmp[ins - 1];
                    nodes_tmp[ins] = nodes_tmp[ins - 1];
                }
                keys_tmp[ins] = k;
                nodes_tmp[ins] = cn;
                w += 1;
            }
            var j: usize = 0;
            while (j < w) : (j += 1) {
                child_keys[child_off[i] + j] = keys_tmp[j];
                child_indices[child_off[i] + j] = nodes_tmp[j];
            }
        }
    }

    // ---- Phase 5: value offsets per node ----
    var value_offset = try allocator.alloc(u32, NC);
    defer allocator.free(value_offset);
    var values_total: u32 = 0;
    {
        var i: u32 = 0;
        while (i < NC) : (i += 1) {
            value_offset[i] = values_total;
            values_total += nodes[i].value_count;
        }
    }

    // ---- Phase 6: walk entries again, place each value at its node's
    // slot in the value pool, and concatenate the string payload ----
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(allocator);

    var values = try allocator.alloc(fmt.Value, values_total);
    defer allocator.free(values);

    var fill_pos = try allocator.alloc(u32, NC);
    defer allocator.free(fill_pos);
    @memcpy(fill_pos, value_offset);

    for (entries) |e| {
        var cur: u32 = 0;
        for (e.keys) |k| {
            var rec_idx = nodes[cur].first_child;
            while (rec_idx != 0) : (rec_idx = records[rec_idx].next_sibling) {
                if (records[rec_idx].key == k) {
                    cur = records[rec_idx].child_node;
                    break;
                }
            }
        }
        const str_start: u32 = @intCast(strings.items.len);
        try strings.appendSlice(allocator, e.value);
        try strings.append(allocator, 0); // null terminator so we can hand out [:0]const u8
        values[fill_pos[cur]] = .{
            .str_start = str_start,
            .str_len = @intCast(e.value.len),
        };
        fill_pos[cur] += 1;
    }

    // ---- Phase 7: assemble the final blob ----
    const offsets = fmt.PoolOffsets.compute(NC, values_total, child_total, child_total);
    const total = offsets.strings + strings.items.len;
    const buf = try allocator.alignedAlloc(u8, .@"4", total);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(fmt.Header, buf[0..@sizeOf(fmt.Header)]);
    header.* = .{
        .node_count = NC,
        .values_count = values_total,
        .child_keys_total = child_total,
        .child_indices_total = child_total,
        .strings_total = @intCast(strings.items.len),
        .frontier_cap = frontier_cap,
        .path_buf_cap = path_buf_cap,
    };

    const nodes_dst = std.mem.bytesAsSlice(fmt.Node, buf[offsets.nodes..][0 .. NC * @sizeOf(fmt.Node)]);
    {
        var i: u32 = 0;
        while (i < NC) : (i += 1) {
            nodes_dst[i] = .{
                .count_and_width = fmt.Node.pack(counts[i], widths[i]),
                .values_start = value_offset[i],
                .children_start = child_off[i],
                .values_len = @intCast(nodes[i].value_count),
                ._pad = .{ 0, 0, 0 },
            };
        }
    }
    @memcpy(
        std.mem.bytesAsSlice(fmt.Value, buf[offsets.values..][0 .. values_total * @sizeOf(fmt.Value)]),
        values,
    );
    @memcpy(
        std.mem.bytesAsSlice(u32, buf[offsets.child_indices..][0 .. child_total * @sizeOf(u32)]),
        child_indices,
    );
    @memcpy(buf[offsets.child_keys..][0..child_total], child_keys);
    @memcpy(buf[offsets.strings..][0..strings.items.len], strings.items);

    // The struct writes above all use host-native u32 storage. If the
    // target's endianness differs, swap every u32 field in place so the
    // runtime can `@ptrCast` straight to []const Node etc. on its side.
    if (target_endian != builtin.cpu.arch.endian()) {
        byteSwapBlob(buf, builtin.cpu.arch.endian());
    }

    return buf;
}

/// Byte-swap every u32 field of a blob in place. Reads the header's count
/// fields as `current_endian` so it can locate the per-pool offsets; after
/// the call, the blob is in the opposite endianness from `current_endian`.
///
/// The function only touches the u32 fields (header, node, value,
/// child-indices); u8 fields (`Node.values_len`, child keys, strings) and
/// padding bytes are left untouched.
fn byteSwapBlob(buf: []align(4) u8, current_endian: std.builtin.Endian) void {
    const node_count = std.mem.readInt(u32, buf[0..4], current_endian);
    const values_count = std.mem.readInt(u32, buf[4..8], current_endian);
    const child_keys_total = std.mem.readInt(u32, buf[8..12], current_endian);
    const child_indices_total = std.mem.readInt(u32, buf[12..16], current_endian);

    const offsets = fmt.PoolOffsets.compute(
        node_count,
        values_count,
        child_indices_total,
        child_keys_total,
    );

    // Header: 7 u32 fields starting at offset 0.
    for (0..7) |i| swap32At(buf, i * 4);

    // Nodes: 3 u32 fields per Node (count_and_width, values_start,
    // children_start); the trailing u8 + padding doesn't need swapping.
    for (0..node_count) |i| {
        const off = offsets.nodes + i * @sizeOf(fmt.Node);
        swap32At(buf, off);
        swap32At(buf, off + 4);
        swap32At(buf, off + 8);
    }

    // Values: 2 u32 fields per Value (str_start, str_len).
    for (0..values_count) |i| {
        const off = offsets.values + i * @sizeOf(fmt.Value);
        swap32At(buf, off);
        swap32At(buf, off + 4);
    }

    // Child indices: one u32 each.
    for (0..child_indices_total) |i| {
        swap32At(buf, offsets.child_indices + i * 4);
    }
}

inline fn swap32At(buf: []align(4) u8, offset: usize) void {
    const slot: *align(4) u32 = @ptrCast(@alignCast(buf[offset..].ptr));
    slot.* = @byteSwap(slot.*);
}

/// Convenience for tests / runtime callers: build the blob and reinterpret
/// it in one shot. Caller owns `.bytes` and must call `deinit`.
pub const TrieHandle = struct {
    bytes: []align(4) u8,
    trie: Trie,

    pub fn deinit(self: *TrieHandle, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub fn buildTrie(allocator: std.mem.Allocator, entries: []const Entry) !TrieHandle {
    // Use host endianness — the handle is consumed in the same process, so
    // the runtime reads it natively.
    const bytes = try buildBlob(allocator, entries, builtin.cpu.arch.endian());
    errdefer allocator.free(bytes);
    return .{ .bytes = bytes, .trie = try Trie.fromBytes(bytes) };
}

// =========================================================================
// Tests
// =========================================================================

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

test "fromBytes rejects undersized buffer" {
    var bytes: [@sizeOf(fmt.Header) - 1]u8 align(4) = undefined;
    @memset(&bytes, 0);
    try testing.expectError(error.BlobTooSmall, Trie.fromBytes(&bytes));
}

test "buildBlob produces a byte-swapped blob for cross-endian targets" {
    const host = builtin.cpu.arch.endian();
    const opposite: std.builtin.Endian = switch (host) {
        .little => .big,
        .big => .little,
    };

    const entries = [_]Entry{
        .{ .keys = "a", .value = "甲" },
        .{ .keys = "ab", .value = "乙" },
        .{ .keys = "ab", .value = "丙" },
        .{ .keys = "ac", .value = "丁" },
    };

    const native = try buildBlob(testing.allocator, &entries, host);
    defer testing.allocator.free(native);

    const swapped = try buildBlob(testing.allocator, &entries, opposite);
    defer testing.allocator.free(swapped);

    // Same length, but the first header u32 (node_count) should appear
    // byte-reversed in the cross-endian build.
    try testing.expectEqual(native.len, swapped.len);
    var native_first_bytes: [4]u8 = native[0..4].*;
    std.mem.reverse(u8, &native_first_bytes);
    try testing.expectEqualSlices(u8, &native_first_bytes, swapped[0..4]);

    // Swap back; the blob should be bit-identical to the natively-built one.
    byteSwapBlob(swapped, opposite);
    try testing.expectEqualSlices(u8, native, swapped);

    // And it must parse and yield the same data.
    const t = try Trie.fromBytes(swapped);
    const a = t.root().getChild(&t, 'a').?;
    try testing.expectEqualStrings("甲", a.values(&t).at(0));
    const ab = a.getChild(&t, 'b').?;
    try testing.expectEqualStrings("乙", ab.values(&t).at(0));
    try testing.expectEqualStrings("丙", ab.values(&t).at(1));
    const ac = a.getChild(&t, 'c').?;
    try testing.expectEqualStrings("丁", ac.values(&t).at(0));
}
