//! Exposes the embedded dictionary as a raw blob of bytes.
//!
//! The blob is built at build time by `scripts/gen_trie.zig` (driven by
//! `build.zig`) from `tables/*.txt`, with the same builder a host uses at
//! runtime (`dict.build`). At runtime, `jd_init` calls
//! `trie.Trie.fromBytes(blob_bytes)` to reinterpret the embedded bytes as a
//! `Trie` view in O(1) — no parsing, no copying. A libjd built with
//! `-Dbuiltin_dict=false` (libjd-engine) embeds no blob at all.

const trie_blob = @import("trie_blob");

/// 4-byte-aligned slice into the embedded blob. The alignment is set by
/// the generator-emitted wrapper module that does the `@embedFile`. Empty
/// in a libjd without an embedded dictionary.
pub const blob_bytes: []align(4) const u8 = &trie_blob.bytes;

/// Whether this libjd embeds a dictionary.
pub const has_builtin = blob_bytes.len != 0;
