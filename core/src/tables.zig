//! Exposes the table data as a raw blob of bytes.
//!
//! The blob is built at build time by `scripts/gen_trie.zig` (driven by
//! `build.zig`) from `src/tables/*.txt`. At runtime, `jd_init` calls
//! `trie.Trie.fromBytes(blob_bytes)` to reinterpret the embedded bytes as
//! a `Trie` view in O(1) — no parsing, no copying.

const trie_blob = @import("trie_blob");

/// 4-byte-aligned slice into the embedded blob. The alignment is set by
/// the generator-emitted wrapper module that does the `@embedFile`.
pub const blob_bytes: []align(4) const u8 = &trie_blob.bytes;
