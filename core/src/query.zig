const std = @import("std");
const testing = std.testing;

const Node = @import("./trie.zig").Node;
const NodeInitOptions = @import("./trie.zig").NodeInitOptions;
const NodePagination = @import("./pagination.zig").NodePagination;
const QueryOption = @import("./pagination.zig").QueryOption;
const generateTestTrie = @import("./trie_test_data.zig").generateTestTrie;

const ArrayList = std.ArrayList;

pub fn InitOptions(comptime node_init_options: NodeInitOptions) type {
    return struct {
        root_node: *const Node(node_init_options),
        page_size: u8,
    };
}

pub const QueryResult = extern struct {
    commit: ?[*:0]const u8,
    options: ?[*]const QueryOption,
    options_count: u32,
    total_pages: u32,
    current_page: u32,
};

pub fn Context(comptime node_init_options: NodeInitOptions) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        commit_allocator: std.heap.ArenaAllocator,
        root_node: *const Node(node_init_options),
        page_size: u8,
        node: *const Node(node_init_options),
        pager: ?NodePagination(node_init_options),
        pressed_key_indexes: ArrayList(usize),

        pub fn init(allocator: std.mem.Allocator, options: InitOptions(node_init_options)) Self {
            return .{
                .allocator = allocator,
                .commit_allocator = std.heap.ArenaAllocator.init(allocator),
                .root_node = options.root_node,
                .page_size = options.page_size,
                .node = options.root_node,
                .pager = null,
                .pressed_key_indexes = ArrayList(usize).initCapacity(allocator, 6) catch unreachable,
            };
        }

        pub fn deinit(self: *Self) void {
            self.commit_allocator.deinit();
            if (self.pager) |*pager| {
                pager.*.deinit();
            }
            self.pressed_key_indexes.deinit();
        }

        pub fn reset(self: *Self) void {
            self.node = self.root_node;
            if (self.pager) |*pager| {
                pager.*.deinit();
            }
            self.pager = null;
            self.pressed_key_indexes.clearRetainingCapacity();
        }

        pub fn pressKey(self: *Self, key: u8) QueryResult {
            // free the previous commit.
            _ = self.commit_allocator.reset(.free_all);

            const allocator = self.commit_allocator.allocator();

            // If press space, commit the first option.
            // If there is no option, commit the space.
            if (key == ' ') {
                if (self.pager) |*pager| {
                    const options = pager.*.getOptions();

                    const commit = get_commit: {
                        if (options.len >= 1) {
                            const original_commit = std.mem.sliceTo(options[0].value, 0);
                            const commit = allocator.allocSentinel(u8, original_commit.len, 0) catch unreachable;
                            @memcpy(commit, original_commit);
                            break :get_commit commit;
                        } else {
                            const commit = allocator.allocSentinel(u8, 1, 0) catch unreachable;
                            commit[0] = ' ';
                            break :get_commit commit;
                        }
                    };

                    self.reset();

                    return .{
                        .commit = commit,
                        .options = null,
                        .options_count = 0,
                        .total_pages = 0,
                        .current_page = 0,
                    };
                } else {
                    const commit = allocator.allocSentinel(u8, 1, 0) catch unreachable;
                    commit[0] = ' ';

                    self.reset();

                    return .{
                        .commit = commit,
                        .options = null,
                        .options_count = 0,
                        .total_pages = 0,
                        .current_page = 0,
                    };
                }
            }

            // When press `;`, jump to the `;` child of the trie,
            // which is handled in the end of this function.
            // If the `;` child does not exist, select the 2nd option.
            // If the 2nd option does not exist,
            // commit the 1st option with `;` in the end.
            if (key == ';' and self.node.getChild(';') == null) {
                if (self.pager) |*pager| {
                    const options = pager.*.getOptions();

                    const commit = get_commit: {
                        if (options.len >= 2) {
                            const original_commit = std.mem.sliceTo(options[1].value, 0);
                            const commit = allocator.allocSentinel(u8, original_commit.len, 0) catch unreachable;
                            @memcpy(commit, original_commit);
                            break :get_commit commit;
                        } else {
                            const original_commit = std.mem.sliceTo(options[0].value, 0);
                            const commit = allocator.allocSentinel(u8, original_commit.len + 1, 0) catch unreachable;
                            @memcpy(commit[0..original_commit.len], original_commit);
                            commit[commit.len - 1] = ';';
                            break :get_commit commit;
                        }
                    };

                    self.reset();

                    return .{
                        .commit = commit,
                        .options = null,
                        .options_count = 0,
                        .total_pages = 0,
                        .current_page = 0,
                    };
                }
            }

            // User can press `1` to `9` to select an option.
            // If the option does not exist,
            // commit the first option with the key in the end,
            // which is handled in the end of this function.
            if (key >= '1' and key <= '9') {
                if (self.pager) |*pager| {
                    const options = pager.*.getOptions();
                    const option_index = key - '1';

                    if (option_index < options.len) {
                        const commit = get_commit: {
                            const original_commit = std.mem.sliceTo(options[option_index].value, 0);
                            const commit = allocator.allocSentinel(u8, original_commit.len, 0) catch unreachable;
                            @memcpy(commit, original_commit);
                            break :get_commit commit;
                        };

                        self.reset();

                        return .{
                            .commit = commit,
                            .options = null,
                            .options_count = 0,
                            .total_pages = 0,
                            .current_page = 0,
                        };
                    }
                }
            }

            if (self.node.getChild(key)) |node| {
                // If the node contains the key,
                // jump to the child with the key.

                const key_index = self.node.indexOfChild(key).?;

                self.node = node;
                if (self.pager) |*pager| {
                    pager.*.deinit();
                }
                self.pager = NodePagination(node_init_options).init(self.allocator, node, self.page_size);
                self.pressed_key_indexes.append(key_index) catch unreachable;

                const options = self.pager.?.getOptions();

                // If there is only one option,
                // and the option do not have a hint,
                // commit the option.
                if (options.len == 1 and options[0].hint == null) {
                    const original_commit = std.mem.sliceTo(options[0].value, 0);
                    const commit = allocator.allocSentinel(u8, original_commit.len, 0) catch unreachable;
                    @memcpy(commit, original_commit);

                    self.reset();

                    return .{
                        .commit = commit,
                        .options = null,
                        .options_count = 0,
                        .total_pages = 0,
                        .current_page = 0,
                    };
                }

                return .{
                    .commit = null,
                    .options = options.ptr,
                    .options_count = self.node.count,
                    .total_pages = self.pager.?.total_pages,
                    .current_page = 1,
                };
            } else if (self.root_node.getChild(key)) |node| {
                // if the node has no child with the key,
                // but the root node has a child with the key,
                // jump to the child of the root node,
                // and commit the first option of previous node.

                const prev_options = self.pager.?.getOptions();
                const prev_original_commit = std.mem.sliceTo(prev_options[0].value, 0);
                const prev_commit = allocator.allocSentinel(u8, prev_original_commit.len, 0) catch unreachable;
                @memcpy(prev_commit, prev_original_commit);

                self.node = node;
                self.pager.?.deinit();
                self.pager = NodePagination(node_init_options).init(self.allocator, node, self.page_size);
                self.pressed_key_indexes.clearRetainingCapacity();
                self.pressed_key_indexes.append(self.root_node.indexOfChild(key).?) catch unreachable;

                const options = self.pager.?.getOptions();

                // If there is only one option,
                // and the option do not have a hint,
                // commit the option with prev_commit in the start.
                if (options.len == 1 and options[0].hint == null) {
                    const original_commit = std.mem.sliceTo(options[0].value, 0);
                    const commit = allocator.allocSentinel(u8, prev_original_commit.len + original_commit.len, 0) catch unreachable;
                    @memcpy(commit[0..prev_commit.len], prev_commit);
                    @memcpy(commit[prev_commit.len..], original_commit);
                    allocator.free(prev_commit);

                    self.reset();

                    return .{
                        .commit = commit,
                        .options = null,
                        .options_count = 0,
                        .total_pages = 0,
                        .current_page = 0,
                    };
                }

                return .{
                    .commit = prev_commit,
                    .options = options.ptr,
                    .options_count = self.node.count,
                    .total_pages = self.pager.?.total_pages,
                    .current_page = 1,
                };
            }

            // When reaching here,
            // it means the key in not a letter,
            // or it's a letter but neither
            // the current node nor the root node has any child with that key.
            // If the current node is the root root, commit the key directly,
            // owtherwise, commit the first option of the current node with the key at the end.
            if (self.node == self.root_node) {
                const commit = allocator.allocSentinel(u8, 1, 0) catch unreachable;
                commit[0] = key;

                self.reset();

                return .{
                    .commit = commit,
                    .options = null,
                    .options_count = 0,
                    .total_pages = 0,
                    .current_page = 0,
                };
            } else {
                const options = self.pager.?.getOptions();
                const original_commit = std.mem.sliceTo(options[0].value, 0);
                const commit = allocator.allocSentinel(u8, original_commit.len + 1, 0) catch unreachable;
                @memcpy(commit[0..original_commit.len], original_commit);
                commit[commit.len - 1] = key;

                self.reset();

                return .{
                    .commit = commit,
                    .options = null,
                    .options_count = 0,
                    .total_pages = 0,
                    .current_page = 0,
                };
            }
        }

        pub fn nextPage(self: *Self) QueryResult {
            if (self.pager) |*pager| {
                pager.*.nextPage();

                return .{
                    .commit = null,
                    .options = pager.*.getOptions().ptr,
                    .options_count = self.node.count,
                    .total_pages = pager.*.total_pages,
                    .current_page = pager.*.current_page,
                };
            } else {
                // If haven't press any key yet,
                // aka the node is the root node,
                // aka the pager is null,
                // reutrn an empty QueryResult.
                return .{
                    .commit = null,
                    .options = null,
                    .options_count = 0,
                    .total_pages = 0,
                    .current_page = 0,
                };
            }
        }

        pub fn prevPage(self: *Self) QueryResult {
            if (self.pager) |*pager| {
                pager.*.prevPage();

                return .{
                    .commit = null,
                    .options = pager.*.getOptions().ptr,
                    .options_count = self.node.count,
                    .total_pages = pager.*.total_pages,
                    .current_page = pager.*.current_page,
                };
            } else {
                // If haven't press any key yet,
                // aka the node is the root node,
                // aka the pager is null,
                // reutrn an empty QueryResult.
                return .{
                    .commit = null,
                    .options = null,
                    .options_count = 0,
                    .total_pages = 0,
                    .current_page = 0,
                };
            }
        }

        pub fn backspace(self: *Self) QueryResult {
            if (self.pressed_key_indexes.items.len != 0) {
                _ = self.pressed_key_indexes.pop();

                self.node = self.root_node;

                for (self.pressed_key_indexes.items) |index| {
                    self.node = self.node.getChildByIndex(index).?;
                }

                self.pager.?.deinit();
                if (self.node == self.root_node) {
                    self.pager = null;

                    return .{
                        .commit = null,
                        .options = null,
                        .options_count = 0,
                        .total_pages = 0,
                        .current_page = 0,
                    };
                } else {
                    self.pager = NodePagination(node_init_options).init(self.allocator, self.node, self.page_size);

                    return .{
                        .commit = null,
                        .options = self.pager.?.getOptions().ptr,
                        .options_count = self.node.count,
                        .total_pages = self.pager.?.total_pages,
                        .current_page = 1,
                    };
                }
            } else {
                return .{
                    .commit = null,
                    .options = null,
                    .options_count = 0,
                    .total_pages = 0,
                    .current_page = 0,
                };
            }
        }
    };
}

