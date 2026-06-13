const std = @import("std");
const testing = std.testing;

const trie_mod = @import("trie");
const Trie = trie_mod.Trie;
const Node = trie_mod.Trie.Node;
const buildTestTrie = @import("./trie_test_data.zig").buildTestTrie;

const ArrayList = std.ArrayList;

pub const QueryOption = extern struct {
    value: [*:0]const u8,
    hint: ?[*:0]const u8,
};

pub fn expectEqualQueryOption(expected: QueryOption, actual: QueryOption) !void {
    const expected_value_len = std.mem.len(expected.value);
    const actual_value_len = std.mem.len(actual.value);
    if (expected_value_len != actual_value_len) {
        std.debug.print("The length of `value` field is not equal: {d} != {d}\n", .{ expected_value_len, actual_value_len });
        return error.TestExpectedEqual;
    }

    const expected_value = expected.value[0..expected_value_len];
    const actual_value = actual.value[0..actual_value_len];
    if (!std.mem.eql(u8, expected_value, actual_value)) {
        std.debug.print("The `value` field is not equal: \"{s}\" != \"{s}\"\n", .{ expected_value, actual_value });
        return error.TestExpectedEqual;
    }

    if (expected.hint) |eh| {
        if (actual.hint) |ah| {
            const expected_hint_len = std.mem.len(eh);
            const actual_hint_len = std.mem.len(ah);
            if (expected_hint_len != actual_hint_len) {
                std.debug.print("The length of `hint` field is not equal: {d} != {d}\n", .{ expected_hint_len, actual_hint_len });
                return error.TestExpectedEqual;
            }

            const expected_hint = eh[0..expected_hint_len];
            const actual_hint = ah[0..actual_hint_len];
            if (!std.mem.eql(u8, expected_hint, actual_hint)) {
                std.debug.print("The `hint` field is not equal: \"{s}\" != \"{s}\"\n", .{ expected_hint, actual_hint });
                return error.TestExpectedEqual;
            }
        } else {
            std.debug.print("The `hint` field is expected not to be null but actually is.\n", .{});
            return error.TestExpectedEqual;
        }
    } else {
        if (actual.hint) |_| {
            std.debug.print("The `hint` field is expected to be null but actually is not.\n", .{});
            return error.TestExpectedEqual;
        }
    }
}

pub fn expectEqualQueryOptionSlice(expected: []const QueryOption, actual: []const QueryOption) !void {
    if (expected.len != actual.len) {
        std.debug.print("The length of slice is not equal: {d} != {d}\n", .{ expected.len, actual.len });
        return error.TestExpectedEqual;
    }

    for (expected, actual, 0..) |expected_item, actual_item, index| {
        expectEqualQueryOption(expected_item, actual_item) catch |e| {
            std.debug.print("The {d}th item is not equal.\n", .{index + 1});
            return e;
        };
    }
}

pub fn expectEqualQueryOptionManyItemPtr(expected: [*]const QueryOption, actual: [*]const QueryOption, len: u8) !void {
    for (0..len) |index| {
        expectEqualQueryOption(expected[index], actual[index]) catch |e| {
            std.debug.print("The {d}th item is not equal.\n", .{index + 1});
            return e;
        };
    }
}

/// One entry in the BFS frontier. `path_start`/`path_len` index into the
/// shared `path_buf`, giving the key sequence from the queried start node
/// down to this entry's node. Hint strings are materialized on demand from
/// this path when a value is emitted.
const FrontierEntry = struct {
    node: *const Node,
    path_start: u32,
    path_len: u8,
};

