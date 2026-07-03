const std = @import("std");
const testing = std.testing;

const trie_mod = @import("trie");
const Trie = trie_mod.Trie;
const Node = trie_mod.Trie.Node;
const pagination = @import("./pagination.zig");
const punc_mod = @import("./punc.zig");
const punc_fmt = @import("punc_format");

const NodePagination = pagination.NodePagination;
const PuncPagination = pagination.PuncPagination;
const QueryOption = pagination.QueryOption;

const buildTestTrie = @import("./trie_test_data.zig").buildTestTrie;

/// Longest key sequence a dictionary entry may have — single source of
/// truth is `trie.MAX_KEYS_LEN`; `trie.buildBlob` rejects longer entries
/// as a hard build error, so the unchecked `pressed_keys` writes during
/// descent can never run past the array.
pub const MAX_PRESSED_KEYS: usize = trie_mod.MAX_KEYS_LEN;

/// Bytes required for `Context.commit_scratch`, given the longest value
/// across both blobs (`max(trie.max_value_len, punc.max_value_len)`).
/// The worst-case composition is two values concatenated (case F1 in
/// `pressKey`: previous first option + new auto-committed option) plus
/// the 0 sentinel. The value-plus-one-byte cases (B, G, H: value + key
/// byte + sentinel) and the bare synth cases (A: " " + sentinel) are
/// covered too, since max_value + 2 ≤ 2 × max(max_value, 1) + 1.
pub fn commitScratchCap(max_value_len: usize) usize {
    return 2 * @max(max_value_len, 1) + 1;
}

pub const InitOptions = struct {
    trie: *const Trie,
    punc: *const punc_mod.Punc,
    page_size: u8,
};

pub const QueryResult = extern struct {
    commit: ?[*:0]const u8,
    options: ?[*]const QueryOption,
    options_count: u32,
    total_pages: u32,
    current_page: u32,
};

/// One bit per ASCII key, packed into bytes. Bit `k` set ⇒ the next press
/// of `k` (a paired key) emits the close half. Indexed directly by key.
/// Sized off `punc_fmt.TABLE_SIZE` so both lookup tables and this bitset
/// share a single source of truth for "the ASCII keyspace".
const PAIR_TOGGLE_BYTES: usize = punc_fmt.TABLE_SIZE / 8;

