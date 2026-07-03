//! Punctuation-marks API + builder, paired with `punc_format.zig`.
//!
//! Two source-table shapes are modeled independently:
//!
//!   - **Normal**: one line of `normal.txt` = `<key>\t<value>[\t<value>...]`.
//!     Each source line becomes one `NormalEntry` slot indexed by key.
//!   - **Paired**: one line of `paired.txt` = `<key>\t<open>\t<close>`.
//!     Each line becomes one `PairedEntry` slot indexed by key.
//!
//! At runtime the library reads an embedded blob produced at build time
//! and reinterprets it with `Punc.fromBytes`. The two tables are direct-
//! indexed by the ASCII byte the user pressed; an absent slot is detected
//! via `isPresent()` on either entry type.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const fmt = @import("punc_format");

/// Builder input: one row of `normal.txt`.
pub const NormalInput = struct {
    key: u8,
    /// Source-order candidate values. The first becomes the default.
    candidates: []const []const u8,
};

/// Builder input: one row of `paired.txt`.
pub const PairedInput = struct {
    key: u8,
    open: []const u8,
    close: []const u8,
};

/// Runtime view over an embedded punc blob. Construct with `fromBytes`.
pub const Punc = struct {
    normal_table: *const [fmt.TABLE_SIZE]fmt.NormalEntry,
    paired_table: *const [fmt.TABLE_SIZE]fmt.PairedEntry,
    strings: []const u8,

    /// Longest candidate/half string in bytes (excluding the NUL terminator).
    max_value_len: u32,

    /// Parse a blob produced by `buildBlob` (or by `scripts/gen_punc.zig`).
    /// O(1) — just header read + slice header construction.
    pub fn fromBytes(bytes: []align(4) const u8) !Punc {
        if (bytes.len < @sizeOf(fmt.Header)) return error.BlobTooSmall;
        const header_ptr: *const fmt.Header = @ptrCast(@alignCast(bytes.ptr));

        const offsets = fmt.PoolOffsets.compute();

        const normal_ptr: *const [fmt.TABLE_SIZE]fmt.NormalEntry =
            @ptrCast(@alignCast(bytes[offsets.normal_table..].ptr));
        const paired_ptr: *const [fmt.TABLE_SIZE]fmt.PairedEntry =
            @ptrCast(@alignCast(bytes[offsets.paired_table..].ptr));
        const strings = bytes[offsets.strings..][0..header_ptr.strings_total];

        return .{
            .normal_table = normal_ptr,
            .paired_table = paired_ptr,
            .strings = strings,
            .max_value_len = header_ptr.max_value_len,
        };
    }

    /// Returns the normal entry for `key`, or null if no normal mapping.
    pub fn lookupNormal(self: *const Punc, key: u8) ?*const fmt.NormalEntry {
        const entry = &self.normal_table[key];
        if (!entry.isPresent()) return null;
        return entry;
    }

    /// Returns the paired entry for `key`, or null if no paired mapping.
    pub fn lookupPaired(self: *const Punc, key: u8) ?*const fmt.PairedEntry {
        const entry = &self.paired_table[key];
        if (!entry.isPresent()) return null;
        return entry;
    }

    /// Pointer to the i-th candidate of `entry`, NUL-terminated. `i` must
    /// be < `entry.candidates_count`. Walks NULs in the strings pool —
    /// O(i × value_len), trivial for punctuation-sized data.
    pub fn candidateAt(self: *const Punc, entry: *const fmt.NormalEntry, i: usize) [*:0]const u8 {
        std.debug.assert(i < entry.candidates_count);
        var offset: usize = entry.values_offset;
        var seen: usize = 0;
        while (seen < i) : (seen += 1) {
            const nul = std.mem.indexOfScalarPos(u8, self.strings, offset, 0).?;
            offset = nul + 1;
        }
        return @ptrCast(&self.strings[offset]);
    }

    /// Open half of a paired entry, NUL-terminated.
    pub fn openValue(self: *const Punc, entry: *const fmt.PairedEntry) [*:0]const u8 {
        return @ptrCast(&self.strings[entry.open_offset]);
    }

    /// Close half of a paired entry, NUL-terminated.
    pub fn closeValue(self: *const Punc, entry: *const fmt.PairedEntry) [*:0]const u8 {
        return @ptrCast(&self.strings[entry.close_offset]);
    }
};