/// Lazy paginator over the values reachable from a given trie node, in BFS
/// order (shorter completions first, ties broken by `keyRank`).
///
/// Design: pagination state is a single forward-only BFS cursor plus the
/// most-recently-materialized page. `nextPage`/`prevPage` are pure integer
/// bumps on `current_page`; all real work happens lazily in `getOptions`.
/// If the user navigates backwards, the cursor is rewound and replayed from
/// the start. The replay cost is O(current_page × page_size), which is
/// invisible at IME interaction speeds.
pub const NodePagination = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    /// Backs the materialized current page (options array + hint strings).
    /// Reset before each materialization, so old page memory is reclaimed.
    page_arena: std.heap.ArenaAllocator,

    trie: *const Trie,
    start_node: *const Node,
    page_size: u8,
    total_pages: u32,
    current_page: u32,

    /// BFS cursor — together (frontier, frontier_head, skipped) identify
    /// the next value to emit. `bfs_page` is the page that the cursor will
    /// emit next.
    bfs_page: u32,
    frontier: ArrayList(FrontierEntry),
    frontier_head: usize,
    path_buf: ArrayList(u8),
    skipped: u8,

    /// Cached page contents for `cached_page`, allocated in `page_arena`.
    /// `cached_page == 0` means no page is currently materialized.
    cached_options: []QueryOption,
    cached_page: u32,

    pub fn init(allocator: std.mem.Allocator, trie: *const Trie, node: *const Node, page_size: u8) Self {
        const total_pages: u32 = (node.count() + page_size - 1) / page_size;
        var frontier: ArrayList(FrontierEntry) = .empty;
        frontier.append(allocator, .{
            .node = node,
            .path_start = 0,
            .path_len = 0,
        }) catch unreachable;
        return .{
            .allocator = allocator,
            .page_arena = std.heap.ArenaAllocator.init(allocator),
            .trie = trie,
            .start_node = node,
            .page_size = page_size,
            .total_pages = total_pages,
            .current_page = 1,
            .bfs_page = 1,
            .frontier = frontier,
            .frontier_head = 0,
            .path_buf = .empty,
            .skipped = 0,
            .cached_options = &.{},
            .cached_page = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.frontier.deinit(self.allocator);
        self.path_buf.deinit(self.allocator);
        self.page_arena.deinit();
    }

    pub fn nextPage(self: *Self) void {
        if (self.current_page < self.total_pages) self.current_page += 1;
    }

    pub fn prevPage(self: *Self) void {
        if (self.current_page > 1) self.current_page -= 1;
    }

    pub fn getOptions(self: *Self) []const QueryOption {
        if (self.cached_page == self.current_page) return self.cached_options;

        if (self.current_page < self.bfs_page) self.rewindBFS();
        while (self.bfs_page < self.current_page) self.skipOnePage();

        _ = self.page_arena.reset(.retain_capacity);
        self.cached_options = self.materializeOnePage();
        self.cached_page = self.current_page;
        return self.cached_options;
    }

    fn rewindBFS(self: *Self) void {
        self.frontier.clearRetainingCapacity();
        self.path_buf.clearRetainingCapacity();
        self.frontier.append(self.allocator, .{
            .node = self.start_node,
            .path_start = 0,
            .path_len = 0,
        }) catch unreachable;
        self.frontier_head = 0;
        self.skipped = 0;
        self.bfs_page = 1;
    }

    fn pageOptionCount(self: *const Self, page: u32) u8 {
        if (page == self.total_pages) {
            const rem = self.start_node.count() % self.page_size;
            if (rem != 0) return @intCast(rem);
        }
        return self.page_size;
    }

    fn enqueueChildren(self: *Self, entry: FrontierEntry) void {
        const w = entry.node.getWidth();
        if (w == 0) return;
        // Reserve so the inner loop never reallocates — otherwise the
        // parent-path slice we re-read every iteration could be invalidated.
        self.path_buf.ensureUnusedCapacity(self.allocator, @as(usize, entry.path_len + 1) * w) catch unreachable;
        self.frontier.ensureUnusedCapacity(self.allocator, w) catch unreachable;
        for (0..w) |i| {
            const child = entry.node.getChildByIndex(self.trie, i).?;
            const key = entry.node.keyOfChildByIndex(self.trie, i).?;
            const child_path_start: u32 = @intCast(self.path_buf.items.len);
            const parent_path = self.path_buf.items[entry.path_start..][0..entry.path_len];
            self.path_buf.appendSliceAssumeCapacity(parent_path);
            self.path_buf.appendAssumeCapacity(key);
            self.frontier.appendAssumeCapacity(.{
                .node = child,
                .path_start = child_path_start,
                .path_len = entry.path_len + 1,
            });
        }
    }

    /// Consume one value from the BFS cursor. If `emit_to` is non-null, the
    /// value is materialized as a `QueryOption` allocated in that allocator
    /// (with a freshly-allocated hint copy). Otherwise the value is skipped.
    fn consumeOne(self: *Self, emit_to: ?std.mem.Allocator) ?QueryOption {
        while (true) {
            // Copy by value — `enqueueChildren` may reallocate `frontier`.
            const entry = self.frontier.items[self.frontier_head];
            const values = entry.node.values(self.trie);

            if (self.skipped == 0) {
                self.enqueueChildren(entry);
                if (values.len() == 0) {
                    self.frontier_head += 1;
                    continue;
                }
            }

            const value = values.at(self.skipped);
            const opt: ?QueryOption = if (emit_to) |alloc| blk: {
                const hint: ?[*:0]const u8 = if (entry.path_len == 0) null else h: {
                    const path = self.path_buf.items[entry.path_start..][0..entry.path_len];
                    const buf = alloc.allocSentinel(u8, entry.path_len, 0) catch unreachable;
                    @memcpy(buf, path);
                    break :h buf.ptr;
                };
                break :blk .{ .value = value.ptr, .hint = hint };
            } else null;

            self.skipped += 1;
            if (self.skipped == values.len()) {
                self.frontier_head += 1;
                self.skipped = 0;
            }
            return opt;
        }
    }

    fn skipOnePage(self: *Self) void {
        const n = self.pageOptionCount(self.bfs_page);
        for (0..n) |_| _ = self.consumeOne(null);
        self.bfs_page += 1;
    }

    fn materializeOnePage(self: *Self) []QueryOption {
        const page_alloc = self.page_arena.allocator();
        const n = self.pageOptionCount(self.current_page);
        const options = page_alloc.alloc(QueryOption, n) catch unreachable;
        for (0..n) |i| options[i] = self.consumeOne(page_alloc).?;
        self.bfs_page += 1;
        return options;
    }
};

