//! Exposes the punctuation-marks table data as a raw blob of bytes.
//!
//! The blob is built at build time by `scripts/gen_punc.zig` (driven by
//! `build.zig`) from `src/punctuation-marks/*.txt`. At runtime, `jd_init`
//! calls `punc.Punc.fromBytes(blob_bytes)` to reinterpret the embedded
//! bytes as a `Punc` view in O(1) — no parsing, no copying.

const punc_blob = @import("punc_blob");

/// 4-byte-aligned slice into the embedded blob. The alignment is set by
/// the generator-emitted wrapper module that does the `@embedFile`.
pub const blob_bytes: []align(4) const u8 = &punc_blob.bytes;
