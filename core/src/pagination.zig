const std = @import("std");
const testing = std.testing;

const trie_mod = @import("trie");
const Trie = trie_mod.Trie;
const Node = trie_mod.Trie.Node;
const buildTestTrie = @import("./trie_test_data.zig").buildTestTrie;
const punc_fmt = @import("punc_format");
const punc_mod = @import("./punc.zig");

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
pub const FrontierEntry = struct {
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
/// Pre-allocated buffers a `NodePagination` borrows. The caller owns the
/// memory and is responsible for keeping it valid for the paginator's
/// lifetime. Sizes are dictated by `Trie.frontier_cap` / `Trie.path_buf_cap`
/// and the chosen page_size; in production these come from the per-context
/// buffer carved by `jd_init`.
pub const Buffers = struct {
    frontier: []FrontierEntry,
    path_buf: []u8,
    page_fba: *std.heap.FixedBufferAllocator,
};

pub const NodePagination = struct {
    const Self = @This();

    /// Backs the materialized current page (options array + hint strings).
    /// Reset before each materialization, so old page memory is reclaimed.
    page_fba: *std.heap.FixedBufferAllocator,

    trie: *const Trie,
    start_node: *const Node,
    page_size: u8,
    total_pages: u32,
    current_page: u32,

    /// BFS cursor — together (frontier, frontier_head, skipped) identify
    /// the next value to emit. `bfs_page` is the page that the cursor will
    /// emit next.
    bfs_page: u32,
    frontier: []FrontierEntry,
    frontier_len: usize,
    frontier_head: usize,
    path_buf: []u8,
    path_buf_len: usize,
    skipped: u8,

    /// Cached page contents for `cached_page`, allocated in `page_fba`.
    /// `cached_page == 0` means no page is currently materialized.
    cached_options: []QueryOption,
    cached_page: u32,

    pub fn init(buffers: Buffers, trie: *const Trie, node: *const Node, page_size: u8) Self {
        const total_pages: u32 = (node.count() + page_size - 1) / page_size;
        buffers.frontier[0] = .{
            .node = node,
            .path_start = 0,
            .path_len = 0,
        };
        return .{
            .page_fba = buffers.page_fba,
            .trie = trie,
            .start_node = node,
            .page_size = page_size,
            .total_pages = total_pages,
            .current_page = 1,
            .bfs_page = 1,
            .frontier = buffers.frontier,
            .frontier_len = 1,
            .frontier_head = 0,
            .path_buf = buffers.path_buf,
            .path_buf_len = 0,
            .skipped = 0,
            .cached_options = &.{},
            .cached_page = 0,
        };
    }

    pub fn nextPage(self: *Self) void {
        if (self.current_page < self.total_pages) self.current_page += 1;
    }

    pub fn prevPage(self: *Self) void {
        if (self.current_page > 1) self.current_page -= 1;
    }

    /// Random-access page jump. Like `nextPage`/`prevPage`, out-of-range
    /// requests are silently ignored — callers can pass any `u32` without
    /// guarding the bounds themselves.
    pub fn jumpToPage(self: *Self, page: u32) void {
        if (page >= 1 and page <= self.total_pages) self.current_page = page;
    }

    pub fn getOptions(self: *Self) []const QueryOption {
        if (self.cached_page == self.current_page) return self.cached_options;

        if (self.current_page < self.bfs_page) self.rewindBFS();
        while (self.bfs_page < self.current_page) self.skipOnePage();

        self.page_fba.reset();
        self.cached_options = self.materializeOnePage();
        self.cached_page = self.current_page;
        return self.cached_options;
    }

    fn rewindBFS(self: *Self) void {
        self.frontier[0] = .{
            .node = self.start_node,
            .path_start = 0,
            .path_len = 0,
        };
        self.frontier_len = 1;
        self.path_buf_len = 0;
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
        for (0..w) |i| {
            const child = entry.node.getChildByIndex(self.trie, i).?;
            const key = entry.node.keyOfChildByIndex(self.trie, i).?;
            const child_path_start: u32 = @intCast(self.path_buf_len);
            const parent_path = self.path_buf[entry.path_start..][0..entry.path_len];
            @memcpy(self.path_buf[self.path_buf_len..][0..entry.path_len], parent_path);
            self.path_buf_len += entry.path_len;
            self.path_buf[self.path_buf_len] = key;
            self.path_buf_len += 1;
            self.frontier[self.frontier_len] = .{
                .node = child,
                .path_start = child_path_start,
                .path_len = entry.path_len + 1,
            };
            self.frontier_len += 1;
        }
    }

    /// Consume one value from the BFS cursor. If `emit_to` is non-null, the
    /// value is materialized as a `QueryOption` allocated in that allocator
    /// (with a freshly-allocated hint copy). Otherwise the value is skipped.
    fn consumeOne(self: *Self, emit_to: ?std.mem.Allocator) ?QueryOption {
        while (true) {
            const entry = self.frontier[self.frontier_head];
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
                    const path = self.path_buf[entry.path_start..][0..entry.path_len];
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
        const page_alloc = self.page_fba.allocator();
        const n = self.pageOptionCount(self.current_page);
        const options = page_alloc.alloc(QueryOption, n) catch unreachable;
        for (0..n) |i| options[i] = self.consumeOne(page_alloc).?;
        self.bfs_page += 1;
        return options;
    }
};

/// Paginator over a single normal-table entry's punctuation candidates.
///
/// Compared to `NodePagination`, this is much simpler: candidates sit as
/// NUL-separated strings in a flat pool, the count is known up-front
/// (`NormalEntry.candidates_count`), and there is no BFS. Paired-toggle
/// logic does NOT live here — paired punctuation is handled inline in
/// `query.zig` Case P. This paginator strictly serves multi-candidate
/// normal lookups (the `[` → `「`/`【`/`〔`/`［` case).
pub const PuncPagination = struct {
    const Self = @This();

    /// The normal entry whose candidates we paginate.
    entry: *const punc_fmt.NormalEntry,
    /// Shared strings pool. `entry.values_offset` indexes into this.
    strings: []const u8,
    /// Backs the materialized current page (options array). Reset before
    /// each materialization, matching `NodePagination`'s contract.
    page_fba: *std.heap.FixedBufferAllocator,

    page_size: u8,
    total_pages: u32,
    current_page: u32,

    /// Cached page contents for `cached_page`. `cached_page == 0` means
    /// no page is currently materialized.
    cached_options: []QueryOption,
    cached_page: u32,

    pub fn init(
        entry: *const punc_fmt.NormalEntry,
        strings: []const u8,
        page_fba: *std.heap.FixedBufferAllocator,
        page_size: u8,
    ) Self {
        std.debug.assert(entry.candidates_count > 0);
        const total_pages: u32 =
            (@as(u32, entry.candidates_count) + page_size - 1) / page_size;
        return .{
            .entry = entry,
            .strings = strings,
            .page_fba = page_fba,
            .page_size = page_size,
            .total_pages = total_pages,
            .current_page = 1,
            .cached_options = &.{},
            .cached_page = 0,
        };
    }

    pub fn nextPage(self: *Self) void {
        if (self.current_page < self.total_pages) self.current_page += 1;
    }

    pub fn prevPage(self: *Self) void {
        if (self.current_page > 1) self.current_page -= 1;
    }

    pub fn jumpToPage(self: *Self, page: u32) void {
        if (page >= 1 and page <= self.total_pages) self.current_page = page;
    }

    pub fn getOptions(self: *Self) []const QueryOption {
        if (self.cached_page == self.current_page) return self.cached_options;

        const start: usize = (self.current_page - 1) * @as(usize, self.page_size);
        const end: usize = @min(start + self.page_size, self.entry.candidates_count);
        const slice_len = end - start;

        // Walk to the `start`-th candidate.
        var offset: usize = self.entry.values_offset;
        var i: usize = 0;
        while (i < start) : (i += 1) {
            offset = std.mem.indexOfScalarPos(u8, self.strings, offset, 0).? + 1;
        }

        self.page_fba.reset();
        const alloc = self.page_fba.allocator();
        const options = alloc.alloc(QueryOption, slice_len) catch unreachable;
        i = 0;
        while (i < slice_len) : (i += 1) {
            const value_ptr: [*:0]const u8 = @ptrCast(&self.strings[offset]);
            options[i] = .{ .value = value_ptr, .hint = null };
            offset = std.mem.indexOfScalarPos(u8, self.strings, offset, 0).? + 1;
        }

        self.cached_options = options;
        self.cached_page = self.current_page;
        return options;
    }

    /// Pick the i-th candidate on the CURRENT page and return its
    /// commit-bytes pointer (a rodata slice into the strings pool).
    pub fn commitAtIndex(self: *Self, i: usize) [*:0]const u8 {
        const flat_index: usize = (self.current_page - 1) * @as(usize, self.page_size) + i;
        std.debug.assert(flat_index < self.entry.candidates_count);
        var offset: usize = self.entry.values_offset;
        var seen: usize = 0;
        while (seen < flat_index) : (seen += 1) {
            offset = std.mem.indexOfScalarPos(u8, self.strings, offset, 0).? + 1;
        }
        return @ptrCast(&self.strings[offset]);
    }
};

/// Tagged-union pager — used so a `Context` can be in either a trie
/// composition or a punctuation candidate window without duplicating the
/// branching across every paging API. Paired punctuation is NOT paginated
/// (it's a single-press commit) — only the normal multi-candidate case
/// reaches the `punc` variant here.
pub const Pager = union(enum) {
    trie: NodePagination,
    punc: PuncPagination,

    pub fn getOptions(self: *Pager) []const QueryOption {
        return switch (self.*) {
            .trie => |*p| p.getOptions(),
            .punc => |*p| p.getOptions(),
        };
    }

    pub fn nextPage(self: *Pager) void {
        switch (self.*) {
            .trie => |*p| p.nextPage(),
            .punc => |*p| p.nextPage(),
        }
    }

    pub fn prevPage(self: *Pager) void {
        switch (self.*) {
            .trie => |*p| p.prevPage(),
            .punc => |*p| p.prevPage(),
        }
    }

    pub fn jumpToPage(self: *Pager, page: u32) void {
        switch (self.*) {
            .trie => |*p| p.jumpToPage(page),
            .punc => |*p| p.jumpToPage(page),
        }
    }

    pub fn totalPages(self: *const Pager) u32 {
        return switch (self.*) {
            .trie => |p| p.total_pages,
            .punc => |p| p.total_pages,
        };
    }

    pub fn currentPage(self: *const Pager) u32 {
        return switch (self.*) {
            .trie => |p| p.current_page,
            .punc => |p| p.current_page,
        };
    }

    /// Total options across all pages.
    pub fn totalOptions(self: *const Pager) u32 {
        return switch (self.*) {
            .trie => |p| p.start_node.count(),
            .punc => |p| @as(u32, p.entry.candidates_count),
        };
    }

    /// Pick option `i` from the CURRENT page and return its commit-bytes
    /// pointer. No side effects in either variant — paired-toggle flipping
    /// lives in `query.zig` Case P (paired branch), not here.
    pub fn commitAtIndex(self: *Pager, i: usize) [*:0]const u8 {
        return switch (self.*) {
            .trie => |*p| p.getOptions()[i].value,
            .punc => |*p| p.commitAtIndex(i),
        };
    }
};

/// Computes the page_fba buffer size for a given page_size. Used by both
/// production (`jd_init` in main.zig) and tests.
pub fn pageBufferSize(page_size: u8) usize {
    // page_size options + one hint per option of up to MAX_HINT_LEN bytes + sentinel.
    const MAX_HINT_LEN: usize = 5;
    return @as(usize, page_size) * (@sizeOf(QueryOption) + MAX_HINT_LEN + 1);
}

// =========================================================================
// Tests
// =========================================================================

/// Wraps the three heap regions a `NodePagination` borrows so each test can
/// build/teardown them in two lines instead of five. In production this work
/// is done by `jd_init`.
const TestHarness = struct {
    frontier: []FrontierEntry,
    path_buf: []u8,
    page_buf: []u8,
    page_fba: std.heap.FixedBufferAllocator,

    fn init(allocator: std.mem.Allocator, trie: *const Trie, page_size: u8) !TestHarness {
        // `+1` so tests that paginate from root (with subtree = root's full
        // node count, one more than any non-root node) still fit.
        const frontier = try allocator.alloc(FrontierEntry, trie.frontier_cap + 1);
        const path_buf = try allocator.alloc(u8, trie.path_buf_cap + 1);
        const page_buf = try allocator.alloc(u8, pageBufferSize(page_size));
        return .{
            .frontier = frontier,
            .path_buf = path_buf,
            .page_buf = page_buf,
            .page_fba = std.heap.FixedBufferAllocator.init(page_buf),
        };
    }

    fn deinit(self: *TestHarness, allocator: std.mem.Allocator) void {
        allocator.free(self.frontier);
        allocator.free(self.path_buf);
        allocator.free(self.page_buf);
    }

    fn buffers(self: *TestHarness) Buffers {
        return .{
            .frontier = self.frontier,
            .path_buf = self.path_buf,
            .page_fba = &self.page_fba,
        };
    }
};

test "page count is correct" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try TestHarness.init(testing.allocator, &th.trie, 8);
    defer harness.deinit(testing.allocator);

    const node_pagination = NodePagination.init(harness.buffers(), &th.trie, th.trie.root(), 8);

    try testing.expectEqual(node_pagination.total_pages, 2);
}

test "work properly with simple pagination" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var harness = try TestHarness.init(testing.allocator, &th.trie, 8);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 8);

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

    var harness = try TestHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 3);

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

    var harness = try TestHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 3);

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

    var harness = try TestHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 3);

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

    var harness = try TestHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 3);

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

    var harness = try TestHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 3);

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

    var harness = try TestHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 3);

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

    var harness = try TestHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 3);

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

    var harness = try TestHarness.init(testing.allocator, &th.trie, 1);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 1);

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

    var harness = try TestHarness.init(testing.allocator, &th.trie, 16);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 16);

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

