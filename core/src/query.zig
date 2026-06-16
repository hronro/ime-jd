const std = @import("std");
const testing = std.testing;

const trie_mod = @import("trie");
const Trie = trie_mod.Trie;
const Node = trie_mod.Trie.Node;
const pagination = @import("./pagination.zig");
const NodePagination = pagination.NodePagination;
const QueryOption = pagination.QueryOption;
const buildTestTrie = @import("./trie_test_data.zig").buildTestTrie;

/// Inline-buffer sizes. `MAX_PRESSED_KEYS` is a domain invariant
/// (dictionary entries have ≤ 6 letters; `buildBlob` asserts it).
/// `COMMIT_SCRATCH_BYTES` covers any in-place commit composition; the
/// largest is a two-value concatenation (case E1 in `pressKey`), bounded
/// by the same build-time assert in `buildBlob`.
pub const MAX_PRESSED_KEYS: usize = 6;
pub const COMMIT_SCRATCH_BYTES: usize = 128;

pub const InitOptions = struct {
    trie: *const Trie,
    page_size: u8,
};

pub const QueryResult = extern struct {
    commit: ?[*:0]const u8,
    options: ?[*]const QueryOption,
    options_count: u32,
    total_pages: u32,
    current_page: u32,
};

pub const Context = struct {
    const Self = @This();

    /// Pre-allocated buffers borrowed from the caller. In production these
    /// come from `jd_init`'s carved tail; in tests, separately allocated.
    pub const Buffers = struct {
        frontier: []pagination.FrontierEntry,
        path_buf: []u8,
        page_buf: []u8,
    };

    /// The backing allocation handed to `shared_allocator.free` in
    /// `jd_deinit`. In production this is the entire `jd_init` allocation
    /// (including the Context struct itself); in tests it's unused.
    /// Alignment is `@alignOf(usize)` because that's the max alignment
    /// of any field on Context (Self-referential @alignOf isn't allowed).
    raw: []align(@alignOf(usize)) u8,

    /// Scratch for commit-string composition (synth single byte, value+key,
    /// value+';', value+value). Returned to C as a sentinel-terminated
    /// pointer; the caller consumes before the next jd_* call.
    commit_scratch: [COMMIT_SCRATCH_BYTES]u8,

    /// One entry per descended trie key; bounded by max key length.
    pressed_keys: [MAX_PRESSED_KEYS]usize,
    pressed_keys_len: u8,

    /// Backs the per-page `QueryOption` arrays and their hint strings
    /// inside `NodePagination`. Reset on every page materialization.
    page_fba: std.heap.FixedBufferAllocator,

    /// BFS frontier + path bytes for any active `NodePagination`. Shared
    /// across successive paginators on this context (each new `pager`
    /// re-uses the same backing memory).
    frontier_buf: []pagination.FrontierEntry,
    path_buf: []u8,

    trie: *const Trie,
    root_node: *const Node,
    page_size: u8,
    node: *const Node,
    pager: ?NodePagination,

    /// Constructs a Context from pre-allocated buffers. The caller (jd_init
    /// or a test harness) provides storage for the three variable-sized
    /// regions; the inline fields (commit_scratch, pressed_keys, page_fba)
    /// live inside the returned struct. `raw` is left undefined — jd_init
    /// sets it explicitly after the carved layout is known; tests don't
    /// touch it.
    pub fn init(buffers: Buffers, options: InitOptions) Self {
        const root_node = options.trie.root();
        return .{
            .raw = undefined,
            .commit_scratch = undefined,
            .pressed_keys = undefined,
            .pressed_keys_len = 0,
            .page_fba = std.heap.FixedBufferAllocator.init(buffers.page_buf),
            .frontier_buf = buffers.frontier,
            .path_buf = buffers.path_buf,
            .trie = options.trie,
            .root_node = root_node,
            .page_size = options.page_size,
            .node = root_node,
            .pager = null,
        };
    }

    fn paginationBuffers(self: *Self) pagination.Buffers {
        return .{
            .frontier = self.frontier_buf,
            .path_buf = self.path_buf,
            .page_fba = &self.page_fba,
        };
    }

    /// Writes `len` bytes already filled in `commit_scratch[0..len]` plus a
    /// trailing 0 sentinel, and returns the scratch pointer typed for C.
    inline fn scratchCommit(self: *Self, len: usize) [*:0]const u8 {
        self.commit_scratch[len] = 0;
        return @ptrCast(&self.commit_scratch);
    }

    pub fn reset(self: *Self) void {
        self.node = self.root_node;
        self.pager = null;
        self.pressed_keys_len = 0;
    }

    pub fn pressKey(self: *Self, key: u8) QueryResult {
        // Case A: space — commit first option (rodata pointer), else synth " ".
        if (key == ' ') {
            if (self.pager) |*pager| {
                const options = pager.*.getOptions();
                if (options.len >= 1) {
                    const commit = options[0].value; // rodata
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
            self.commit_scratch[0] = ' ';
            const commit = self.scratchCommit(1);
            self.reset();
            return .{
                .commit = commit,
                .options = null,
                .options_count = 0,
                .total_pages = 0,
                .current_page = 0,
            };
        }

        // Case B: ';' with no ';' child — commit the 2nd option (rodata),
        // or fall back to option[0] + ';' written into scratch.
        if (key == ';' and self.node.getChild(self.trie, ';') == null) {
            if (self.pager) |*pager| {
                const options = pager.*.getOptions();
                if (options.len >= 2) {
                    const commit = options[1].value; // rodata
                    self.reset();
                    return .{
                        .commit = commit,
                        .options = null,
                        .options_count = 0,
                        .total_pages = 0,
                        .current_page = 0,
                    };
                } else {
                    const original = std.mem.sliceTo(options[0].value, 0);
                    @memcpy(self.commit_scratch[0..original.len], original);
                    self.commit_scratch[original.len] = ';';
                    const commit = self.scratchCommit(original.len + 1);
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

        // Case C: '1'..'9' picks an option by index (rodata pointer).
        if (key >= '1' and key <= '9') {
            if (self.pager) |*pager| {
                const options = pager.*.getOptions();
                const option_index = key - '1';
                if (option_index < options.len) {
                    const commit = options[option_index].value; // rodata
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

        // Case D: descend into a child of the current node.
        if (self.node.getChild(self.trie, key)) |node| {
            const key_index = self.node.indexOfChild(self.trie, key).?;

            self.node = node;
            self.pager = NodePagination.init(self.paginationBuffers(), self.trie, node, self.page_size);
            self.pressed_keys[self.pressed_keys_len] = key_index;
            self.pressed_keys_len += 1;

            const options = self.pager.?.getOptions();

            // D1: single option with no hint — commit it directly (rodata).
            if (options.len == 1 and options[0].hint == null) {
                const commit = options[0].value; // rodata
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
                .options_count = self.node.count(),
                .total_pages = self.pager.?.total_pages,
                .current_page = 1,
            };
        } else if (self.root_node.getChild(self.trie, key)) |node| {
            // Case E: current node has no child with `key`, but root does —
            // commit the previous page's first option (rodata), then jump.
            //
            // Both `.value` pointers are into the trie strings pool, so
            // they remain valid across the page_fba reset triggered by the
            // new pager's first `getOptions()`. The `QueryOption` array
            // slice (`prev_options`) does get invalidated, but we capture
            // the rodata pointer up front.
            const prev_value = self.pager.?.getOptions()[0].value; // rodata

            self.node = node;
            self.pager = NodePagination.init(self.paginationBuffers(), self.trie, node, self.page_size);
            self.pressed_keys_len = 0;
            self.pressed_keys[self.pressed_keys_len] = self.root_node.indexOfChild(self.trie, key).?;
            self.pressed_keys_len += 1;

            const options = self.pager.?.getOptions();

            // E1: single option no hint — concat prev + new into scratch.
            if (options.len == 1 and options[0].hint == null) {
                const prev = std.mem.sliceTo(prev_value, 0);
                const curr = std.mem.sliceTo(options[0].value, 0);
                @memcpy(self.commit_scratch[0..prev.len], prev);
                @memcpy(self.commit_scratch[prev.len..][0..curr.len], curr);
                const commit = self.scratchCommit(prev.len + curr.len);
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
                .commit = prev_value, // rodata
                .options = options.ptr,
                .options_count = self.node.count(),
                .total_pages = self.pager.?.total_pages,
                .current_page = 1,
            };
        }

        // Case F: at root, key has no child — commit the key byte itself.
        if (self.node == self.root_node) {
            self.commit_scratch[0] = key;
            const commit = self.scratchCommit(1);
            self.reset();
            return .{
                .commit = commit,
                .options = null,
                .options_count = 0,
                .total_pages = 0,
                .current_page = 0,
            };
        } else {
            // Case G: deep in the trie, key has no matching descent — commit
            // the current first option with `key` appended.
            const options = self.pager.?.getOptions();
            const original = std.mem.sliceTo(options[0].value, 0);
            @memcpy(self.commit_scratch[0..original.len], original);
            self.commit_scratch[original.len] = key;
            const commit = self.scratchCommit(original.len + 1);
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
                .options_count = self.node.count(),
                .total_pages = pager.*.total_pages,
                .current_page = pager.*.current_page,
            };
        } else {
            return emptyResult();
        }
    }

    pub fn prevPage(self: *Self) QueryResult {
        if (self.pager) |*pager| {
            pager.*.prevPage();

            return .{
                .commit = null,
                .options = pager.*.getOptions().ptr,
                .options_count = self.node.count(),
                .total_pages = pager.*.total_pages,
                .current_page = pager.*.current_page,
            };
        } else {
            return emptyResult();
        }
    }

    pub fn jumpToPage(self: *Self, page: u32) QueryResult {
        if (self.pager) |*pager| {
            pager.*.jumpToPage(page);

            return .{
                .commit = null,
                .options = pager.*.getOptions().ptr,
                .options_count = self.node.count(),
                .total_pages = pager.*.total_pages,
                .current_page = pager.*.current_page,
            };
        } else {
            return emptyResult();
        }
    }

    pub fn backspace(self: *Self) QueryResult {
        if (self.pressed_keys_len != 0) {
            self.pressed_keys_len -= 1;

            self.node = self.root_node;

            for (self.pressed_keys[0..self.pressed_keys_len]) |index| {
                self.node = self.node.getChildByIndex(self.trie, index).?;
            }

            if (self.node == self.root_node) {
                self.pager = null;
                return emptyResult();
            } else {
                self.pager = NodePagination.init(self.paginationBuffers(), self.trie, self.node, self.page_size);

                return .{
                    .commit = null,
                    .options = self.pager.?.getOptions().ptr,
                    .options_count = self.node.count(),
                    .total_pages = self.pager.?.total_pages,
                    .current_page = 1,
                };
            }
        } else {
            return emptyResult();
        }
    }
};

fn emptyResult() QueryResult {
    return .{
        .commit = null,
        .options = null,
        .options_count = 0,
        .total_pages = 0,
        .current_page = 0,
    };
}

// =========================================================================
// Tests
// =========================================================================

/// Wraps the three heap regions a `Context` borrows so each test can build
/// and tear them down without repeating the boilerplate. In production this
/// work is done by `jd_init`.
const ContextHarness = struct {
    ctx: Context,
    frontier: []pagination.FrontierEntry,
    path_buf: []u8,
    page_buf: []u8,

    fn init(allocator: std.mem.Allocator, trie: *const Trie, page_size: u8) !ContextHarness {
        // `+1` covers the (test-only) case of paginating from root.
        const frontier = try allocator.alloc(pagination.FrontierEntry, trie.frontier_cap + 1);
        const path_buf = try allocator.alloc(u8, trie.path_buf_cap + 1);
        const page_buf = try allocator.alloc(u8, pagination.pageBufferSize(page_size));
        var self = ContextHarness{
            .ctx = undefined,
            .frontier = frontier,
            .path_buf = path_buf,
            .page_buf = page_buf,
        };
        self.ctx = Context.init(.{
            .frontier = frontier,
            .path_buf = path_buf,
            .page_buf = page_buf,
        }, .{ .trie = trie, .page_size = page_size });
        return self;
    }

    fn deinit(self: *ContextHarness, allocator: std.mem.Allocator) void {
        allocator.free(self.frontier);
        allocator.free(self.path_buf);
        allocator.free(self.page_buf);
    }
};

test "works with initial typing" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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

test "works with 2nd typing" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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

test "commit with manually select" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    const query_result = context.pressKey('2');

    try testing.expectEqualStrings("乙", std.mem.sliceTo(query_result.commit.?, 0));
    try testing.expectEqual(@as(u32, 0), query_result.options_count);
    try testing.expectEqual(@as(u32, 0), query_result.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result.current_page);
}

test "select with out of range number" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    const query_result = context.pressKey('4');

    try testing.expectEqualStrings("甲4", std.mem.sliceTo(query_result.commit.?, 0));
    try testing.expectEqual(@as(u32, 0), query_result.options_count);
    try testing.expectEqual(@as(u32, 0), query_result.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result.current_page);
}

test "press space to commit the 1st option" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    const query_result = context.pressKey(' ');

    try testing.expectEqualStrings("甲", std.mem.sliceTo(query_result.commit.?, 0));
    try testing.expectEqual(@as(u32, 0), query_result.options_count);
    try testing.expectEqual(@as(u32, 0), query_result.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result.current_page);
}

test "press space when haven't press any other key" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    const query_result = context.pressKey(' ');

    try testing.expectEqualStrings(" ", std.mem.sliceTo(query_result.commit.?, 0));
    try testing.expectEqual(@as(u32, 0), query_result.options_count);
    try testing.expectEqual(@as(u32, 0), query_result.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result.current_page);
}

test "press `;` to commit the 2nd option" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    _ = context.pressKey('c');
    const query_result = context.pressKey(';');

    try testing.expectEqualStrings("FooBar", std.mem.sliceTo(query_result.commit.?, 0));
    try testing.expectEqual(@as(u32, 0), query_result.options_count);
    try testing.expectEqual(@as(u32, 0), query_result.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result.current_page);
}

test "press `;` to commit the 2nd option 2" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    const query_result = context.pressKey(';');

    try testing.expectEqualStrings("乙", std.mem.sliceTo(query_result.commit.?, 0));
    try testing.expectEqual(@as(u32, 0), query_result.options_count);
    try testing.expectEqual(@as(u32, 0), query_result.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result.current_page);
}

test "press `;` when there are options start with `'`" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "甲" },
        .{ .keys = "ab", .value = "乙" },
        .{ .keys = "ac", .value = "丙" },
        .{ .keys = "ad;", .value = "Hello World" },
        .{ .keys = "ae;a", .value = "Foo" },
        .{ .keys = "ae;b", .value = "Bar" },
    });
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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