// =========================================================================
// Tests
// =========================================================================

test "page count is correct" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, th.trie.root(), 8);
    defer node_pagination.deinit();

    try testing.expectEqual(node_pagination.total_pages, 2);
}

test "work properly with simple pagination" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 8);
    defer node_pagination.deinit();

    const options = node_pagination.getOptions();

    var expected = [_]QueryOption{
        .{ .value = "甲", .hint = null },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙1", .hint = "c" },
        .{ .value = "丙2", .hint = "c" },
        .{ .value = "Foo", .hint = "e" },
        .{ .value = "Bar", .hint = "f" },
        .{ .value = "丁1", .hint = "cd" },
        .{ .value = "丁2", .hint = "cd" },
    };

    try expectEqualQueryOptionSlice(expected[0..], options);
}

test "work properly with small page size" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 3);
    defer node_pagination.deinit();

    const options = node_pagination.getOptions();

    var expected = [_]QueryOption{
        .{ .value = "甲", .hint = null },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙1", .hint = "c" },
    };

    try expectEqualQueryOptionSlice(expected[0..], options);
}

test "next page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 3);
    defer node_pagination.deinit();

    node_pagination.nextPage();
    const options = node_pagination.getOptions();

    var expected = [_]QueryOption{
        .{ .value = "丙2", .hint = "c" },
        .{ .value = "Foo", .hint = "e" },
        .{ .value = "Bar", .hint = "f" },
    };

    try expectEqualQueryOptionSlice(expected[0..], options);
}

test "last page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 3);
    defer node_pagination.deinit();

    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    const options = node_pagination.getOptions();

    var expected = [_]QueryOption{
        .{ .value = "丁4", .hint = "ce" },
        .{ .value = "FooBar", .hint = "c;" },
    };

    try expectEqualQueryOptionSlice(expected[0..], options);
}

test "next page on last page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 3);
    defer node_pagination.deinit();

    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    const options = node_pagination.getOptions();

    var expected = [_]QueryOption{
        .{ .value = "丁4", .hint = "ce" },
        .{ .value = "FooBar", .hint = "c;" },
    };

    try expectEqualQueryOptionSlice(expected[0..], options);
}

test "back and forth" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 3);
    defer node_pagination.deinit();

    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.prevPage();
    node_pagination.prevPage();
    node_pagination.nextPage();
    node_pagination.prevPage();
    const options = node_pagination.getOptions();

    var expected = [_]QueryOption{
        .{ .value = "丙2", .hint = "c" },
        .{ .value = "Foo", .hint = "e" },
        .{ .value = "Bar", .hint = "f" },
    };

    try expectEqualQueryOptionSlice(expected[0..], options);
}