test "jump to page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var harness = try TestHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 3);

    // Jump forward past the current page.
    node_pagination.jumpToPage(3);
    const options3 = node_pagination.getOptions();
    var expected3 = [_]QueryOption{
        .{ .value = "丁1", .hint = "cd" },
        .{ .value = "丁2", .hint = "cd" },
        .{ .value = "丁3", .hint = "cd" },
    };
    try expectEqualQueryOptionSlice(expected3[0..], options3);

    // Jump backward — exercises the BFS rewind path.
    node_pagination.jumpToPage(1);
    const options1 = node_pagination.getOptions();
    var expected1 = [_]QueryOption{
        .{ .value = "甲", .hint = null },
        .{ .value = "乙", .hint = "b" },
        .{ .value = "丙1", .hint = "c" },
    };
    try expectEqualQueryOptionSlice(expected1[0..], options1);

    // Jump to the partial last page.
    node_pagination.jumpToPage(4);
    const options4 = node_pagination.getOptions();
    var expected4 = [_]QueryOption{
        .{ .value = "丁4", .hint = "ce" },
        .{ .value = "FooBar", .hint = "c;" },
    };
    try expectEqualQueryOptionSlice(expected4[0..], options4);

    // Out-of-range: silently ignored.
    node_pagination.jumpToPage(0);
    try testing.expectEqual(@as(u32, 4), node_pagination.current_page);
    node_pagination.jumpToPage(999);
    try testing.expectEqual(@as(u32, 4), node_pagination.current_page);
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
        .{ .keys = "asdfgh", .value = "World" },
    });
    defer th.deinit(testing.allocator);

    const node = th.trie.root().getChild(&th.trie, 'a').?;

    var harness = try TestHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    var node_pagination = NodePagination.init(harness.buffers(), &th.trie, node, 3);

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
        .{ .value = "World", .hint = "sdfgh" },
    };
    try expectEqualQueryOptionSlice(expected3[0..], options3);
}