// =========================================================================
// Builder — produces a blob from inputs.
// =========================================================================

/// Build a complete punc blob. Caller owns the returned slice and must
/// free it with `allocator.free`. The slice is `align(4)` so it can be
/// passed straight to `Punc.fromBytes`.
///
/// Within each input list, keys must be unique (caller-checked at build
/// time). The two lists may share keys, but the runtime semantics in
/// `query.zig` (Case C paired, then Case D normal) treat the paired
/// branch as taking precedence — the generator enforces disjointness as
/// a build-time error.
pub fn buildBlob(
    allocator: std.mem.Allocator,
    normals: []const NormalInput,
    paireds: []const PairedInput,
    target_endian: std.builtin.Endian,
) ![]align(4) u8 {
    // ---- Phase 1: build the strings pool. Offset 0 is reserved with a
    // NUL byte so `PairedEntry.open_offset == 0` reliably means "no entry".
    var strings: std.ArrayList(u8) = .empty;
    defer strings.deinit(allocator);
    try strings.append(allocator, 0);

    var normal_table: [fmt.TABLE_SIZE]fmt.NormalEntry = @splat(.{
        .values_offset = 0,
        .candidates_count = 0,
    });
    var paired_table: [fmt.TABLE_SIZE]fmt.PairedEntry = @splat(.{
        .open_offset = 0,
        .close_offset = 0,
    });

    // Longest candidate/half in bytes; sizes the per-context commit
    // scratch buffer via the header (see `query.commitScratchCap`).
    var max_value_len: u32 = 0;

    // ---- Phase 2: emit normals. ----
    for (normals) |n| {
        if (n.candidates.len == 0) return error.NormalEntryHasNoCandidates;
        if (n.candidates.len > std.math.maxInt(u16)) return error.TooManyCandidates;

        const start_offset = strings.items.len;
        if (start_offset > std.math.maxInt(u16)) return error.StringsPoolTooLarge;

        for (n.candidates) |c| {
            max_value_len = @max(max_value_len, std.math.cast(u32, c.len) orelse
                return error.ValueTooLong);
            try strings.appendSlice(allocator, c);
            try strings.append(allocator, 0);
        }
        if (strings.items.len > std.math.maxInt(u16)) return error.StringsPoolTooLarge;

        normal_table[n.key] = .{
            .values_offset = @intCast(start_offset),
            .candidates_count = @intCast(n.candidates.len),
        };
    }

    // ---- Phase 3: emit paireds. ----
    for (paireds) |p| {
        max_value_len = @max(max_value_len, std.math.cast(u32, p.open.len) orelse
            return error.ValueTooLong);
        max_value_len = @max(max_value_len, std.math.cast(u32, p.close.len) orelse
            return error.ValueTooLong);

        const open_offset = strings.items.len;
        if (open_offset > std.math.maxInt(u16)) return error.StringsPoolTooLarge;
        try strings.appendSlice(allocator, p.open);
        try strings.append(allocator, 0);

        const close_offset = strings.items.len;
        if (close_offset > std.math.maxInt(u16)) return error.StringsPoolTooLarge;
        try strings.appendSlice(allocator, p.close);
        try strings.append(allocator, 0);
        if (strings.items.len > std.math.maxInt(u16)) return error.StringsPoolTooLarge;

        paired_table[p.key] = .{
            .open_offset = @intCast(open_offset),
            .close_offset = @intCast(close_offset),
        };
    }

    // ---- Phase 4: assemble the blob. ----
    const offsets = fmt.PoolOffsets.compute();
    const total = offsets.strings + strings.items.len;
    const buf = try allocator.alignedAlloc(u8, .@"4", total);
    @memset(buf, 0);

    const header = std.mem.bytesAsValue(fmt.Header, buf[0..@sizeOf(fmt.Header)]);
    header.* = .{
        .strings_total = @intCast(strings.items.len),
        .max_value_len = max_value_len,
    };

    {
        const dst: *[fmt.TABLE_SIZE]fmt.NormalEntry =
            @ptrCast(@alignCast(buf[offsets.normal_table..].ptr));
        dst.* = normal_table;
    }
    {
        const dst: *[fmt.TABLE_SIZE]fmt.PairedEntry =
            @ptrCast(@alignCast(buf[offsets.paired_table..].ptr));
        dst.* = paired_table;
    }

    @memcpy(buf[offsets.strings..][0..strings.items.len], strings.items);

    if (target_endian != builtin.cpu.arch.endian()) {
        byteSwapBlob(buf);
    }

    return buf;
}

