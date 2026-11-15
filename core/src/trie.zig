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

/// Runtime view over an embedded trie blob. Construct with `fromBytes`.
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

    pub const Node = NodeView;

    /// Parse a blob produced by `buildBlob` (or by `scripts/gen_trie.zig`).
    /// O(1) — just header read + slice header construction.
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
    target_endian: std.lang.Endian,
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

    // ---- Phase 1: walk entries, build trie shape (nodes numbered in
    // insertion order for now), count values ----
    // Hard errors, not asserts: this code runs in the generator's
    // `fast` build, where `std.debug.assert` compiles to nothing —
    // a violated invariant here must fail the build, not ship as UB.
    var max_value_len: u32 = 0;
    for (entries) |e| {
        // Key sequences must fit `Context.pressed_keys: [MAX_KEYS_LEN]usize`
        // (query.zig writes it unchecked during trie descent).
        if (e.keys.len > MAX_KEYS_LEN) return error.EntryKeysTooLong;
        // The longest value sets the commit bound reported by
        // `jd_abi_layout(JD_ABI_MAX_COMMIT_LEN)`; track it in the header.
        max_value_len = @max(max_value_len, std.math.cast(u32, e.value.len) orelse
            return error.EntryValueTooLong);
        var cur: u32 = 0;
        for (e.keys) |k| {
            // Reject bytes outside the a-z + ';' alphabet. Without this, one
            // bad dictionary line can give a node a 28th distinct child and
            // overflow Phase 2's fixed [ALPHA] insertion buffers — silent
            // stack corruption in the generator's `fast` build.
            if (!isValidKeyByte(k)) return error.EntryKeyOutsideAlphabet;
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

    // ---- Phase 2: renumber breadth-first, children in keyRank order.
    // Visiting node `i` (new numbering) hands its children the next free
    // numbers, so its child slots start at `next - 1` and the child pool
    // needs no indices (see `fmt.Header`). Everything below works in the
    // new numbering; `old_of` maps back for the per-node build data. ----
    var old_of = try allocator.alloc(u32, NC);
    defer allocator.free(old_of);
    var new_of = try allocator.alloc(u32, NC);
    defer allocator.free(new_of);
    var widths = try allocator.alloc(u8, NC);
    defer allocator.free(widths);
    var children_start = try allocator.alloc(u32, NC);
    defer allocator.free(children_start);
    var child_keys = try allocator.alloc(u8, fmt.childKeysTotal(NC));
    defer allocator.free(child_keys);
    {
        old_of[0] = 0;
        new_of[0] = 0;
        var next: u32 = 1;
        var i: u32 = 0;
        while (i < NC) : (i += 1) {
            var keys_tmp: [ALPHA]u8 = undefined;
            var nodes_tmp: [ALPHA]u32 = undefined;
            var w: usize = 0;
            var rec_idx = nodes[old_of[i]].first_child;
            while (rec_idx != 0) : (rec_idx = records[rec_idx].next_sibling) {
                // Guaranteed by the alphabet check in Phase 1 (≤ 27 distinct
                // bytes); re-checked here because the fixed [ALPHA] buffers
                // and the u8 width field depend on it directly.
                if (w == ALPHA) return error.NodeTooWide;
                const k = records[rec_idx].key;
                const kr = keyRank(k);
                var ins = w;
                while (ins > 0 and keyRank(keys_tmp[ins - 1]) > kr) : (ins -= 1) {
                    keys_tmp[ins] = keys_tmp[ins - 1];
                    nodes_tmp[ins] = nodes_tmp[ins - 1];
                }
                keys_tmp[ins] = k;
                nodes_tmp[ins] = records[rec_idx].child_node;
                w += 1;
            }
            widths[i] = @intCast(w);
            children_start[i] = next - 1;
            for (keys_tmp[0..w], nodes_tmp[0..w]) |k, old| {
                child_keys[next - 1] = k;
                old_of[next] = old;
                new_of[old] = next;
                next += 1;
            }
        }
        std.debug.assert(next == NC);
    }

    // ---- Phase 3: subtree counts (children always have higher index than
    // their parent, so a reverse pass is post-order) ----
    var counts = try allocator.alloc(u32, NC);
    defer allocator.free(counts);
    {
        var i: usize = NC;
        while (i > 0) {
            i -= 1;
            counts[i] = nodes[old_of[i]].value_count;
            for (children_start[i] + 1..children_start[i] + 1 + widths[i]) |c| counts[i] += counts[c];
        }
    }
    // The root's subtree count is the global maximum, and the packed node
    // stores counts in 24 bits (fmt.Node.pack asserts that only in `debug`).
    if (counts[0] > 0x00FF_FFFF) return error.TooManyValuesTotal;

    // ---- Phase 3b: subtree node count + path bytes, for sizing the per-
    // context BFS buffers in `jd_init`. Same reverse-pass shape as Phase 3:
    //   node_count[i] = 1 + Σ node_count[child]
    //   path_bytes[i] = Σ (node_count[child] + path_bytes[child])
    // We then take the max over non-root indices — `NodePagination.init` is
    // never called on the root, so the root's totals (which sum the whole
    // trie) don't enter the bound. ----
    var subtree_node_count = try allocator.alloc(u32, NC);
    defer allocator.free(subtree_node_count);
    var subtree_path_bytes = try allocator.alloc(u32, NC);
    defer allocator.free(subtree_path_bytes);
    var frontier_cap: u32 = 0;
    var path_buf_cap: u32 = 0;
    {
        var i: usize = NC;
        while (i > 0) {
            i -= 1;
            subtree_node_count[i] = 1;
            subtree_path_bytes[i] = 0;
            for (children_start[i] + 1..children_start[i] + 1 + widths[i]) |c| {
                subtree_node_count[i] += subtree_node_count[c];
                subtree_path_bytes[i] += subtree_node_count[c] + subtree_path_bytes[c];
            }
            if (i == 0) break; // skip root
            frontier_cap = @max(frontier_cap, subtree_node_count[i]);
            path_buf_cap = @max(path_buf_cap, subtree_path_bytes[i]);
        }
    }

    // ---- Phase 4: value offsets per node, in node order ----
    var value_offset = try allocator.alloc(u32, NC);
    defer allocator.free(value_offset);
    var values_total: u32 = 0;
    {
        var i: u32 = 0;
        while (i < NC) : (i += 1) {
            value_offset[i] = values_total;
            // values_len is a u8 in the blob node; more entries than that
            // sharing one exact key sequence would truncate silently and
            // desync count() from the actual value list.
            const vc = nodes[old_of[i]].value_count;
            if (vc > std.math.maxInt(u8)) return error.TooManyValuesPerNode;
            values_total += vc;
        }
    }

    // ---- Phase 5: walk entries again, place each value at its node's
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
        const n = new_of[cur];
        values[fill_pos[n]] = .{
            .str_start = str_start,
            .str_len = @intCast(e.value.len),
        };
        fill_pos[n] += 1;
    }

    // ---- Phase 6: the reverse index — every value index, ordered by the
    // value's bytes and then by index, so equal values sit together in
    // node order (shortest code first) ----
    const by_value = try allocator.alloc(u32, values_total);
    defer allocator.free(by_value);
    for (by_value, 0..) |*slot, i| slot.* = @intCast(i);
    {
        const Order = struct {
            values: []const fmt.Value,
            strings: []const u8,
            fn lessThan(ctx: @This(), a: u32, b: u32) bool {
                return switch (std.mem.order(u8, ctx.values[a].bytes(ctx.strings), ctx.values[b].bytes(ctx.strings))) {
                    .lt => true,
                    .gt => false,
                    .eq => a < b,
                };
            }
        };
        std.sort.pdq(u32, by_value, Order{ .values = values, .strings = strings.items }, Order.lessThan);
    }

    // ---- Phase 7: assemble the final blob ----
    const offsets = fmt.PoolOffsets.compute(NC, values_total);
    const total = fmt.blobSize(NC, values_total, strings.items.len);
    const buf = try allocator.alignedAlloc(u8, .@"4", total);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(fmt.Header, buf[0..@sizeOf(fmt.Header)]);
    header.* = .{
        .node_count = NC,
        .values_count = values_total,
        .strings_total = @intCast(strings.items.len),
        .frontier_cap = frontier_cap,
        .path_buf_cap = path_buf_cap,
        .max_value_len = max_value_len,
    };

    const nodes_dst = std.mem.bytesAsSlice(fmt.Node, buf[offsets.nodes..][0 .. NC * @sizeOf(fmt.Node)]);
    {
        var i: u32 = 0;
        while (i < NC) : (i += 1) {
            nodes_dst[i] = .{
                .count_and_width = fmt.Node.pack(counts[i], widths[i]),
                .values_start = value_offset[i],
                .children_start = children_start[i],
                .values_len = @intCast(nodes[old_of[i]].value_count),
                ._pad = .{ 0, 0, 0 },
            };
        }
    }
    @memcpy(
        std.mem.bytesAsSlice(fmt.Value, buf[offsets.values..][0 .. values_total * @sizeOf(fmt.Value)]),
        values,
    );
    @memcpy(
        std.mem.bytesAsSlice(u32, buf[offsets.by_value..][0 .. values_total * @sizeOf(u32)]),
        by_value,
    );
    @memcpy(buf[offsets.child_keys..][0..child_keys.len], child_keys);
    @memcpy(buf[offsets.strings..][0..strings.items.len], strings.items);

    // The struct writes above all use host-native u32 storage. If the
    // target's endianness differs, swap every u32 field in place so the
    // runtime can `@ptrCast` straight to []const Node etc. on its side.
    if (target_endian != builtin.target.cpu.arch.endian()) {
        byteSwapBlob(buf, builtin.target.cpu.arch.endian());
    }

    return buf;
}