// =========================================================================
// Tests — PuncPagination
// =========================================================================

const PuncTestHarness = struct {
    ph: punc_mod.PuncHandle,
    page_buf: []u8,
    page_fba: std.heap.FixedBufferAllocator,

    fn init(
        allocator: std.mem.Allocator,
        normals: []const punc_mod.NormalInput,
        page_size: u8,
    ) !PuncTestHarness {
        const ph = try punc_mod.buildPunc(allocator, normals, &.{});
        errdefer {
            var ph_mut = ph;
            ph_mut.deinit(allocator);
        }
        const page_buf = try allocator.alloc(u8, pageBufferSize(page_size));
        return .{
            .ph = ph,
            .page_buf = page_buf,
            .page_fba = std.heap.FixedBufferAllocator.init(page_buf),
        };
    }

    fn deinit(self: *PuncTestHarness, allocator: std.mem.Allocator) void {
        self.ph.deinit(allocator);
        allocator.free(self.page_buf);
    }
};

test "PuncPagination: single-candidate single page" {
    const candidates = [_][]const u8{"。"};
    var h = try PuncTestHarness.init(testing.allocator, &.{
        .{ .key = '.', .candidates = &candidates },
    }, 5);
    defer h.deinit(testing.allocator);

    const entry = h.ph.punc.lookupNormal('.') orelse return error.TestUnexpectedNull;
    var p = PuncPagination.init(entry, h.ph.punc.strings, &h.page_fba, 5);

    try testing.expectEqual(@as(u32, 1), p.total_pages);
    const opts = p.getOptions();
    try testing.expectEqual(@as(usize, 1), opts.len);
    try testing.expectEqualStrings("。", std.mem.sliceTo(opts[0].value, 0));
    try testing.expect(opts[0].hint == null);
}