pub const Context = struct {
    const Self = @This();

    /// Pre-allocated buffers borrowed from the caller. In production these
    /// come from `jd_init`'s carved tail; in tests, separately allocated.
    pub const Buffers = struct {
        frontier: []pagination.FrontierEntry,
        path_buf: []u8,
        page_buf: []u8,
        /// Must be at least `commitScratchCap(max(trie.max_value_len,
        /// punc.max_value_len))` bytes.
        commit_scratch: []u8,
    };

    /// The backing allocation handed to `shared_allocator.free` in
    /// `jd_deinit`. In production this is the entire `jd_init` allocation
    /// (including the Context struct itself); in tests it's unused.
    /// Alignment is `@alignOf(usize)` because that's the max alignment
    /// of any field on Context (Self-referential @alignOf isn't allowed).
    raw: []align(@alignOf(usize)) u8,

    /// Scratch for commit-string composition (synth single byte, value+key,
    /// value+';', value+value). Returned to C as a sentinel-terminated
    /// pointer; the caller consumes before the next jd_* call. Borrowed
    /// from the caller like the other buffers, sized by
    /// `commitScratchCap` from the caps embedded in the blobs.
    commit_scratch: []u8,

    /// One entry per descended trie key; bounded by max key length.
    pressed_keys: [MAX_PRESSED_KEYS]usize,
    pressed_keys_len: u8,

    /// Persistent paired-punctuation toggle state. Bit `k` (for k in
    /// 0..255) tracks whether the next paired-press of ASCII byte `k`
    /// should emit the close half. Survives `reset()` so pairs alternate
    /// across compositions for the lifetime of the `jd_context`; cleared
    /// only on `jd_deinit`.
    pair_toggle_bits: [PAIR_TOGGLE_BYTES]u8,

    /// Backs the per-page `QueryOption` arrays and their hint strings
    /// inside `NodePagination` / `PuncPagination`. Reset on every page
    /// materialization.
    page_fba: std.heap.FixedBufferAllocator,

    /// BFS frontier + path bytes for any active trie `NodePagination`.
    /// Shared across successive paginators on this context.
    frontier_buf: []pagination.FrontierEntry,
    path_buf: []u8,

    trie: *const Trie,
    punc: *const punc_mod.Punc,
    root_node: *const Node,
    page_size: u8,
    node: *const Node,
    pager: ?pagination.Pager,

    /// Constructs a Context from pre-allocated buffers. The caller (jd_init
    /// or a test harness) provides storage for the four variable-sized
    /// regions; the inline fields (pressed_keys, page_fba,
    /// pair_toggle_bits) live inside the returned struct. `raw` is left
    /// undefined — jd_init sets it explicitly after the carved layout is
    /// known; tests don't touch it.
    pub fn init(buffers: Buffers, options: InitOptions) Self {
        const root_node = options.trie.root();
        return .{
            .raw = undefined,
            .commit_scratch = buffers.commit_scratch,
            .pressed_keys = undefined,
            .pressed_keys_len = 0,
            .pair_toggle_bits = @splat(0),
            .page_fba = std.heap.FixedBufferAllocator.init(buffers.page_buf),
            .frontier_buf = buffers.frontier,
            .path_buf = buffers.path_buf,
            .trie = options.trie,
            .punc = options.punc,
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
        return @ptrCast(self.commit_scratch.ptr);
    }

    /// Concatenate `prev` (if non-null) and `value` into `commit_scratch`
    /// and return a sentinel-terminated pointer. Both inputs are read via
    /// `sliceTo(... ,0)` so they may be rodata pointers from any pool.
    fn commitWithPrefix(self: *Self, prev: ?[*:0]const u8, value: [*:0]const u8) [*:0]const u8 {
        var total_len: usize = 0;
        if (prev) |pc| {
            const prev_bytes = std.mem.sliceTo(pc, 0);
            @memcpy(self.commit_scratch[0..prev_bytes.len], prev_bytes);
            total_len = prev_bytes.len;
        }
        const value_bytes = std.mem.sliceTo(value, 0);
        @memcpy(self.commit_scratch[total_len..][0..value_bytes.len], value_bytes);
        total_len += value_bytes.len;
        return self.scratchCommit(total_len);
    }

    /// Reads the toggle bit for `key` and atomically flips it. Returns
    /// the PRE-flip value (true ⇒ this commit should emit the close half).
    fn flipPairToggle(self: *Self, key: u8) bool {
        const byte_idx: usize = key / 8;
        const bit_mask: u8 = @as(u8, 1) << @intCast(key % 8);
        const was_set = (self.pair_toggle_bits[byte_idx] & bit_mask) != 0;
        self.pair_toggle_bits[byte_idx] ^= bit_mask;
        return was_set;
    }

    /// If a trie pager is currently active, commit its first option and
    /// fully reset the trie composition state. Returns the committed bytes
    /// (a rodata pointer) or null if no trie pager was active.
    fn commitTriePagerIfActive(self: *Self) ?[*:0]const u8 {
        if (self.pager) |*p| {
            if (p.* == .trie) {
                const prev = p.commitAtIndex(0);
                self.pager = null;
                self.node = self.root_node;
                self.pressed_keys_len = 0;
                return prev;
            }
        }
        return null;
    }

    pub fn reset(self: *Self) void {
        self.node = self.root_node;
        self.pager = null;
        self.pressed_keys_len = 0;
        // pair_toggle_bits intentionally NOT reset — see field docs.
    }

    pub fn pressKey(self: *Self, key: u8) QueryResult {
        // ============================================================
        // Cases that pick an option from the current pager (any kind).
        // ============================================================

        // Case A: space — commit first option (rodata pointer), else synth " ".
        if (key == ' ') {
            if (self.pager) |*p| {
                const opts = p.getOptions();
                if (opts.len >= 1) {
                    const commit = p.commitAtIndex(0);
                    self.reset();
                    return commitOnly(commit);
                }
            }
            self.commit_scratch[0] = ' ';
            const commit = self.scratchCommit(1);
            self.reset();
            return commitOnly(commit);
        }

        // Case B: ';' with no ';' child of current node — only meaningful
        // when the active pager is a trie pager (punc pagers don't shadow
        // ';'). Commits the 2nd option, or option[0] + ';' as fallback.
        if (key == ';' and self.node.getChild(self.trie, ';') == null) {
            if (self.pager) |*p| {
                if (p.* == .trie) {
                    const options = p.getOptions();
                    if (options.len >= 2) {
                        const commit = p.commitAtIndex(1);
                        self.reset();
                        return commitOnly(commit);
                    } else {
                        const original = std.mem.sliceTo(options[0].value, 0);
                        @memcpy(self.commit_scratch[0..original.len], original);
                        self.commit_scratch[original.len] = ';';
                        const commit = self.scratchCommit(original.len + 1);
                        self.reset();
                        return commitOnly(commit);
                    }
                }
            }
        }

        // Numeric candidate-selector bindings (`1`-`9` and the like) are
        // intentionally NOT handled here. Picking a non-first candidate
        // from a candidate window is the IME's responsibility — see
        // docs/integration.md. Digits reaching this function therefore
        // fall through to the trie/fallback cases, where they get
        // appended literally to any in-flight commit.

        // ============================================================
        // From here, the key didn't pick from the current pager.
        // If a punc (normal-multi-candidate) pager is still active, the
        // user is abandoning the window — commit its first option and
        // proceed.
        // ============================================================
        var prev_commit: ?[*:0]const u8 = null;
        if (self.pager) |*p| {
            if (p.* == .punc) {
                prev_commit = p.commitAtIndex(0);
                self.pager = null;
                self.node = self.root_node;
                self.pressed_keys_len = 0;
            }
        }

        // ============================================================
        // Case C: paired punctuation. Single-press commit with toggle.
        // ============================================================
        if (self.punc.lookupPaired(key)) |paired_entry| {
            if (prev_commit == null) {
                prev_commit = self.commitTriePagerIfActive();
            }

            const emit_close = self.flipPairToggle(key);
            const value_ptr = if (emit_close)
                self.punc.closeValue(paired_entry)
            else
                self.punc.openValue(paired_entry);

            const commit = self.commitWithPrefix(prev_commit, value_ptr);
            self.reset();
            return commitOnly(commit);
        }

        // ============================================================
        // Case D: normal punctuation. Auto-commit if single candidate,
        // otherwise open a candidate window.
        // ============================================================
        if (self.punc.lookupNormal(key)) |normal_entry| {
            if (prev_commit == null) {
                prev_commit = self.commitTriePagerIfActive();
            }

            if (normal_entry.candidates_count == 1) {
                const value_ptr: [*:0]const u8 =
                    @ptrCast(&self.punc.strings[normal_entry.values_offset]);
                const commit = self.commitWithPrefix(prev_commit, value_ptr);
                self.reset();
                return commitOnly(commit);
            }

            self.pager = .{ .punc = PuncPagination.init(
                normal_entry,
                self.punc.strings,
                &self.page_fba,
                self.page_size,
            ) };
            self.node = self.root_node;
            self.pressed_keys_len = 0;

            const options = self.pager.?.getOptions();
            return .{
                .commit = prev_commit,
                .options = options.ptr,
                .options_count = self.pager.?.totalOptions(),
                .total_pages = self.pager.?.totalPages(),
                .current_page = 1,
            };
        }

        // ============================================================
        // Trie descent cases (E, F, G, H). `prev_commit` may be set if
        // the user was in a punc window and pressed a non-punc key.
        // ============================================================

        // Case E: descend into a child of the current node.
        if (self.node.getChild(self.trie, key)) |node| {
            const key_index = self.node.indexOfChild(self.trie, key).?;

            self.node = node;
            self.pager = .{ .trie = NodePagination.init(self.paginationBuffers(), self.trie, node, self.page_size) };
            self.pressed_keys[self.pressed_keys_len] = key_index;
            self.pressed_keys_len += 1;

            const options = self.pager.?.getOptions();

            // E1: single option no hint — auto-commit. If prev_commit is set,
            // concat into scratch; otherwise return the rodata pointer.
            if (options.len == 1 and options[0].hint == null) {
                if (prev_commit) |_| {
                    const commit = self.commitWithPrefix(prev_commit, options[0].value);
                    self.reset();
                    return commitOnly(commit);
                } else {
                    const commit = options[0].value;
                    self.reset();
                    return commitOnly(commit);
                }
            }

            return .{
                .commit = prev_commit,
                .options = options.ptr,
                .options_count = self.pager.?.totalOptions(),
                .total_pages = self.pager.?.totalPages(),
                .current_page = 1,
            };
        } else if (self.root_node.getChild(self.trie, key)) |node| {
            // Case F: current node has no child with `key`, but root does —
            // commit the previous page's first option (rodata), then jump.
            //
            // prev_commit cannot be set here: it's set only when we exited a
            // punc window (which resets self.node to root_node and
            // pressed_keys_len to 0). If self.node == root_node, the
            // `self.node.getChild(...)` branch above would have matched.
            std.debug.assert(prev_commit == null);

            const prev_value = self.pager.?.getOptions()[0].value; // rodata

            self.node = node;
            self.pager = .{ .trie = NodePagination.init(self.paginationBuffers(), self.trie, node, self.page_size) };
            self.pressed_keys_len = 0;
            self.pressed_keys[self.pressed_keys_len] = self.root_node.indexOfChild(self.trie, key).?;
            self.pressed_keys_len += 1;

            const options = self.pager.?.getOptions();

            // F1: single option no hint — concat prev + new into scratch.
            if (options.len == 1 and options[0].hint == null) {
                const prev = std.mem.sliceTo(prev_value, 0);
                const curr = std.mem.sliceTo(options[0].value, 0);
                @memcpy(self.commit_scratch[0..prev.len], prev);
                @memcpy(self.commit_scratch[prev.len..][0..curr.len], curr);
                const commit = self.scratchCommit(prev.len + curr.len);
                self.reset();
                return commitOnly(commit);
            }

            return .{
                .commit = prev_value, // rodata
                .options = options.ptr,
                .options_count = self.pager.?.totalOptions(),
                .total_pages = self.pager.?.totalPages(),
                .current_page = 1,
            };
        }

        // Case G: at root, key has no child — commit (prev_commit if any +) the key byte.
        if (self.node == self.root_node) {
            var total_len: usize = 0;
            if (prev_commit) |pc| {
                const prev_bytes = std.mem.sliceTo(pc, 0);
                @memcpy(self.commit_scratch[0..prev_bytes.len], prev_bytes);
                total_len = prev_bytes.len;
            }
            self.commit_scratch[total_len] = key;
            total_len += 1;
            const commit = self.scratchCommit(total_len);
            self.reset();
            return commitOnly(commit);
        } else {
            // Case H: deep in the trie, key has no matching descent — commit
            // the current first option with `key` appended.
            // prev_commit cannot be set here (would require self.node == root).
            std.debug.assert(prev_commit == null);
            const options = self.pager.?.getOptions();
            const original = std.mem.sliceTo(options[0].value, 0);
            @memcpy(self.commit_scratch[0..original.len], original);
            self.commit_scratch[original.len] = key;
            const commit = self.scratchCommit(original.len + 1);
            self.reset();
            return commitOnly(commit);
        }
    }

    pub fn nextPage(self: *Self) QueryResult {
        if (self.pager) |*p| {
            p.nextPage();
            return .{
                .commit = null,
                .options = p.getOptions().ptr,
                .options_count = p.totalOptions(),
                .total_pages = p.totalPages(),
                .current_page = p.currentPage(),
            };
        }
        return emptyResult();
    }

    pub fn prevPage(self: *Self) QueryResult {
        if (self.pager) |*p| {
            p.prevPage();
            return .{
                .commit = null,
                .options = p.getOptions().ptr,
                .options_count = p.totalOptions(),
                .total_pages = p.totalPages(),
                .current_page = p.currentPage(),
            };
        }
        return emptyResult();
    }

    pub fn jumpToPage(self: *Self, page: u32) QueryResult {
        if (self.pager) |*p| {
            p.jumpToPage(page);
            return .{
                .commit = null,
                .options = p.getOptions().ptr,
                .options_count = p.totalOptions(),
                .total_pages = p.totalPages(),
                .current_page = p.currentPage(),
            };
        }
        return emptyResult();
    }

    pub fn backspace(self: *Self) QueryResult {
        // If we're in a punc candidate window, backspace just closes it.
        if (self.pager) |*p| {
            if (p.* == .punc) {
                self.pager = null;
                self.pressed_keys_len = 0;
                self.node = self.root_node;
                return emptyResult();
            }
        }

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
                self.pager = .{ .trie = NodePagination.init(self.paginationBuffers(), self.trie, self.node, self.page_size) };

                return .{
                    .commit = null,
                    .options = self.pager.?.getOptions().ptr,
                    .options_count = self.pager.?.totalOptions(),
                    .total_pages = self.pager.?.totalPages(),
                    .current_page = 1,
                };
            }
        } else {
            return emptyResult();
        }
    }
};