/// Byte-swap every u32 field of a blob in place. Reads the header's count
/// fields as `current_endian` so it can locate the per-pool offsets; after
/// the call, the blob is in the opposite endianness from `current_endian`.
///
/// The function only touches the u32 fields (header, node, value,
/// by-value index); u8 fields (`Node.values_len`, child keys, strings) and
/// padding bytes are left untouched.
fn byteSwapBlob(buf: []align(4) u8, current_endian: std.lang.Endian) void {
    const node_count = std.mem.readInt(u32, buf[0..4], current_endian);
    const values_count = std.mem.readInt(u32, buf[4..8], current_endian);
    const offsets = fmt.PoolOffsets.compute(node_count, values_count);

    for (0..fmt.HEADER_WORDS) |i| swap32At(buf, i * 4);

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

    // By-value index: one u32 per value.
    for (0..values_count) |i| {
        swap32At(buf, offsets.by_value + i * 4);
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
    const bytes = try buildBlob(allocator, entries, builtin.target.cpu.arch.endian());
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

test "max_value_len is computed and round-trips through the blob" {
    var th = try buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "甲" }, // 3 bytes
        .{ .keys = "ab", .value = "abcdefghij" }, // 10 bytes — the max
        .{ .keys = "c", .value = "xy" },
    });
    defer th.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 10), th.trie.max_value_len);
}