test "back and forth 2" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 3);
    defer node_pagination.deinit();

    node_pagination.nextPage();
    node_pagination.prevPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    const options = node_pagination.getOptions();

    var expected = [_]QueryOption{
        .{ .value = "丁1", .hint = "cd" },
        .{ .value = "丁2", .hint = "cd" },
        .{ .value = "丁3", .hint = "cd" },
    };

    try expectEqualQueryOptionSlice(expected[0..], options);
}

test "back and forth to the first page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 3);
    defer node_pagination.deinit();

    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.prevPage();
    node_pagination.prevPage();
    node_pagination.nextPage();
    node_pagination.prevPage();
    node_pagination.prevPage();
    const options = node_pagination.getOptions();

    var expected = [_]QueryOption{
        .{ .value = "甲", .hint = null },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙1", .hint = "c" },
    };

    try expectEqualQueryOptionSlice(expected[0..], options);
}

test "page size is 1" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 1);
    defer node_pagination.deinit();

    const expected_total_pages: u32 = 11;
    try testing.expectEqual(expected_total_pages, node_pagination.total_pages);

    const options1 = node_pagination.getOptions();
    var expected1 = [_]QueryOption{
        .{ .value = "甲", .hint = null },
    };
    try expectEqualQueryOptionSlice(expected1[0..], options1);

    node_pagination.nextPage();
    const options2 = node_pagination.getOptions();
    var expected2 = [_]QueryOption{
        .{ .value = "乙", .hint = "b" },
    };
    try expectEqualQueryOptionSlice(expected2[0..], options2);

    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    node_pagination.nextPage();
    const options_last = node_pagination.getOptions();
    var expected_last = [_]QueryOption{
        .{ .value = "丁4", .hint = "ce" },
    };
    try expectEqualQueryOptionSlice(expected_last[0..], options_last);
}

test "page size is larger than the length of all options" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 16);
    defer node_pagination.deinit();

    try testing.expectEqual(@as(u32, 1), node_pagination.total_pages);

    const options = node_pagination.getOptions();
    var expected = [_]QueryOption{
        .{ .value = "甲", .hint = null },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙1", .hint = "c" },
        .{ .value = "丙2", .hint = "c" },
        .{ .value = "Foo", .hint = "e" },
        .{ .value = "Bar", .hint = "f" },
        .{ .value = "丁1", .hint = "cd" },
        .{ .value = "丁2", .hint = "cd" },
        .{ .value = "丁3", .hint = "cd" },
        .{ .value = "丁4", .hint = "ce" },
        .{ .value = "FooBar", .hint = "c;" },
    };
    try expectEqualQueryOptionSlice(expected[0..], options);
}

test "deep nodes" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "甲" },
        .{ .keys = "ab", .value = "乙" },
        .{ .keys = "ac", .value = "丙" },
        .{ .keys = "ad", .value = "丁" },
        .{ .keys = "ae", .value = "Foo" },
        .{ .keys = "afj", .value = "Bar" },
        .{ .keys = "abcde", .value = "Hello" },
        .{ .keys = "asdfghjkl", .value = "World" },
    });
    defer th.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var node_pagination = NodePagination.init(testing.allocator, &th.trie, node, 3);
    defer node_pagination.deinit();

    const options1 = node_pagination.getOptions();
    var expected1 = [_]QueryOption{
        .{ .value = "甲", .hint = null },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙", .hint = "c" },
    };
    try expectEqualQueryOptionSlice(expected1[0..], options1);

    node_pagination.nextPage();
    const options2 = node_pagination.getOptions();
    var expected2 = [_]QueryOption{
        .{ .value = "丁", .hint = "d" },
        .{ .value = "Foo", .hint = "e" },
        .{ .value = "Bar", .hint = "fj" },
    };
    try expectEqualQueryOptionSlice(expected2[0..], options2);

    node_pagination.nextPage();
    const options3 = node_pagination.getOptions();
    var expected3 = [_]QueryOption{
        .{ .value = "Hello", .hint = "bcde" },
        .{ .value = "World", .hint = "sdfghjkl" },
    };
    try expectEqualQueryOptionSlice(expected3[0..], options3);
}