test "PuncPagination: multi-candidate single page" {
    const candidates = [_][]const u8{ "「", "【", "〔", "［" };
    var h = try PuncTestHarness.init(testing.allocator, &.{
        .{ .key = '[', .candidates = &candidates },
    }, 5);
    defer h.deinit(testing.allocator);

    const entry = h.ph.punc.lookupNormal('[') orelse return error.TestUnexpectedNull;
    var p = PuncPagination.init(entry, h.ph.punc.strings, &h.page_fba, 5);

    try testing.expectEqual(@as(u32, 1), p.total_pages);
    const opts = p.getOptions();
    try testing.expectEqual(@as(usize, 4), opts.len);
    try testing.expectEqualStrings("「", std.mem.sliceTo(opts[0].value, 0));
    try testing.expectEqualStrings("【", std.mem.sliceTo(opts[1].value, 0));
    try testing.expectEqualStrings("〔", std.mem.sliceTo(opts[2].value, 0));
    try testing.expectEqualStrings("［", std.mem.sliceTo(opts[3].value, 0));
}

test "PuncPagination: pagination with small page_size" {
    const candidates = [_][]const u8{ "「", "【", "〔", "［" };
    var h = try PuncTestHarness.init(testing.allocator, &.{
        .{ .key = '[', .candidates = &candidates },
    }, 2);
    defer h.deinit(testing.allocator);

    const entry = h.ph.punc.lookupNormal('[') orelse return error.TestUnexpectedNull;
    var p = PuncPagination.init(entry, h.ph.punc.strings, &h.page_fba, 2);

    try testing.expectEqual(@as(u32, 2), p.total_pages);
    const page1 = p.getOptions();
    try testing.expectEqual(@as(usize, 2), page1.len);
    try testing.expectEqualStrings("「", std.mem.sliceTo(page1[0].value, 0));
    try testing.expectEqualStrings("【", std.mem.sliceTo(page1[1].value, 0));

    p.nextPage();
    const page2 = p.getOptions();
    try testing.expectEqual(@as(usize, 2), page2.len);
    try testing.expectEqualStrings("〔", std.mem.sliceTo(page2[0].value, 0));
    try testing.expectEqualStrings("［", std.mem.sliceTo(page2[1].value, 0));

    p.prevPage();
    try testing.expectEqual(@as(u32, 1), p.current_page);
    p.jumpToPage(2);
    try testing.expectEqual(@as(u32, 2), p.current_page);
    p.jumpToPage(0);
    try testing.expectEqual(@as(u32, 2), p.current_page);
    p.jumpToPage(99);
    try testing.expectEqual(@as(u32, 2), p.current_page);
}

