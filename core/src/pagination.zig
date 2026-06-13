const std = @import("std");
const testing = std.testing;

const trie_mod = @import("trie");
const Trie = trie_mod.Trie;
const Node = trie_mod.Trie.Node;
const TailLinkedList = @import("./tail_linked_list.zig").TailLinkedList;
const buildTestTrie = @import("./trie_test_data.zig").buildTestTrie;

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

const TLLNode = struct {
    hint: ?[*:0]const u8,
    node: *const Node,
};
const TLL = TailLinkedList(TLLNode);

pub const NodePagination = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    trie: *const Trie,
    node: *const Node,
    page_size: u8,
    total_pages: u32,
    current_page: u32,
    pages: []?[]const QueryOption,
    tail_linked_list: TLL,
    tll_node_skipped_options: u8,

    pub fn init(allocator: std.mem.Allocator, trie: *const Trie, node: *const Node, page_size: u8) Self {
        const total_pages: u32 = blk: {
            if (node.count() % page_size == 0) {
                break :blk node.count() / page_size;
            } else {
                break :blk node.count() / page_size + 1;
            }
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        const pages = arena.allocator().alloc(?[]const QueryOption, total_pages) catch unreachable;
        @memset(pages, null);
        var tail_linked_list = TLL{};
        const first_tll_node = arena.allocator().create(TLL.Node) catch unreachable;
        first_tll_node.*.data = .{
            .hint = null,
            .node = node,
        };
        tail_linked_list.append(first_tll_node);

        return .{
            .arena = arena,
            .trie = trie,
            .node = node,
            .page_size = page_size,
            .total_pages = total_pages,
            .current_page = 1,
            .pages = pages,
            .tail_linked_list = tail_linked_list,
            .tll_node_skipped_options = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn getOptions(self: *Self) []const QueryOption {
        if (self.pages[self.current_page - 1]) |options| {
            return options;
        } else {
            const options = self.calculateQueryOptionsOfCurrentPage();
            self.pages[self.current_page - 1] = options;
            return options;
        }
    }

    pub fn nextPage(self: *Self) void {
        if (self.pages[self.current_page - 1] == null) {
            self.pages[self.current_page - 1] = self.calculateQueryOptionsOfCurrentPage();
        }

        if (self.current_page < self.total_pages) {
            self.current_page += 1;
        }
    }

    pub fn prevPage(self: *Self) void {
        if (self.current_page > 1) {
            self.current_page -= 1;
        }
    }

    fn calculateQueryOptionsOfCurrentPage(self: *Self) []QueryOption {
        const allocator = self.arena.allocator();

        const options_len = get_options_len: {
            if (self.current_page == self.total_pages) {
                const last_page_size = self.node.count() % self.page_size;

                if (last_page_size != 0) {
                    break :get_options_len last_page_size;
                }
            }

            break :get_options_len self.page_size;
        };
        var options = allocator.alloc(QueryOption, options_len) catch unreachable;

        var inserted_options_count: u32 = 0;

        while (inserted_options_count < options.len) {
            const tll_node = self.tail_linked_list.first.?;

            const node = tll_node.*.data.node;
            const hint = tll_node.*.data.hint;

            if (self.tll_node_skipped_options == 0) {
                for (0..node.getWidth()) |i| {
                    if (node.getChildByIndex(self.trie, i)) |child| {
                        const new_tll_node = allocator.create(TLL.Node) catch unreachable;
                        const key = node.keyOfChildByIndex(self.trie, i).?;

                        const new_hint = gen_new_hint: {
                            if (hint) |old_hint| {
                                const old_hint_len = std.mem.len(old_hint);
                                var new_hint = allocator.allocSentinel(u8, old_hint_len + 1, 0) catch unreachable;
                                @memcpy(new_hint[0..old_hint_len], old_hint[0..old_hint_len]);
                                new_hint[old_hint_len] = key;
                                break :gen_new_hint new_hint;
                            } else {
                                var new_hint = allocator.allocSentinel(u8, 1, 0) catch unreachable;
                                new_hint[0] = key;
                                break :gen_new_hint new_hint;
                            }
                        };

                        new_tll_node.*.data = .{
                            .hint = new_hint,
                            .node = child,
                        };
                        self.tail_linked_list.append(new_tll_node);
                    }
                }

                if (node.values(self.trie).len() == 0) {
                    const removed_tll_node = self.tail_linked_list.popFirst().?;
                    allocator.destroy(removed_tll_node);
                    continue;
                }
            }

            const node_values = node.values(self.trie);
            const value = node_values.at(self.tll_node_skipped_options);
            options[inserted_options_count] = .{
                .hint = hint,
                .value = value.ptr,
            };

            self.tll_node_skipped_options += 1;
            inserted_options_count += 1;

            if (self.tll_node_skipped_options == node_values.len()) {
                const removed_tll_node = self.tail_linked_list.popFirst().?;
                allocator.destroy(removed_tll_node);
                self.tll_node_skipped_options = 0;
            }
        }

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