inline fn commitOnly(commit: [*:0]const u8) QueryResult {
    return .{
        .commit = commit,
        .options = null,
        .options_count = 0,
        .total_pages = 0,
        .current_page = 0,
    };
}

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

/// Wraps the heap regions a `Context` borrows so each test can build and
/// tear them down without repeating the boilerplate. In production this
/// work is done by `jd_init`.
///
/// The PuncHandle is heap-allocated so its `punc` field's address stays
/// stable when this struct is returned-by-value from `init` (the ctx
/// holds a pointer to it).
const ContextHarness = struct {
    ctx: Context,
    frontier: []pagination.FrontierEntry,
    path_buf: []u8,
    page_buf: []u8,
    commit_scratch: []u8,
    punc_handle: *punc_mod.PuncHandle,

    fn init(
        allocator: std.mem.Allocator,
        trie: *const Trie,
        page_size: u8,
    ) !ContextHarness {
        return ContextHarness.initWithPunc(allocator, trie, page_size, &.{}, &.{});
    }

    fn initWithPunc(
        allocator: std.mem.Allocator,
        trie: *const Trie,
        page_size: u8,
        normals: []const punc_mod.NormalInput,
        paireds: []const punc_mod.PairedInput,
    ) !ContextHarness {
        const frontier = try allocator.alloc(pagination.FrontierEntry, trie.frontier_cap + 1);
        errdefer allocator.free(frontier);
        const path_buf = try allocator.alloc(u8, trie.path_buf_cap + 1);
        errdefer allocator.free(path_buf);
        const page_buf = try allocator.alloc(u8, pagination.pageBufferSize(page_size));
        errdefer allocator.free(page_buf);
        const punc_handle = try allocator.create(punc_mod.PuncHandle);
        errdefer allocator.destroy(punc_handle);
        punc_handle.* = try punc_mod.buildPunc(allocator, normals, paireds);
        errdefer punc_handle.deinit(allocator);
        // Exactly the production formula — no slack, so a composition that
        // outgrows the cap fails the safety-checked test build.
        const commit_scratch = try allocator.alloc(u8, commitScratchCap(
            @max(trie.max_value_len, punc_handle.punc.max_value_len),
        ));
        errdefer allocator.free(commit_scratch);
        var self = ContextHarness{
            .ctx = undefined,
            .frontier = frontier,
            .path_buf = path_buf,
            .page_buf = page_buf,
            .commit_scratch = commit_scratch,
            .punc_handle = punc_handle,
        };
        self.ctx = Context.init(.{
            .frontier = frontier,
            .path_buf = path_buf,
            .page_buf = page_buf,
            .commit_scratch = commit_scratch,
        }, .{ .trie = trie, .punc = &punc_handle.punc, .page_size = page_size });
        return self;
    }

    fn deinit(self: *ContextHarness, allocator: std.mem.Allocator) void {
        allocator.free(self.frontier);
        allocator.free(self.path_buf);
        allocator.free(self.page_buf);
        allocator.free(self.commit_scratch);
        self.punc_handle.deinit(allocator);
        allocator.destroy(self.punc_handle);
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

test "digit after composition commits first option + literal digit" {
    // The engine does NOT pick from '1'-'9' — that's the IME's job per
    // docs/integration.md. Digits fall through to the literal-append path.
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    const query_result = context.pressKey('2');

    try testing.expectEqualStrings("甲2", std.mem.sliceTo(query_result.commit.?, 0));
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

    _ = context.pressKey('a');
    _ = context.backspace();

    const query_result = context.backspace();
    try testing.expectEqual(@as(?[*:0]const u8, null), query_result.commit);
    try testing.expectEqual(@as(?[*]const QueryOption, null), query_result.options);

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

// =========================================================================
// Tests — punctuation integration
// =========================================================================

test "single-candidate normal punc commits directly from root" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const candidates = [_][]const u8{"。"};
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '.', .candidates = &candidates },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &normals, &.{});
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    const r = context.pressKey('.');
    try testing.expectEqualStrings("。", std.mem.sliceTo(r.commit.?, 0));
    try testing.expectEqual(@as(?[*]const QueryOption, null), r.options);
}

