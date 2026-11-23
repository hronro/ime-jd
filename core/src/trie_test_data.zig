//! Test fixture used by query.zig and pagination.zig.
//!
//! The old version chained `comptime root_node.add(...)` to build a trie at
//! comptime, which Zig 0.16's comptime rules forbid. The new version builds
//! the same trie at test runtime via `trie.buildTrie` — cheap (microseconds
//! for 11 entries) and lets us drop the dual compressed/dense loop the
//! original used (there's only one trie type now).

const std = @import("std");
const trie = @import("trie");

pub const test_entries = [_]trie.Entry{
    .{ .keys = "a", .value = "甲" },
    .{ .keys = "ab", .value = "乙" },
    .{ .keys = "ac", .value = "丙1" },
    .{ .keys = "ac", .value = "丙2" },
    .{ .keys = "acd", .value = "丁1" },
    .{ .keys = "acd", .value = "丁2" },
    .{ .keys = "acd", .value = "丁3" },
    .{ .keys = "ace", .value = "丁4" },
    .{ .keys = "acz", .value = "FooBar" },
    .{ .keys = "ae", .value = "Foo" },
    .{ .keys = "af", .value = "Bar" },
};

pub fn buildTestTrie(allocator: std.mem.Allocator) !trie.TrieHandle {
    return trie.buildTrie(allocator, &test_entries);
}