test "works with initial typing" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        const query_result = context.pressKey('a');

        var expected_options = [_]QueryOption{
            .{ .value = "甲", .hint = null },
            .{ .value = "乙", .hint = "b" },
            .{ .value = "丙1", .hint = "c" },
        };

        try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result.options.?, 3);
        try testing.expectEqual(@as(u32, 11), query_result.options_count);
        try testing.expectEqual(@as(u32, 4), query_result.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result.current_page);
    }
}

test "works with 2nd typing" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        const query_result = context.pressKey('c');

        var expected_options = [_]QueryOption{
            .{ .value = "丙1", .hint = null },
            .{ .value = "丙2", .hint = null },
            .{ .value = "丁1", .hint = "d" },
        };

        try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result.options.?, 3);
        try testing.expectEqual(@as(u32, 7), query_result.options_count);
        try testing.expectEqual(@as(u32, 3), query_result.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result.current_page);
    }
}

test "commit with manually select" {
    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        const query_result = context.pressKey('2');

        try testing.expectEqualStrings("乙", std.mem.sliceTo(query_result.commit.?, 0));
        try testing.expectEqual(@as(u32, 0), query_result.options_count);
        try testing.expectEqual(@as(u32, 0), query_result.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result.current_page);
    }
}

test "select with out of range number" {
    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        const query_result = context.pressKey('4');

        try testing.expectEqualStrings("甲4", std.mem.sliceTo(query_result.commit.?, 0));
        try testing.expectEqual(@as(u32, 0), query_result.options_count);
        try testing.expectEqual(@as(u32, 0), query_result.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result.current_page);
    }
}