test "single-candidate punc commits trie + punc after composition" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const candidates = [_][]const u8{"。"};
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '.', .candidates = &candidates },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &normals, &.{});
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    const r = context.pressKey('.');
    try testing.expectEqualStrings("甲。", std.mem.sliceTo(r.commit.?, 0));
    try testing.expectEqual(@as(?[*]const QueryOption, null), r.options);
}

test "multi-candidate punc opens window" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const candidates = [_][]const u8{ "「", "【", "〔", "［" };
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '[', .candidates = &candidates },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &normals, &.{});
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    const r = context.pressKey('[');
    try testing.expectEqual(@as(?[*:0]const u8, null), r.commit);
    try testing.expectEqual(@as(u32, 4), r.options_count);
    try testing.expectEqual(@as(u32, 2), r.total_pages);
    try testing.expectEqual(@as(u32, 1), r.current_page);
    try testing.expectEqualStrings("「", std.mem.sliceTo(r.options.?[0].value, 0));
    try testing.expectEqualStrings("【", std.mem.sliceTo(r.options.?[1].value, 0));
    try testing.expectEqualStrings("〔", std.mem.sliceTo(r.options.?[2].value, 0));
    // Picking a non-first candidate (e.g. `【` at index 1) is the IME's
    // job — the engine doesn't handle `1`-`9` as candidate selectors.
}

