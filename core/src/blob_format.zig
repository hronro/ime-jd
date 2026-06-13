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

pub const MAGIC: u32 = 0x4A445452; // "JDTR" in little-endian byte order
pub const VERSION: u32 = 1;

/// 32-byte fixed header at offset 0 of the blob.
/// Pool offsets are computed at runtime from the counts here.
pub const Header = extern struct {
    magic: u32,
    version: u32,

    node_count: u32,
    values_count: u32,

    // Pool sizes (in elements, not bytes).
    child_keys_total: u32,
    child_indices_total: u32,
    strings_total: u32,

    _reserved: u32,
};

/// 16-byte fixed-layout node. `_pad` is unused but keeps the struct
/// 4-aligned so an array of Nodes is naturally aligned for u32 reads.
pub const Node = extern struct {
    // count occupies the low 24 bits, width the high 8 bits. We pack them
    // because count fits comfortably in 24 bits even at full scale
    // (140K << 16M) and packing saves 3 bytes/node of otherwise-wasted
    // alignment padding.
    count_and_width: u32,

    // Offset into values_pool where this node's values list starts.
    values_start: u32,

    // Offset into child_indices_pool (and parallel child_keys_pool) where
    // this node's children list starts.
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

/// Compute total blob size for given pool counts. Generator uses this to
/// size its output buffer; runtime uses it as a sanity check.
pub fn blobSize(
    node_count: usize,
    values_count: usize,
    child_indices_total: usize,
    child_keys_total: usize,
    strings_total: usize,
) usize {
    return @sizeOf(Header) +
        node_count * @sizeOf(Node) +
        values_count * @sizeOf(Value) +
        child_indices_total * @sizeOf(u32) +
        // child_keys are 1-byte; we round up to maintain alignment for
        // anything that might follow (currently nothing — but it's cheap
        // safety for future fields).
        std.mem.alignForward(usize, child_keys_total, 4) +
        strings_total;
}

/// Pool offsets within the blob. Used by both the generator (to know
/// where to write each pool) and the runtime (to know where to read).
pub const PoolOffsets = struct {
    nodes: usize,
    values: usize,
    child_indices: usize,
    child_keys: usize,
    strings: usize,

    pub fn compute(
        node_count: usize,
        values_count: usize,
        child_indices_total: usize,
        child_keys_total: usize,
    ) PoolOffsets {
        const nodes = @sizeOf(Header);
        const values = nodes + node_count * @sizeOf(Node);
        const child_indices = values + values_count * @sizeOf(Value);
        const child_keys = child_indices + child_indices_total * @sizeOf(u32);
        const strings = child_keys + std.mem.alignForward(usize, child_keys_total, 4);
        return .{
            .nodes = nodes,
            .values = values,
            .child_indices = child_indices,
            .child_keys = child_keys,
            .strings = strings,
        };
    }
};
