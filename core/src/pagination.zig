const std = @import("std");
const testing = std.testing;

const Node = @import("./trie.zig").Node;
const numberToAlphabet = @import("./trie.zig").numberToAlphabet;
const trie_children_width = @import("./trie.zig").WIDTH;
const generateTestTrie = @import("./trie_test_data.zig").generateTestTrie;

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
            std.debug.print("The `hint` field is expect not to be null but actully is.\n", .{});
            return error.TestExpectedEqual;
        }
    } else {
        if (actual.hint) |_| {
            std.debug.print("The `hint` field is expect to be null but actuall is not.\n", .{});
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

pub const NodePagination = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    node: *const Node,
    page_size: u8,
    total_pages: u32,
    current_page: u32,
    pages: []?[]const QueryOption,
    /// The path of indexes to the current page's trie node.
    cursors: std.ArrayList(u8),
    /// The number of padding items before the current page's first item.
    cursor_left_paddings: u8,

    pub fn init(allocator: std.mem.Allocator, node: *const Node, page_size: u8) Self {
        const total_pages: u32 = blk: {
            if (node.count % page_size == 0) {
                break :blk node.count / page_size;
            } else {
                break :blk node.count / page_size + 1;
            }
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        var cursors = std.ArrayList(u8).init(allocator);
        var pages = arena.allocator().alloc(?[]const QueryOption, total_pages) catch unreachable;

        for (0..total_pages) |i| {
            pages[i] = null;
        }

        return .{
            .arena = arena,
            .node = node,
            .page_size = page_size,
            .total_pages = total_pages,
            .current_page = 1,
            .pages = pages,
            .cursors = cursors,
            .cursor_left_paddings = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cursors.deinit();
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
        // calculate current page's query options if it is not calculated.
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
                const last_page_size = self.node.count % self.page_size;

                if (last_page_size != 0) {
                    break :get_options_len last_page_size;
                }
            }

            break :get_options_len self.page_size;
        };
        var options = allocator.alloc(QueryOption, options_len) catch unreachable;

        var trie_node = self.node;

        for (self.cursors.items) |i| {
            trie_node = trie_node.children[i].?;
        }

        var inserted_options_count: u32 = 0;

        insert_options: {
            process_one_node: while (true) {
                // lazy init hint
                // if the whole for loop is skipped,
                // the hint will not be initialized.
                var hint: ?[*:0]const u8 = null;

                for (trie_node.values, 0..) |value, value_index| {
                    if (value_index < self.cursor_left_paddings) {
                        continue;
                    } else {
                        if (hint == null and self.cursors.items.len != 0) {
                            var real_hint = allocator.allocSentinel(u8, self.cursors.items.len, 0) catch unreachable;
                            for (self.cursors.items, 0..) |i, j| {
                                real_hint[j] = numberToAlphabet(i);
                            }
                            hint = real_hint;
                        }

                        options[inserted_options_count] = .{
                            .value = value,
                            .hint = hint,
                        };
                    }

                    if (inserted_options_count == options_len - 1) {
                        self.cursor_left_paddings = @intCast(u8, value_index + 1);
                        break :insert_options;
                    } else {
                        inserted_options_count += 1;
                    }
                }

                // If we reach here, it means we have exhausted all values in this node.
                // Now let's go to the next sibling of the node.
                // If it's already the last sibling,
                // then we go to the first child of the next sibling of the parent node.
                // If all of ancestors of the current node are the last sibling,
                // then we go to the next level of the trie,
                // aka the first child of first sibling of the current node.
                while (true) {
                    trieCursorsGoNext(&self.cursors, 0);

                    var p = self.node;
                    access_trie_from_cursors: while (true) {
                        p = self.node;
                        for (self.cursors.items, 0..) |i, j| {
                            if (p.children[i]) |node| {
                                p = node;
                            } else {
                                // if we reach here, means the current trie is null,
                                // and there is no children in it,
                                // so we can simply skip to next sibling of the current trie.
                                trieCursorsGoNext(&self.cursors, @intCast(u8, self.cursors.items.len - j - 1));
                                continue :access_trie_from_cursors;
                            }
                        }
                        break :access_trie_from_cursors;
                    }

                    trie_node = p;
                    self.cursor_left_paddings = 0;
                    continue :process_one_node;
                }
            }
        }

        return options;
    }
};

/// Go to the next node in the trie.
/// `depth` means which node is the next node relative to.
/// `depth` = 0 means the current node,
/// `depth` = 1 means the parent node of the current node,
/// `depth` = 2 means the grandparent node of the current node,
/// and so on.
fn trieCursorsGoNext(cursors: *std.ArrayList(u8), depth: u8) void {
    if (cursors.items.len == 0) {
        cursors.append(0) catch unreachable;
    } else {
        var should_goto_next_level = true;
        var ancestors_count: u8 = 0;

        // find the first ancestor that is not the last sibling
        find_first_ancestor: while (cursors.items.len - ancestors_count - depth > 0) {
            ancestors_count += 1;

            if (cursors.items[cursors.items.len - ancestors_count - depth] < trie_children_width - 1) {
                should_goto_next_level = false;
                break :find_first_ancestor;
            }
        }

        if (should_goto_next_level) {
            @memset(cursors.items, 0);
            cursors.append(0) catch unreachable;
        } else {
            cursors.items[cursors.items.len - ancestors_count - depth] += 1;
            for ((cursors.items.len - ancestors_count - depth + 1)..cursors.items.len) |i| {
                cursors.items[i] = 0;
            }
        }
    }
}

test "empty cursors should append `0`" {
    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    trieCursorsGoNext(&input, 0);

    const expected = [_]u8{0};

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next" {
    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{ 1, 2, 3, 4 });
    trieCursorsGoNext(&input, 0);

    const expected = [_]u8{ 1, 2, 3, 5 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next sibling" {
    const max = trie_children_width - 1;

    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{ 1, 2, 3, max });
    trieCursorsGoNext(&input, 0);

    const expected = [_]u8{ 1, 2, 4, 0 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next sibling 2" {
    const max = trie_children_width - 1;

    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{ 1, 2, max, max });
    trieCursorsGoNext(&input, 0);

    const expected = [_]u8{ 1, 3, 0, 0 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next level" {
    const max = trie_children_width - 1;

    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{max});
    trieCursorsGoNext(&input, 0);

    const expected = [_]u8{ 0, 0 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next level 2" {
    const max = trie_children_width - 1;

    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{ max, max, max });
    trieCursorsGoNext(&input, 1);

    const expected = [_]u8{ 0, 0, 0, 0 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next with depth 1" {
    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{ 1, 2, 3, 4 });
    trieCursorsGoNext(&input, 1);

    const expected = [_]u8{ 1, 2, 4, 0 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next sibling with depth 1" {
    const max = trie_children_width - 1;

    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{ 1, 2, max, 3 });
    trieCursorsGoNext(&input, 1);

    const expected = [_]u8{ 1, 3, 0, 0 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next sibling 2 with depth 1" {
    const max = trie_children_width - 1;

    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{ 1, max, max, 2 });
    trieCursorsGoNext(&input, 1);

    const expected = [_]u8{ 2, 0, 0, 0 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next level with depth 1" {
    const max = trie_children_width - 1;

    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{ max, 1 });
    trieCursorsGoNext(&input, 2);

    const expected = [_]u8{ 0, 0, 0 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "trie cursors go next level 1" {
    const max = trie_children_width - 1;

    var input = std.ArrayList(u8).init(testing.allocator);
    defer input.deinit();
    try input.appendSlice(&.{ max, max, max, 1 });
    trieCursorsGoNext(&input, 1);

    const expected = [_]u8{ 0, 0, 0, 0, 0 };

    try testing.expectEqualSlices(u8, &expected, input.items);
}

test "page count is correct" {
    const node = comptime generateTestTrie();
    var node_pagination = NodePagination.init(testing.allocator, &node, 8);
    defer node_pagination.deinit();

    try testing.expectEqual(node_pagination.total_pages, 2);
}

test "work properly with simple pagination" {
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 8);
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
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 3);
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
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 3);
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
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 3);
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
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 3);
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
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 3);
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
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 3);
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
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 3);
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
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 1);
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
    const root_node = comptime generateTestTrie();
    const node = root_node.get_child('a').?;
    var node_pagination = NodePagination.init(testing.allocator, node, 16);
    defer node_pagination.deinit();

    const expected_total_pages: u32 = 1;
    try testing.expectEqual(expected_total_pages, node_pagination.total_pages);

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
    comptime var root_node = Node.init();

    comptime root_node.add("a", "甲");
    comptime root_node.add("ab", "乙");
    comptime root_node.add("ac", "丙");
    comptime root_node.add("ad", "丁");
    comptime root_node.add("ae", "Foo");
    comptime root_node.add("afj", "Bar");
    comptime root_node.add("abcde", "Hello");
    comptime root_node.add("asdfghjkl", "World");

    comptime root_node.calculateCount();

    const node = root_node.get_child('a').?;

    var node_pagination = NodePagination.init(testing.allocator, node, 3);
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