test "punc window: next page" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const candidates = [_][]const u8{ "「", "【", "〔", "［" };
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '[', .candidates = &candidates },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 2, &normals, &.{});
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('[');
    const r = context.nextPage();
    try testing.expectEqual(@as(u32, 2), r.current_page);
    try testing.expectEqualStrings("〔", std.mem.sliceTo(r.options.?[0].value, 0));
    try testing.expectEqualStrings("［", std.mem.sliceTo(r.options.?[1].value, 0));
}

test "paired punc toggles on consecutive presses" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const paireds = [_]punc_mod.PairedInput{
        .{ .key = '"', .open = "“", .close = "”" },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &.{}, &paireds);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    const r1 = context.pressKey('"');
    try testing.expectEqualStrings("“", std.mem.sliceTo(r1.commit.?, 0));

    const r2 = context.pressKey('"');
    try testing.expectEqualStrings("”", std.mem.sliceTo(r2.commit.?, 0));

    const r3 = context.pressKey('"');
    try testing.expectEqualStrings("“", std.mem.sliceTo(r3.commit.?, 0));
}

test "paired toggle survives non-paired commits in between" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const paireds = [_]punc_mod.PairedInput{
        .{ .key = '"', .open = "“", .close = "”" },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &.{}, &paireds);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('"'); // commits “, toggle for '"' → 1
    _ = context.pressKey('a');
    _ = context.pressKey(' '); // commit 甲
    const r = context.pressKey('"');
    try testing.expectEqualStrings("”", std.mem.sliceTo(r.commit.?, 0));
}