test "entries with keys longer than MAX_KEYS_LEN are a hard error" {
    try testing.expectError(error.EntryKeysTooLong, buildTrie(testing.allocator, &.{
        .{ .keys = "abcdefg", .value = "x" }, // 7 keys > MAX_KEYS_LEN (6)
    }));
}

test "entries with keys outside the a-z ';' alphabet are a hard error" {
    // Uppercase, digits, and whitespace are the likely dictionary typos;
    // each must fail the build instead of overflowing Phase 2's fixed
    // [ALPHA] insertion buffers in the generator's `fast` build.
    inline for (.{ "A", "0", " ", "a-", "a\tb" }) |keys| {
        try testing.expectError(error.EntryKeyOutsideAlphabet, buildTrie(testing.allocator, &.{
            .{ .keys = keys, .value = "x" },
        }));
    }
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

test "more than 255 values on one key sequence is a hard error" {
    // values_len is a u8 in the blob node; 256 entries sharing one key
    // sequence used to truncate silently in `fast` builds.
    var entries: [256]Entry = undefined;
    for (&entries) |*e| e.* = .{ .keys = "a", .value = "x" };
    try testing.expectError(error.TooManyValuesPerNode, buildTrie(testing.allocator, &entries));

    // 255 on the node is the boundary and must still build.
    var th = try buildTrie(testing.allocator, entries[0..255]);
    defer th.deinit(testing.allocator);
    const a = th.trie.root().getChild(&th.trie, 'a').?;
    try testing.expectEqual(@as(usize, 255), a.values(&th.trie).len());
}

test "fromBytes rejects undersized buffer" {
    var bytes: [@sizeOf(fmt.Header) - 1]u8 align(4) = undefined;
    @memset(&bytes, 0);
    try testing.expectError(error.BlobTooSmall, Trie.fromBytes(&bytes));
}

test "buildBlob produces a byte-swapped blob for cross-endian targets" {
    const host = builtin.target.cpu.arch.endian();
    const opposite: std.lang.Endian = switch (host) {
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