test "press space to commit the 1st option" {
    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        const query_result = context.pressKey(' ');

        try testing.expectEqualStrings("甲", std.mem.sliceTo(query_result.commit.?, 0));
        try testing.expectEqual(@as(u32, 0), query_result.options_count);
        try testing.expectEqual(@as(u32, 0), query_result.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result.current_page);
    }
}

test "press space when haven't press any other key" {
    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        const query_result = context.pressKey(' ');

        try testing.expectEqualStrings(" ", std.mem.sliceTo(query_result.commit.?, 0));
        try testing.expectEqual(@as(u32, 0), query_result.options_count);
        try testing.expectEqual(@as(u32, 0), query_result.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result.current_page);
    }
}

test "press `;` to commit the 2nd option" {
    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        _ = context.pressKey('c');
        const query_result = context.pressKey(';');

        try testing.expectEqualStrings("FooBar", std.mem.sliceTo(query_result.commit.?, 0));
        try testing.expectEqual(@as(u32, 0), query_result.options_count);
        try testing.expectEqual(@as(u32, 0), query_result.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result.current_page);
    }
}

test "press `;` to commit the 2nd option 2" {
    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        const query_result = context.pressKey(';');

        try testing.expectEqualStrings("乙", std.mem.sliceTo(query_result.commit.?, 0));
        try testing.expectEqual(@as(u32, 0), query_result.options_count);
        try testing.expectEqual(@as(u32, 0), query_result.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result.current_page);
    }
}

