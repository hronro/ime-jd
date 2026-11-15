//! On-disk format for the build-time-generated trie blob.
//!
//! The generator (`scripts/gen_trie.zig`) emits a single contiguous byte
//! buffer in this layout; the runtime (`trie.zig`) reinterprets that
//! buffer in place via @ptrCast. Both ends must speak the same format, so
//! everything is defined once here.
//!
//! Cross-platform notes:
//!   - All integer fields are explicit u8/u32 — no usize.
//!   - Layout uses `extern struct` so field order/padding is guaranteed.
//!   - All multi-byte integers are stored in **target** endianness. The
//!     build-time generator (`scripts/gen_trie.zig`) runs on the host;
//!     when the host and target endianness differ, `trie.buildBlob`
//!     byte-swaps every u32 field after construction. The runtime is
//!     consequently free to read fields directly via `@ptrCast`, in its
//!     own native endianness, on any target.
//!   - The Node struct is 16 bytes including 3 bytes of natural padding
//!     after `values_len`. Keep it 4-byte-aligned so the runtime can take
//!     the embedded byte slice and @ptrCast it to []const Node without
//!     copying. The build system aligns @embedFile data; we assert the
//!     alignment at startup as a sanity check.

const std = @import("std");

/// 24-byte fixed header at offset 0 of the blob.
/// Pool offsets are computed at runtime from the counts here.
///
/// No magic/version fields: the blob is regenerated from source every build
/// (`scripts/gen_trie.zig` → `trie.bin` → `@embedFile`), so generator and
/// runtime are always in lockstep within this monorepo.
///
/// Nodes are numbered breadth-first from the root (index 0), each node's
/// children in `keyRank` order. That makes the child pool implicit: the
/// children of every node, laid end to end in node order, are nodes 1, 2,
/// 3, … — so child slot `k` *is* node `k + 1`, and a node's own key is
/// `child_keys[index - 1]`. It also makes node order the order candidates
/// are enumerated in (shorter codes first, ties by key rank), and lets the
/// parent of node `n` be found by a binary search for the child slot
/// `n - 1` over the nodes' `children_start` — which is what turns a value
/// back into its code.
pub const Header = extern struct {
    node_count: u32,
    values_count: u32,
    /// Bytes in the strings pool, NULs included.
    strings_total: u32,

    // Worst-case BFS state sizes — computed in `buildBlob`, consumed by
    // `jd_init` to size the per-context buffer. `frontier_cap` is the max
    // node count in any non-root subtree; `path_buf_cap` is the max sum of
    // (depth − start_depth) across nodes in any non-root subtree.
    frontier_cap: u32,
    path_buf_cap: u32,

    // Longest value string in bytes (excluding the NUL terminator) —
    // computed in `buildBlob`. It sets the upper bound a consumer can query
    // via `jd_abi_layout(JD_ABI_MAX_COMMIT_LEN)` when it wants a fixed buffer
    // big enough to join any commit the engine can produce.
    max_value_len: u32,
};

/// Number of u32 fields in `Header` — what a cross-endian build swaps.
pub const HEADER_WORDS: usize = @sizeOf(Header) / @sizeOf(u32);

/// 16-byte fixed-layout node. `_pad` is unused but keeps the struct
/// 4-aligned so an array of Nodes is naturally aligned for u32 reads.
pub const Node = extern struct {
    // count occupies the low 24 bits, width the high 8 bits. We pack them
    // because count fits comfortably in 24 bits even at full scale
    // (140K << 16M) and packing saves 3 bytes/node of otherwise-wasted
    // alignment padding.
    count_and_width: u32,

    // Offset into values_pool where this node's values list starts.
    // Non-decreasing in node order, like `children_start`.
    values_start: u32,

    // Slot in child_keys where this node's children start. The child in
    // slot `k` is node `k + 1` (see `Header`), so the children are nodes
    // `children_start + 1 ..= children_start + width`.
    children_start: u32,

    // Number of values directly at this node (usually 0–3).
    // Width is the number of children — packed into count_and_width above.
    values_len: u8,

    _pad: [3]u8,

    pub inline fn count(self: *const Node) u32 {
        return self.count_and_width & 0x00FF_FFFF;
    }

    pub inline fn width(self: *const Node) u8 {
        return @intCast(self.count_and_width >> 24);
    }

    pub fn pack(c: u32, w: u8) u32 {
        std.debug.assert(c <= 0x00FF_FFFF);
        return (@as(u32, w) << 24) | (c & 0x00FF_FFFF);
    }
};

/// 8-byte value entry. Each node's values are a contiguous range of
/// these. Each Value points into the shared strings pool.
pub const Value = extern struct {
    str_start: u32,
    str_len: u32,

    pub inline fn bytes(self: *const Value, strings: []const u8) [:0]const u8 {
        // Strings are emitted with a trailing 0 byte so we can hand out a
        // [:0]const u8 slice safely.
        return strings[self.str_start..][0..self.str_len :0];
    }
};

/// Every non-root node has exactly one incoming edge, so the child pool
/// holds one key per node but the root.
pub fn childKeysTotal(node_count: usize) usize {
    return node_count -| 1;
}

/// Compute total blob size for given pool counts. Generator uses this to
/// size its output buffer; runtime uses it as a sanity check.
pub fn blobSize(node_count: usize, values_count: usize, strings_total: usize) usize {
    return PoolOffsets.compute(node_count, values_count).strings + strings_total;
}

/// Pool offsets within the blob. Used by both the generator (to know
/// where to write each pool) and the runtime (to know where to read).
///
///   [Header][Node × node_count][Value × values_count]
///   [u32 × values_count: by_value][u8 × node_count − 1: child_keys, padded to 4]
///   [strings]
///
/// `by_value` lists every value index once, sorted by the value's bytes
/// and then by index — so the values equal to a string are one binary
/// search away and come out in node order, i.e. shortest code first.
pub const PoolOffsets = struct {
    nodes: usize,
    values: usize,
    by_value: usize,
    child_keys: usize,
    strings: usize,

    pub fn compute(node_count: usize, values_count: usize) PoolOffsets {
        const nodes = @sizeOf(Header);
        const values = nodes + node_count * @sizeOf(Node);
        const by_value = values + values_count * @sizeOf(Value);
        const child_keys = by_value + values_count * @sizeOf(u32);
        // child_keys are 1-byte; round up to keep the strings pool — and
        // anything that might follow it — 4-aligned.
        const strings = child_keys + std.mem.alignForward(usize, childKeysTotal(node_count), 4);
        return .{
            .nodes = nodes,
            .values = values,
            .by_value = by_value,
            .child_keys = child_keys,
            .strings = strings,
        };
    }
};
