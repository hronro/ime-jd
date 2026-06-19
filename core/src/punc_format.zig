//! On-disk format for the build-time-generated punctuation-marks blob.
//!
//! Mirrors `blob_format.zig` in spirit but describes a separate data
//! structure: two 256-entry inline tables (one for normal, one for paired)
//! indexed directly by ASCII byte, plus a shared strings pool.
//!
//! The generator (`scripts/gen_punc.zig`) emits a contiguous byte buffer in
//! this layout; the runtime (`punc.zig`) reinterprets that buffer in place
//! via `@ptrCast`. Both ends share this definition.
//!
//! Cross-platform notes:
//!   - All multi-byte integers are stored in **target** endianness.
//!     `gen_punc.zig` runs on the host; when target endianness differs,
//!     `punc.buildBlob` byte-swaps the relevant fields after construction.
//!   - `extern struct` everywhere so field order/padding is guaranteed.
//!   - Offsets into the strings pool are `u16` — strings totals are far
//!     below 64 KiB for any realistic punctuation set.

const std = @import("std");

/// 4-byte fixed header at offset 0 of the blob.
///
/// No magic/version fields, matching `blob_format.Header`: blob is
/// regenerated from source every build, so generator and runtime are
/// always in lockstep.
pub const Header = extern struct {
    strings_total: u32,
};

/// 4-byte entry for one row of `normal.txt`. There is exactly one slot
/// per ASCII byte (256 total); empty slots have `candidates_count == 0`.
///
/// When `candidates_count > 0`, the candidate values live as
/// `candidates_count` consecutive NUL-terminated UTF-8 strings starting
/// at `strings[values_offset]`.
pub const NormalEntry = extern struct {
    values_offset: u16,
    candidates_count: u16,

    pub inline fn isPresent(self: *const NormalEntry) bool {
        return self.candidates_count != 0;
    }
};

/// 4-byte entry for one row of `paired.txt`. There is exactly one slot
/// per ASCII byte; empty slots have `open_offset == 0`.
///
/// The generator reserves offset 0 in the strings pool (an unused NUL
/// byte) so `open_offset == 0` reliably means "no entry" — real entries
/// always live at offset ≥ 1.
///
/// The toggle bit for a paired entry is indexed by its key directly
/// (see `Context.pair_toggle_bits`); no separate pair_id field is needed.
pub const PairedEntry = extern struct {
    open_offset: u16,
    close_offset: u16,

    pub inline fn isPresent(self: *const PairedEntry) bool {
        return self.open_offset != 0;
    }
};

/// Both lookup tables are always exactly 256 slots — direct ASCII-byte
/// indexing, no prefix-sum.
pub const TABLE_SIZE: usize = 256;

/// Pool offsets within the blob. Used by both the generator (to know
/// where to write each pool) and the runtime (to know where to read).
///
/// All sections are fixed-size except `strings`. Both tables are
/// 256 × 4 B = 1024 B. No padding needed: Header is 4-aligned, NormalEntry
/// has 2-byte natural alignment, PairedEntry the same, strings is 1-aligned.
pub const PoolOffsets = struct {
    normal_table: usize,
    paired_table: usize,
    strings: usize,

    pub fn compute() PoolOffsets {
        const normal_table = @sizeOf(Header);
        const paired_table = normal_table + TABLE_SIZE * @sizeOf(NormalEntry);
        const strings = paired_table + TABLE_SIZE * @sizeOf(PairedEntry);
        return .{
            .normal_table = normal_table,
            .paired_table = paired_table,
            .strings = strings,
        };
    }
};

/// Total blob size for a given strings-pool length.
pub fn blobSize(strings_total: usize) usize {
    return @sizeOf(Header) +
        TABLE_SIZE * @sizeOf(NormalEntry) +
        TABLE_SIZE * @sizeOf(PairedEntry) +
        strings_total;
}