test "preess `;` when there are options start with `'`" {
    const pagination = @import("./pagination.zig");

    const node_init_options = .{ NodeInitOptions{}, NodeInitOptions{ .compressed = true } };
    inline for (node_init_options) |node_init_option| {
        comptime var root_node = Node(node_init_option).init();
        comptime root_node.add("a", "甲");
        comptime root_node.add("ab", "乙");
        comptime root_node.add("ac", "丙");
        comptime root_node.add("ad;", "Hello World");
        comptime root_node.add("ae;a", "Foo");
        comptime root_node.add("ae;b", "Bar");
        comptime root_node.calculateCount();

        var context = Context(node_init_option).init(testing.allocator, .{ .root_node = &root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        _ = context.pressKey('e');
        const query_result = context.pressKey(';');

        var expected_options = [_]QueryOption{
            .{ .value = "Foo", .hint = "a" },
            .{ .value = "Bar", .hint = "b" },
        };

        try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result.options.?, 2);
        try testing.expectEqual(@as(u32, 2), query_result.options_count);
        try testing.expectEqual(@as(u32, 1), query_result.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result.current_page);
    }
}

test "press `;` when there is only one option with hint" {
    const node_init_options = .{ NodeInitOptions{}, NodeInitOptions{ .compressed = true } };
    inline for (node_init_options) |node_init_option| {
        comptime var root_node = Node(node_init_option).init();
        comptime root_node.add("abc", "FooBar");
        comptime root_node.calculateCount();

        var context = Context(node_init_option).init(testing.allocator, .{ .root_node = &root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        _ = context.pressKey('b');
        const query_result = context.pressKey(';');

        try testing.expectEqualStrings("FooBar;", std.mem.sliceTo(query_result.commit.?, 0));
        try testing.expectEqual(@as(u32, 0), query_result.options_count);
        try testing.expectEqual(@as(u32, 0), query_result.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result.current_page);
    }
}

test "commit when there is only one option and the there is no hint in the option" {
    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        const query_result = context.pressKey('e');

        try testing.expectEqualStrings("Foo", std.mem.sliceTo(query_result.commit.?, 0));
        try testing.expectEqual(@as(u32, 0), query_result.options_count);
        try testing.expectEqual(@as(u32, 0), query_result.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result.current_page);
    }
}

test "should not commit when there is only one option but the option is with hint" {
    const pagination = @import("./pagination.zig");

    const node_init_options = .{ NodeInitOptions{}, NodeInitOptions{ .compressed = true } };
    inline for (node_init_options) |node_init_option| {
        comptime var root_node = Node(node_init_option).init();
        comptime root_node.add("a", "A");
        comptime root_node.add("ab", "B");
        comptime root_node.add("acde", "C");
        comptime root_node.calculateCount();

        var context = Context(node_init_option).init(testing.allocator, .{ .root_node = &root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        const query_result = context.pressKey('c');

        var expected_options = [_]QueryOption{
            .{ .value = "C", .hint = "de" },
        };

        try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result.options.?, 1);
        try testing.expectEqual(@as(u32, 1), query_result.options_count);
        try testing.expectEqual(@as(u32, 1), query_result.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result.current_page);
    }
}

test "commit when press a key is not in the children of the trie, but the key is in the children of the root trie" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        var expected_options_a = [_]QueryOption{
            .{ .value = "甲", .hint = null },
            .{ .value = "乙", .hint = "b" },
            .{ .value = "丙1", .hint = "c" },
        };
        var expected_options_c = [_]QueryOption{
            .{ .value = "丙1", .hint = null },
            .{ .value = "丙2", .hint = null },
            .{ .value = "丁1", .hint = "d" },
        };

        const query_result1 = context.pressKey('a');
        try testing.expectEqual(@as(?[*:0]const u8, null), query_result1.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_a[0..], query_result1.options.?, 3);
        try testing.expectEqual(@as(u32, 11), query_result1.options_count);
        try testing.expectEqual(@as(u32, 4), query_result1.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result1.current_page);

        const query_result2 = context.pressKey('c');
        try testing.expectEqual(@as(?[*:0]const u8, null), query_result2.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_c[0..], query_result2.options.?, 3);
        try testing.expectEqual(@as(u32, 7), query_result2.options_count);
        try testing.expectEqual(@as(u32, 3), query_result2.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result2.current_page);

        const query_result3 = context.pressKey('a');
        try testing.expectEqualStrings("丙1", std.mem.sliceTo(query_result3.commit.?, 0));
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_a[0..], query_result3.options.?, 3);
        try testing.expectEqual(@as(u32, 11), query_result3.options_count);
        try testing.expectEqual(@as(u32, 4), query_result3.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result3.current_page);

        const query_result4 = context.pressKey('c');
        try testing.expectEqual(@as(?[*:0]const u8, null), query_result4.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_c[0..], query_result4.options.?, 3);
        try testing.expectEqual(@as(u32, 7), query_result4.options_count);
        try testing.expectEqual(@as(u32, 3), query_result4.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result4.current_page);
    }
}