test "PuncPagination: partial last page" {
    const candidates = [_][]const u8{ "「", "【", "〔" };
    var h = try PuncTestHarness.init(testing.allocator, &.{
        .{ .key = '[', .candidates = &candidates },
    }, 2);
    defer h.deinit(testing.allocator);

    const entry = h.ph.punc.lookupNormal('[') orelse return error.TestUnexpectedNull;
    var p = PuncPagination.init(entry, h.ph.punc.strings, &h.page_fba, 2);

    try testing.expectEqual(@as(u32, 2), p.total_pages);
    p.nextPage();
    const page2 = p.getOptions();
    try testing.expectEqual(@as(usize, 1), page2.len);
    try testing.expectEqualStrings("〔", std.mem.sliceTo(page2[0].value, 0));
}

test "PuncPagination: commitAtIndex returns the right candidate" {
    const candidates = [_][]const u8{ "「", "【", "〔", "［" };
    var h = try PuncTestHarness.init(testing.allocator, &.{
        .{ .key = '[', .candidates = &candidates },
    }, 2);
    defer h.deinit(testing.allocator);

    const entry = h.ph.punc.lookupNormal('[') orelse return error.TestUnexpectedNull;
    var p = PuncPagination.init(entry, h.ph.punc.strings, &h.page_fba, 2);

    try testing.expectEqualStrings("「", std.mem.sliceTo(p.commitAtIndex(0), 0));
    try testing.expectEqualStrings("【", std.mem.sliceTo(p.commitAtIndex(1), 0));

    p.nextPage();
    try testing.expectEqualStrings("〔", std.mem.sliceTo(p.commitAtIndex(0), 0));
    try testing.expectEqualStrings("［", std.mem.sliceTo(p.commitAtIndex(1), 0));
}