test "two paired keys have independent toggles" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const paireds = [_]punc_mod.PairedInput{
        .{ .key = '"', .open = "“", .close = "”" },
        .{ .key = '\'', .open = "‘", .close = "’" },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &.{}, &paireds);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('"'); // “
    _ = context.pressKey('\''); // ‘
    const r1 = context.pressKey('"'); // ”
    try testing.expectEqualStrings("”", std.mem.sliceTo(r1.commit.?, 0));
    const r2 = context.pressKey('\''); // ’
    try testing.expectEqualStrings("’", std.mem.sliceTo(r2.commit.?, 0));
}

test "punc window: backspace closes window" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const candidates = [_][]const u8{ "「", "【" };
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '[', .candidates = &candidates },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &normals, &.{});
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('[');
    const r = context.backspace();
    try testing.expectEqual(@as(?[*:0]const u8, null), r.commit);
    try testing.expectEqual(@as(?[*]const QueryOption, null), r.options);
}

test "punc window: pressing a trie key commits punc[0] and starts trie composition" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const candidates = [_][]const u8{ "「", "【" };
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '[', .candidates = &candidates },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &normals, &.{});
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('[');
    const r = context.pressKey('a');
    try testing.expectEqualStrings("「", std.mem.sliceTo(r.commit.?, 0));
    try testing.expectEqual(@as(u32, 11), r.options_count);
    try testing.expectEqualStrings("甲", std.mem.sliceTo(r.options.?[0].value, 0));
}