test "press `;` when there is only one option with hint" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "abc", .value = "FooBar" },
    });
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    _ = context.pressKey('b');
    const query_result = context.pressKey(';');

    try testing.expectEqualStrings("FooBar;", std.mem.sliceTo(query_result.commit.?, 0));
    try testing.expectEqual(@as(u32, 0), query_result.options_count);
    try testing.expectEqual(@as(u32, 0), query_result.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result.current_page);
}

test "commit when there is only one option and the there is no hint in the option" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    const query_result = context.pressKey('e');

    try testing.expectEqualStrings("Foo", std.mem.sliceTo(query_result.commit.?, 0));
    try testing.expectEqual(@as(u32, 0), query_result.options_count);
    try testing.expectEqual(@as(u32, 0), query_result.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result.current_page);
}

test "should not commit when there is only one option but the option is with hint" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "A" },
        .{ .keys = "ab", .value = "B" },
        .{ .keys = "acde", .value = "C" },
    });
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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

test "commit when press a key is not in the children of the trie, but the key is in the children of the root trie" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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

test "next page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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

test "last page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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

test "previous page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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

test "jump to page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');

    // Jump forward past the current page.
    const r3 = context.jumpToPage(3);
    var expected_p3 = [_]QueryOption{
        .{ .value = "丁1", .hint = "cd" },
        .{ .value = "丁2", .hint = "cd" },
        .{ .value = "丁3", .hint = "cd" },
    };
    try pagination.expectEqualQueryOptionManyItemPtr(expected_p3[0..], r3.options.?, 3);
    try testing.expectEqual(@as(u32, 3), r3.current_page);

    // Jump backward.
    const r1 = context.jumpToPage(1);
    var expected_p1 = [_]QueryOption{
        .{ .value = "甲", .hint = null },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙1", .hint = "c" },
    };
    try pagination.expectEqualQueryOptionManyItemPtr(expected_p1[0..], r1.options.?, 3);
    try testing.expectEqual(@as(u32, 1), r1.current_page);

    // Out-of-range targets are silent no-ops.
    const r_zero = context.jumpToPage(0);
    try testing.expectEqual(@as(u32, 1), r_zero.current_page);
    const r_huge = context.jumpToPage(999);
    try testing.expectEqual(@as(u32, 1), r_huge.current_page);
}