test "commit when press a key is not in the children of the trie, and the key is not in the children of the root trie" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        var expected_options_a = [_]QueryOption{
            .{ .value = "甲", .hint = null },
            .{ .value = "乙", .hint = "b" },
            .{ .value = "丙1", .hint = "c" },
        };
        var expected_options_c = [_]QueryOption{
            .{ .value = "丙1", .hint = null },
            .{ .value = "丙2", .hint = null },
            .{ .value = "丁1", .hint = "d" },
        };

        const query_result1 = context.pressKey('a');
        try testing.expectEqual(@as(?[*:0]const u8, null), query_result1.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_a[0..], query_result1.options.?, 3);
        try testing.expectEqual(@as(u32, 11), query_result1.options_count);
        try testing.expectEqual(@as(u32, 4), query_result1.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result1.current_page);

        const query_result2 = context.pressKey('c');
        try testing.expectEqual(@as(?[*:0]const u8, null), query_result2.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_c[0..], query_result2.options.?, 3);
        try testing.expectEqual(@as(u32, 7), query_result2.options_count);
        try testing.expectEqual(@as(u32, 3), query_result2.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result2.current_page);

        const query_result3 = context.pressKey('0');
        try testing.expectEqualStrings("丙10", std.mem.sliceTo(query_result3.commit.?, 0));
        try testing.expectEqual(@as(?[*]const QueryOption, null), query_result3.options);
        try testing.expectEqual(@as(u32, 0), query_result3.options_count);
        try testing.expectEqual(@as(u32, 0), query_result3.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result3.current_page);

        const query_result4 = context.pressKey('a');
        try testing.expectEqual(@as(?[*:0]const u8, null), query_result4.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_a[0..], query_result4.options.?, 3);
        try testing.expectEqual(@as(u32, 11), query_result4.options_count);
        try testing.expectEqual(@as(u32, 4), query_result4.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result4.current_page);
    }
}