test "punc window: pressing space commits the displayed first option" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const candidates = [_][]const u8{ "「", "【" };
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '[', .candidates = &candidates },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &normals, &.{});
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('[');
    const r = context.pressKey(' ');
    try testing.expectEqualStrings("「", std.mem.sliceTo(r.commit.?, 0));
}

test "punc window: pressing punc key again commits and re-opens window" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const candidates = [_][]const u8{ "「", "【" };
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '[', .candidates = &candidates },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &normals, &.{});
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('[');
    const r = context.pressKey('[');
    try testing.expectEqualStrings("「", std.mem.sliceTo(r.commit.?, 0));
    try testing.expectEqual(@as(u32, 2), r.options_count);
}

test "trie composition + paired key commits both" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const paireds = [_]punc_mod.PairedInput{
        .{ .key = '"', .open = "“", .close = "”" },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &.{}, &paireds);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    const r = context.pressKey('"');
    try testing.expectEqualStrings("甲“", std.mem.sliceTo(r.commit.?, 0));
}

// =========================================================================
// Long-value regression tests.
//
// The dictionary contains values far longer than the old fixed 128-byte
// scratch buffer (the longest is 300 bytes). commit_scratch is now sized
// from `max_value_len` embedded in the blobs; the harness allocates it
// with the exact production formula (`commitScratchCap`, zero slack), so
// any composition that outgrows the cap trips the bounds checks of the
// safety-checked test build. Each test below drives one scratch-composing
// case in `pressKey` with values that would have overflowed 128 bytes.
// =========================================================================