test "jump to page with no composition" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    const r = context.jumpToPage(2);
    try testing.expectEqual(@as(?[*:0]const u8, null), r.commit);
    try testing.expectEqual(@as(?[*]const QueryOption, null), r.options);
    try testing.expectEqual(@as(u32, 0), r.current_page);
}

test "press the first key, and the key is not in the root node children" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    const query_result = context.pressKey('x');

    try testing.expectEqualStrings("x", std.mem.sliceTo(query_result.commit.?, 0));
    try testing.expectEqual(@as(?[*]const QueryOption, null), query_result.options);
    try testing.expectEqual(@as(u32, 0), query_result.options_count);
    try testing.expectEqual(@as(u32, 0), query_result.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result.current_page);
}

test "backspace works" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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

    const query_result2 = context.pressKey('c');
    try testing.expectEqual(@as(?[*:0]const u8, null), query_result2.commit);
    try pagination.expectEqualQueryOptionManyItemPtr(expected_options_c[0..], query_result2.options.?, 3);
    try testing.expectEqual(@as(u32, 7), query_result2.options_count);

    const query_result3 = context.backspace();
    try testing.expectEqual(@as(?[*:0]const u8, null), query_result3.commit);
    try pagination.expectEqualQueryOptionManyItemPtr(expected_options_a[0..], query_result3.options.?, 3);
    try testing.expectEqual(@as(u32, 11), query_result3.options_count);

    const query_result4 = context.pressKey('c');
    try testing.expectEqual(@as(?[*:0]const u8, null), query_result4.commit);
    try pagination.expectEqualQueryOptionManyItemPtr(expected_options_c[0..], query_result4.options.?, 3);
    try testing.expectEqual(@as(u32, 7), query_result4.options_count);
}