test "next page" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        const query_result = context.nextPage();

        var expected_options = [_]QueryOption{
            .{ .value = "丙2", .hint = "c" },
            .{ .value = "Foo", .hint = "e" },
            .{ .value = "Bar", .hint = "f" },
        };

        try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result.options.?, 3);
        try testing.expectEqual(@as(u32, 11), query_result.options_count);
        try testing.expectEqual(@as(u32, 4), query_result.total_pages);
        try testing.expectEqual(@as(u32, 2), query_result.current_page);
    }
}

test "last page" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        _ = context.nextPage();
        _ = context.nextPage();
        const query_result = context.nextPage();

        var expected_options = [_]QueryOption{
            .{ .value = "丁4", .hint = "ce" },
            .{ .value = "FooBar", .hint = "c;" },
        };

        try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result.options.?, 2);
        try testing.expectEqual(@as(u32, 11), query_result.options_count);
        try testing.expectEqual(@as(u32, 4), query_result.total_pages);
        try testing.expectEqual(@as(u32, 4), query_result.current_page);
    }
}

test "previous page" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        _ = context.pressKey('a');
        _ = context.nextPage();
        _ = context.nextPage();
        const query_result = context.prevPage();

        var expected_options = [_]QueryOption{
            .{ .value = "丙2", .hint = "c" },
            .{ .value = "Foo", .hint = "e" },
            .{ .value = "Bar", .hint = "f" },
        };

        try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result.options.?, 3);
        try testing.expectEqual(@as(u32, 11), query_result.options_count);
        try testing.expectEqual(@as(u32, 4), query_result.total_pages);
        try testing.expectEqual(@as(u32, 2), query_result.current_page);
    }
}

test "press the first key, and the key is not in the root node children" {
    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        const query_result = context.pressKey('x');

        try testing.expectEqualStrings("x", std.mem.sliceTo(query_result.commit.?, 0));
        try testing.expectEqual(@as(?[*]const QueryOption, null), query_result.options);
        try testing.expectEqual(@as(u32, 0), query_result.options_count);
        try testing.expectEqual(@as(u32, 0), query_result.total_pages);
        try testing.expectEqual(@as(u32, 0), query_result.current_page);
    }
}