const LONG_A = "季" ** 100; // 300 bytes — matches the longest real entry
const LONG_B = "鸡" ** 80; // 240 bytes

fn buildLongValueTrie(allocator: std.mem.Allocator) !trie_mod.TrieHandle {
    return trie_mod.buildTrie(allocator, &.{
        .{ .keys = "aa", .value = LONG_A },
        .{ .keys = "ac", .value = "X" },
        .{ .keys = "b", .value = LONG_B },
    });
}

test "long values: case F1 concatenates two long values into scratch" {
    var th = try buildLongValueTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    // 'a' opens a pager whose first option is LONG_A (child order a < c).
    _ = context.pressKey('a');
    // 'b' is no child of node "a" but is a child of the root, and node "b"
    // has a single hint-less option: commit LONG_A ++ LONG_B (540 bytes).
    const r = context.pressKey('b');
    try testing.expectEqualStrings(LONG_A ++ LONG_B, std.mem.sliceTo(r.commit.?, 0));
}

test "long values: case H appends a literal byte to a long first option" {
    var th = try buildLongValueTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    _ = context.pressKey('a');
    const r = context.pressKey('1');
    try testing.expectEqualStrings(LONG_A ++ "1", std.mem.sliceTo(r.commit.?, 0));
}

test "long values: case B fallback appends ';' to a long single option" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "aa", .value = LONG_A },
    });
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie, 3);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    // Single option WITH hint ("a"), so no E1 auto-commit; pager stays open.
    _ = context.pressKey('a');
    const r = context.pressKey(';');
    try testing.expectEqualStrings(LONG_A ++ ";", std.mem.sliceTo(r.commit.?, 0));
}

test "long values: punctuation after a long composition commits both" {
    var th = try buildLongValueTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const dot_candidates = [_][]const u8{"。"};
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '.', .candidates = &dot_candidates },
    };
    const paireds = [_]punc_mod.PairedInput{
        .{ .key = '"', .open = "“", .close = "”" },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &normals, &paireds);
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    // Case D (normal, single candidate) after a long in-flight composition.
    _ = context.pressKey('a');
    const r1 = context.pressKey('.');
    try testing.expectEqualStrings(LONG_A ++ "。", std.mem.sliceTo(r1.commit.?, 0));

    // Case C (paired) after a long in-flight composition.
    _ = context.pressKey('a');
    const r2 = context.pressKey('"');
    try testing.expectEqualStrings(LONG_A ++ "“", std.mem.sliceTo(r2.commit.?, 0));
}

test "long values: E1 auto-commit concatenates an abandoned punc window" {
    var th = try buildLongValueTrie(testing.allocator);
    defer th.deinit(testing.allocator);

    const bracket_candidates = [_][]const u8{ "「", "【" };
    const normals = [_]punc_mod.NormalInput{
        .{ .key = '[', .candidates = &bracket_candidates },
    };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, 3, &normals, &.{});
    defer harness.deinit(testing.allocator);
    const context = &harness.ctx;

    // '[' opens a punc candidate window; 'b' abandons it (committing 「)
    // and descends to node "b", whose single hint-less option LONG_B
    // auto-commits — concatenated into scratch as 「 ++ LONG_B.
    _ = context.pressKey('[');
    const r = context.pressKey('b');
    try testing.expectEqualStrings("「" ++ LONG_B, std.mem.sliceTo(r.commit.?, 0));
}