/// Byte-swap every multi-byte field of the blob in place. Unlike the
/// trie blob, this format has no count-dependent section offsets — both
/// tables are fixed-size — so no `current_endian` argument is needed to
/// locate sections. Only u32/u16 fields are touched.
fn byteSwapBlob(buf: []align(4) u8) void {
    const offsets = fmt.PoolOffsets.compute();

    // Header: 2 u32 fields starting at offset 0.
    swap32At(buf, 0);
    swap32At(buf, 4);

    // Normal table: 256 entries × 2 u16 fields.
    var i: usize = 0;
    while (i < fmt.TABLE_SIZE) : (i += 1) {
        const off = offsets.normal_table + i * @sizeOf(fmt.NormalEntry);
        swap16At(buf, off);
        swap16At(buf, off + 2);
    }

    // Paired table: 256 entries × 2 u16 fields.
    i = 0;
    while (i < fmt.TABLE_SIZE) : (i += 1) {
        const off = offsets.paired_table + i * @sizeOf(fmt.PairedEntry);
        swap16At(buf, off);
        swap16At(buf, off + 2);
    }
}

inline fn swap32At(buf: []align(4) u8, offset: usize) void {
    const slot: *align(1) u32 = @ptrCast(buf[offset..].ptr);
    slot.* = @byteSwap(slot.*);
}

inline fn swap16At(buf: []align(4) u8, offset: usize) void {
    const slot: *align(1) u16 = @ptrCast(buf[offset..].ptr);
    slot.* = @byteSwap(slot.*);
}

/// Convenience for tests: build the blob and reinterpret it in one shot.
pub const PuncHandle = struct {
    bytes: []align(4) u8,
    punc: Punc,

    pub fn deinit(self: *PuncHandle, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub fn buildPunc(
    allocator: std.mem.Allocator,
    normals: []const NormalInput,
    paireds: []const PairedInput,
) !PuncHandle {
    const bytes = try buildBlob(allocator, normals, paireds, builtin.cpu.arch.endian());
    errdefer allocator.free(bytes);
    return .{ .bytes = bytes, .punc = try Punc.fromBytes(bytes) };
}

// =========================================================================
// Tests
// =========================================================================

test "empty blob roundtrips" {
    var ph = try buildPunc(testing.allocator, &.{}, &.{});
    defer ph.deinit(testing.allocator);

    for (0..256) |k| {
        try testing.expect(ph.punc.lookupNormal(@intCast(k)) == null);
        try testing.expect(ph.punc.lookupPaired(@intCast(k)) == null);
    }
}

test "single-candidate normal lookup" {
    const candidates = [_][]const u8{"。"};
    var ph = try buildPunc(testing.allocator, &.{
        .{ .key = '.', .candidates = &candidates },
    }, &.{});
    defer ph.deinit(testing.allocator);

    const entry = ph.punc.lookupNormal('.') orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u16, 1), entry.candidates_count);
    try testing.expectEqualStrings("。", std.mem.sliceTo(ph.punc.candidateAt(entry, 0), 0));
}