test "backspace works" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        var expected_commit: ?[*:0]const u8 = null;
        var expected_options_a = [_]QueryOption{
            .{ .value = "甲", .hint = null },
            .{ .value = "乙", .hint = "b" },
            .{ .value = "丙1", .hint = "c" },
        };
        var expected_options_c = [_]QueryOption{
            .{ .value = "丙1", .hint = null },
            .{ .value = "丙2", .hint = null },
            .{ .value = "丁1", .hint = "d" },
        };
        const expected_options_count_a: u32 = 11;
        const expected_options_count_c: u32 = 7;
        const expected_total_pages_a: u32 = 4;
        const expected_total_pages_c: u32 = 3;
        const expected_current_page: u32 = 1;

        const query_result1 = context.pressKey('a');
        try testing.expectEqual(expected_commit, query_result1.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_a[0..], query_result1.options.?, 3);
        try testing.expectEqual(expected_options_count_a, query_result1.options_count);
        try testing.expectEqual(expected_total_pages_a, query_result1.total_pages);
        try testing.expectEqual(expected_current_page, query_result1.current_page);

        const query_result2 = context.pressKey('c');
        try testing.expectEqual(expected_commit, query_result2.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_c[0..], query_result2.options.?, 3);
        try testing.expectEqual(expected_options_count_c, query_result2.options_count);
        try testing.expectEqual(expected_total_pages_c, query_result2.total_pages);
        try testing.expectEqual(expected_current_page, query_result2.current_page);

        const query_result3 = context.backspace();
        try testing.expectEqual(expected_commit, query_result3.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_a[0..], query_result3.options.?, 3);
        try testing.expectEqual(expected_options_count_a, query_result3.options_count);
        try testing.expectEqual(expected_total_pages_a, query_result3.total_pages);
        try testing.expectEqual(expected_current_page, query_result3.current_page);

        const query_result4 = context.pressKey('c');
        try testing.expectEqual(expected_commit, query_result4.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options_c[0..], query_result4.options.?, 3);
        try testing.expectEqual(expected_options_count_c, query_result4.options_count);
        try testing.expectEqual(expected_total_pages_c, query_result4.total_pages);
        try testing.expectEqual(expected_current_page, query_result4.current_page);
    }
}

test "backspace works 2" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        var expected_empty_commit: ?[*:0]const u8 = null;
        var expected_empty_options: ?[*]const QueryOption = null;
        var expected_options = [_]QueryOption{
            .{ .value = "甲", .hint = null },
            .{ .value = "乙", .hint = "b" },
            .{ .value = "丙1", .hint = "c" },
        };
        const expected_empty_options_count: u32 = 0;
        const expected_options_count: u32 = 11;
        const expected_empty_total_pages: u32 = 0;
        const expected_total_pages: u32 = 4;
        const expected_empty_current_page: u32 = 0;
        const expected_current_page: u32 = 1;

        const query_result1 = context.pressKey('a');
        try testing.expectEqual(expected_empty_commit, query_result1.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result1.options.?, 3);
        try testing.expectEqual(expected_options_count, query_result1.options_count);
        try testing.expectEqual(expected_total_pages, query_result1.total_pages);
        try testing.expectEqual(expected_current_page, query_result1.current_page);

        const query_result2 = context.backspace();
        try testing.expectEqual(expected_empty_commit, query_result2.commit);
        try testing.expectEqual(expected_empty_options, query_result2.options);
        try testing.expectEqual(expected_empty_options_count, query_result2.options_count);
        try testing.expectEqual(expected_empty_total_pages, query_result2.total_pages);
        try testing.expectEqual(expected_empty_current_page, query_result2.current_page);

        const query_result3 = context.pressKey('a');
        try testing.expectEqual(expected_empty_commit, query_result3.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result3.options.?, 3);
        try testing.expectEqual(expected_options_count, query_result3.options_count);
        try testing.expectEqual(expected_total_pages, query_result3.total_pages);
        try testing.expectEqual(expected_current_page, query_result3.current_page);
    }
}

test "backspace should do nothing when current page is 1" {
    const pagination = @import("./pagination.zig");

    comptime var list_of_root_node_and_option = generateTestTrie();
    inline for (list_of_root_node_and_option) |root_node_and_option| {
        comptime var root_node = root_node_and_option[0];
        comptime var option = root_node_and_option[1];

        var context = Context(option).init(testing.allocator, .{ .root_node = root_node, .page_size = 3 });
        defer context.deinit();

        const query_result = context.pressKey('a');

        var expected_options = [_]QueryOption{
            .{ .value = "甲", .hint = null },
            .{ .value = "乙", .hint = "b" },
            .{ .value = "丙1", .hint = "c" },
        };

        try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
        try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result.options.?, 3);
        try testing.expectEqual(@as(u32, 11), query_result.options_count);
        try testing.expectEqual(@as(u32, 4), query_result.total_pages);
        try testing.expectEqual(@as(u32, 1), query_result.current_page);
    }
}