test "backspace to root" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    var expected_options = [_]QueryOption{
        .{ .value = "甲", .hint = null },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙1", .hint = "c" },
    };

    const query_result1 = context.pressKey('a');
    try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result1.options.?, 3);

    const query_result2 = context.backspace();
    try testing.expectEqual(@as(?[*:0]const u8, null), query_result2.commit);
    try testing.expectEqual(@as(?[*]const QueryOption, null), query_result2.options);
    try testing.expectEqual(@as(u32, 0), query_result2.options_count);
    try testing.expectEqual(@as(u32, 0), query_result2.total_pages);
    try testing.expectEqual(@as(u32, 0), query_result2.current_page);

    const query_result3 = context.pressKey('a');
    try testing.expectEqual(@as(?[*:0]const u8, null), query_result3.commit);
    try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result3.options.?, 3);
}

test "backspace should do nothing when at root" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    // pressKey('a') first to get a page, then backspace once to root,
    // then another backspace must be a no-op.
    _ = context.pressKey('a');
    _ = context.backspace();

    const query_result = context.backspace();
    try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
    try testing.expectEqual(@as(?[*]const QueryOption, null), query_result.options);

    // Verify we can still press 'a' and see the same options.
    const query_result_a = context.pressKey('a');
    var expected_options = [_]QueryOption{
        .{ .value = "甲", .hint = null },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙1", .hint = "c" },
    };
    try pagination.expectEqualQueryOptionManyItemPtr(expected_options[0..], query_result_a.options.?, 3);
}

test "commit when press a key is not in the children of the trie, and the key is not in the children of the root trie" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

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