test "multi-candidate normal preserves source order" {
    const candidates = [_][]const u8{ "「", "【", "〔", "［" };
    var ph = try buildPunc(testing.allocator, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer ph.deinit(testing.allocator);

    const entry = ph.punc.lookupNormal('[') orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u16, 4), entry.candidates_count);
    try testing.expectEqualStrings("「", std.mem.sliceTo(ph.punc.candidateAt(entry, 0), 0));
    try testing.expectEqualStrings("【", std.mem.sliceTo(ph.punc.candidateAt(entry, 1), 0));
    try testing.expectEqualStrings("〔", std.mem.sliceTo(ph.punc.candidateAt(entry, 2), 0));
    try testing.expectEqualStrings("［", std.mem.sliceTo(ph.punc.candidateAt(entry, 3), 0));
}

test "paired stores both halves" {
    var ph = try buildPunc(testing.allocator, &.{}, &.{
        .{ .key = '"', .open = "“", .close = "”" },
    });
    defer ph.deinit(testing.allocator);

    const entry = ph.punc.lookupPaired('"') orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("“", std.mem.sliceTo(ph.punc.openValue(entry), 0));
    try testing.expectEqualStrings("”", std.mem.sliceTo(ph.punc.closeValue(entry), 0));
}

test "missing keys yield null lookups" {
    const candidates = [_][]const u8{"。"};
    var ph = try buildPunc(testing.allocator, &.{
        .{ .key = '.', .candidates = &candidates },
    }, &.{
        .{ .key = '"', .open = "“", .close = "”" },
    });
    defer ph.deinit(testing.allocator);

    try testing.expect(ph.punc.lookupNormal('x') == null);
    try testing.expect(ph.punc.lookupPaired('x') == null);
    // Normal key has no paired entry, and vice versa.
    try testing.expect(ph.punc.lookupPaired('.') == null);
    try testing.expect(ph.punc.lookupNormal('"') == null);
}

test "paired offset 0 is reserved (sentinel works for offset 0 byte)" {
    // Build a blob with only paired entries. The first paired entry's
    // open_offset must be >= 1 because the generator reserves offset 0.
    var ph = try buildPunc(testing.allocator, &.{}, &.{
        .{ .key = '"', .open = "“", .close = "”" },
    });
    defer ph.deinit(testing.allocator);

    const entry = ph.punc.lookupPaired('"') orelse return error.TestUnexpectedNull;
    try testing.expect(entry.open_offset >= 1);
}

test "max_value_len covers normals and both paired halves" {
    const candidates = [_][]const u8{ "。", "……" }; // 3 and 6 bytes
    var ph = try buildPunc(testing.allocator, &.{
        .{ .key = '.', .candidates = &candidates },
    }, &.{
        .{ .key = '"', .open = "“", .close = "”" }, // 3 bytes each
    });
    defer ph.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 6), ph.punc.max_value_len);
}

test "buildBlob produces byte-swapped output for cross-endian targets" {
    const host = builtin.cpu.arch.endian();
    const opposite: std.builtin.Endian = switch (host) {
        .little => .big,
        .big => .little,
    };

    const candidates = [_][]const u8{ "。", "，" };
    const normals = [_]NormalInput{.{ .key = '.', .candidates = &candidates }};
    const paireds = [_]PairedInput{.{ .key = '"', .open = "“", .close = "”" }};

    const native = try buildBlob(testing.allocator, &normals, &paireds, host);
    defer testing.allocator.free(native);

    const swapped = try buildBlob(testing.allocator, &normals, &paireds, opposite);
    defer testing.allocator.free(swapped);

    try testing.expectEqual(native.len, swapped.len);

    // Header's u32 byte-reversed.
    var native_first: [4]u8 = native[0..4].*;
    std.mem.reverse(u8, &native_first);
    try testing.expectEqualSlices(u8, &native_first, swapped[0..4]);

    // Swap back; bit-identical to native.
    byteSwapBlob(swapped);
    try testing.expectEqualSlices(u8, native, swapped);
}
