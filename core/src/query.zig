//! The interactive query state machine behind the C ABI.
//!
//! Two independent positions matter here, and keeping them separate is the
//! central design decision:
//!
//!   - **`state.anchor_index`** — the flat candidate index the user is
//!     looking at. Every *automatic* commit the engine makes resolves
//!     against it: space and the fallbacks take `anchor + 0`, `;` takes
//!     `anchor + 1`. It moves only on an explicit `setAnchor` or when a new
//!     composition starts.
//!   - **the BFS enumeration cursor** inside `pagination.NodePagination` —
//!     purely internal. `readRange` moves it freely, which is what lets a
//!     frontend prefetch a candidate strip arbitrarily far ahead without
//!     changing what space would commit.
//!
//! The two options the anchor needs are cached in `anchor_opts`, so the
//! cursor may roam without ever having to rewind to serve a commit.
//!
//! Commit strings are never assembled into a buffer. Every commit the
//! engine can produce is at most `<immortal string> + (<immortal string> |
//! <one literal byte>)`:
//!
//!   case A   space          → anchor[0]              | " "
//!   case B   `;` fallthrough→ anchor[1]              | anchor[0] + ';'
//!   case C   paired punc    → [prev +] open/close half
//!   case D   normal punc    → [prev +] candidate
//!   case E1  auto-commit    → [prev +] the sole option
//!   case F1  drill + commit → prev + the sole option
//!   case G   root fallback  → [prev +] the key byte
//!   case H   deep fallback  → anchor[0] + the key byte
//!
//! No case needs three segments (the `prev == null` assertions in F and H
//! are what rule it out), so `JdState` carries two immortal pointers plus
//! one inline byte and the engine needs no scratch buffer at all.

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

/// Capacity of the per-context read scratch handed out by
/// `jd_scratch_ptr`. It exists for hosts that cannot allocate memory the
/// engine can write into — notably a WebAssembly host, which has no malloc
/// inside linear memory. Native callers normally pass their own buffer to
/// `readRange` instead and get true zero-copy accumulation.
pub const SCRATCH_OPTIONS: usize = 64;

/// One bit per ASCII key, packed into bytes. Bit `k` set ⇒ the next press
/// of `k` (a paired key) emits the close half. Indexed directly by key.
/// Sized off `punc_fmt.TABLE_SIZE` so both lookup tables and this bitset
/// share a single source of truth for "the ASCII keyspace".
const PAIR_TOGGLE_BYTES: usize = punc_fmt.TABLE_SIZE / 8;

/// Mirrors `jd_state` in `include/jd.h`. Every field is either an immortal
/// pointer (into an embedded blob) or an inline value, so a copy of this
/// struct stays valid forever — there is no invalidation rule.
pub const JdState = extern struct {
    /// First commit segment, or null when nothing was committed.
    commit_a: ?[*:0]const u8,
    /// Second commit segment, appended directly after `commit_a`.
    commit_b: ?[*:0]const u8,
    /// A single literal byte appended last; 0 means none.
    commit_lit: u8,
    /// Total candidates for the in-flight composition; 0 when none.
    options_count: u32,
    /// Flat index the engine's automatic commits resolve against.
    anchor_index: u32,
};

/// Join a state's commit segments in the canonical order into `buf`, the
/// way a frontend would. Returns null when nothing was committed.
/// `buf` must hold `2 * max_value_len + 1` bytes for the worst case.
pub fn joinCommit(state: *const JdState, buf: []u8) ?[]const u8 {
    if (state.commit_a == null and state.commit_b == null and state.commit_lit == 0) return null;
    var len: usize = 0;
    inline for (.{ state.commit_a, state.commit_b }) |seg| {
        if (seg) |p| {
            const bytes = std.mem.sliceTo(p, 0);
            @memcpy(buf[len..][0..bytes.len], bytes);
            len += bytes.len;
        }
    }
    if (state.commit_lit != 0) {
        buf[len] = state.commit_lit;
        len += 1;
    }
    return buf[0..len];
}

pub const InitOptions = struct {
    trie: *const Trie,
    punc: *const punc_mod.Punc,
};

pub const Context = struct {
    const Self = @This();

    /// Pre-allocated buffers borrowed from the caller. In production these
    /// come from `jd_init`'s carved tail; in tests, separately allocated.
    pub const Buffers = struct {
        frontier: []pagination.FrontierEntry,
        path_buf: []u8,
    };

    /// The backing allocation handed to `shared_allocator.free` in
    /// `jd_deinit`. In production this is the entire `jd_init` allocation
    /// (including the Context struct itself); in tests it's unused.
    raw: []align(@alignOf(usize)) u8,

    /// One entry per descended trie key; bounded by max key length.
    pressed_keys: [MAX_PRESSED_KEYS]usize,
    pressed_keys_len: u8,

    /// Persistent paired-punctuation toggle state. Bit `k` tracks whether
    /// the next paired-press of ASCII byte `k` should emit the close half.
    /// Survives `reset()` so pairs alternate across compositions for the
    /// lifetime of the context; cleared only on `jd_deinit`.
    pair_toggle_bits: [PAIR_TOGGLE_BYTES]u8,

    /// The options at `[anchor_index, anchor_index + 2)` — everything the
    /// engine's automatic commits can need (index 0 for space / drill-in /
    /// literal fallbacks, index 1 for `;`). Caching them is what decouples
    /// the anchor from the enumeration cursor: `readRange` may move the
    /// cursor anywhere without forcing a rewind to serve a commit.
    /// `anchor_len` is how many entries are valid (0, 1, or 2).
    anchor_opts: [2]QueryOption,
    anchor_len: u8,

    /// Caller-visible state. `jd_state_ptr` hands out a pointer to this
    /// field; the pointer is stable for the context's lifetime.
    state: JdState,

    /// Read scratch for hosts without their own buffer — see
    /// `SCRATCH_OPTIONS`.
    scratch: [SCRATCH_OPTIONS]QueryOption,

    /// BFS frontier + path bytes for any active trie enumeration. Shared
    /// across successive paginators on this context.
    frontier_buf: []pagination.FrontierEntry,
    path_buf: []u8,

    trie: *const Trie,
    punc: *const punc_mod.Punc,
    root_node: *const Node,
    node: *const Node,
    pager: ?pagination.Pager,

    /// Constructs a Context from pre-allocated buffers. `raw` is left
    /// undefined — `jd_init` sets it once the carved layout is known; tests
    /// don't touch it.
    pub fn init(buffers: Buffers, options: InitOptions) Self {
        const root_node = options.trie.root();
        return .{
            .raw = undefined,
            .pressed_keys = undefined,
            .pressed_keys_len = 0,
            .pair_toggle_bits = @splat(0),
            .anchor_opts = undefined,
            .anchor_len = 0,
            .state = .{
                .commit_a = null,
                .commit_b = null,
                .commit_lit = 0,
                .options_count = 0,
                .anchor_index = 0,
            },
            .scratch = undefined,
            .frontier_buf = buffers.frontier,
            .path_buf = buffers.path_buf,
            .trie = options.trie,
            .punc = options.punc,
            .root_node = root_node,
            .node = root_node,
            .pager = null,
        };
    }

    fn paginationBuffers(self: *Self) pagination.Buffers {
        return .{ .frontier = self.frontier_buf, .path_buf = self.path_buf };
    }

    // ---------------------------------------------------------------
    // Commit recording
    // ---------------------------------------------------------------

    fn setCommit(self: *Self, a: ?[*:0]const u8, b: ?[*:0]const u8, lit: u8) void {
        self.state.commit_a = a;
        self.state.commit_b = b;
        self.state.commit_lit = lit;
    }

    fn clearCommit(self: *Self) void {
        self.setCommit(null, null, 0);
    }

    /// `prev` (optional) followed by `value`, collapsing to a single
    /// segment when there is no prefix.
    fn setCommitWithPrefix(self: *Self, prev: ?[*:0]const u8, value: [*:0]const u8) void {
        if (prev) |p| self.setCommit(p, value, 0) else self.setCommit(value, null, 0);
    }

    // ---------------------------------------------------------------
    // Anchor
    // ---------------------------------------------------------------

    /// Re-materialize `anchor_opts` from the pager at the current anchor.
    fn refreshAnchor(self: *Self) void {
        self.anchor_len = 0;
        if (self.pager) |*p| {
            const n = p.readRange(self.state.anchor_index, 2, &self.anchor_opts);
            self.anchor_len = @intCast(n);
        }
    }

    fn anchorOption(self: *const Self, i: usize) ?QueryOption {
        if (i >= self.anchor_len) return null;
        return self.anchor_opts[i];
    }

    /// Point the anchor at a new candidate index. Out-of-range requests are
    /// silently ignored, so callers can pass any `u32` unguarded.
    pub fn setAnchor(self: *Self, index: u32) void {
        self.clearCommit();
        if (self.pager) |*p| {
            if (index < p.totalOptions()) {
                self.state.anchor_index = index;
                self.refreshAnchor();
            }
        }
    }

    /// Read the options at `[start, start + count)` into `out`. Pure with
    /// respect to everything the caller can observe — it never moves the
    /// anchor, and `QueryOption` holds nothing that can dangle.
    pub fn readRange(self: *Self, start: u32, count: u32, out: []QueryOption) u32 {
        if (self.pager) |*p| return p.readRange(start, count, out);
        return 0;
    }

    // ---------------------------------------------------------------
    // Composition lifecycle
    // ---------------------------------------------------------------

    /// Drop the in-flight composition, leaving any recorded commit alone.
    /// Used by the commit paths in `pressKey`.
    fn endComposition(self: *Self) void {
        self.node = self.root_node;
        self.pager = null;
        self.pressed_keys_len = 0;
        self.anchor_len = 0;
        self.state.options_count = 0;
        self.state.anchor_index = 0;
        // pair_toggle_bits intentionally NOT reset — see field docs.
    }

    /// Public reset: drop both the composition and any recorded commit.
    pub fn reset(self: *Self) void {
        self.clearCommit();
        self.endComposition();
    }

    /// Install a fresh trie enumeration rooted at `node` and park the
    /// anchor at its first candidate.
    fn startTriePager(self: *Self, node: *const Node) void {
        self.pager = .{ .trie = NodePagination.init(self.paginationBuffers(), self.trie, node) };
        self.state.anchor_index = 0;
        self.refreshAnchor();
    }

    /// Reads the toggle bit for `key` and flips it. Returns the PRE-flip
    /// value (true ⇒ this commit should emit the close half).
    fn flipPairToggle(self: *Self, key: u8) bool {
        const byte_idx: usize = key / 8;
        const bit_mask: u8 = @as(u8, 1) << @intCast(key % 8);
        const was_set = (self.pair_toggle_bits[byte_idx] & bit_mask) != 0;
        self.pair_toggle_bits[byte_idx] ^= bit_mask;
        return was_set;
    }

    /// If a trie enumeration is active, take its anchor option as a commit
    /// and tear the composition down. Returns the committed bytes (an
    /// immortal pointer) or null if no trie pager was active.
    fn commitTriePagerIfActive(self: *Self) ?[*:0]const u8 {
        if (self.pager) |*p| {
            if (p.* == .trie) {
                const value = self.anchorOption(0).?.value;
                self.endComposition();
                return value;
            }
        }
        return null;
    }

    // ---------------------------------------------------------------
    // Key dispatch
    // ---------------------------------------------------------------

    pub fn pressKey(self: *Self, key: u8) void {
        self.clearCommit();

        // ============================================================
        // Cases that pick an option at the anchor (any pager kind).
        // ============================================================

        // Case A: space — commit the anchor option, else synthesize " ".
        if (key == ' ') {
            if (self.anchorOption(0)) |opt| {
                self.setCommit(opt.value, null, 0);
            } else {
                self.setCommit(null, null, ' ');
            }
            self.endComposition();
            return;
        }

        // Case B: ';' with no ';' child of the current node — only
        // meaningful when the active pager is a trie pager (punc pagers
        // don't shadow ';'). Commits the anchor's 2nd option, or its 1st
        // with ';' appended as a fallback.
        if (key == ';' and self.node.getChild(self.trie, ';') == null) {
            if (self.pager) |*p| {
                if (p.* == .trie) {
                    if (self.anchorOption(1)) |second| {
                        self.setCommit(second.value, null, 0);
                    } else {
                        // A trie pager always has at least one option.
                        self.setCommit(self.anchorOption(0).?.value, null, ';');
                    }
                    self.endComposition();
                    return;
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
        // From here, the key didn't pick at the anchor. If a punc
        // (normal-multi-candidate) pager is still active, the user is
        // abandoning the window — commit its anchor option and proceed.
        // ============================================================
        var prev: ?[*:0]const u8 = null;
        if (self.pager) |*p| {
            if (p.* == .punc) {
                prev = self.anchorOption(0).?.value;
                self.endComposition();
            }
        }

        // ============================================================
        // Case C: paired punctuation. Single-press commit with toggle.
        // ============================================================
        if (self.punc.lookupPaired(key)) |paired_entry| {
            if (prev == null) prev = self.commitTriePagerIfActive();

            const emit_close = self.flipPairToggle(key);
            const value_ptr = if (emit_close)
                self.punc.closeValue(paired_entry)
            else
                self.punc.openValue(paired_entry);

            self.setCommitWithPrefix(prev, value_ptr);
            self.endComposition();
            return;
        }

        // ============================================================
        // Case D: normal punctuation. Auto-commit if single candidate,
        // otherwise open a candidate window.
        // ============================================================
        if (self.punc.lookupNormal(key)) |normal_entry| {
            if (prev == null) prev = self.commitTriePagerIfActive();

            if (normal_entry.candidates_count == 1) {
                self.setCommitWithPrefix(prev, self.punc.candidateAt(normal_entry, 0));
                self.endComposition();
                return;
            }

            self.pager = .{ .punc = PuncPagination.init(normal_entry, self.punc) };
            self.node = self.root_node;
            self.pressed_keys_len = 0;
            self.state.anchor_index = 0;
            self.refreshAnchor();
            self.state.options_count = self.pager.?.totalOptions();
            if (prev) |p| self.setCommit(p, null, 0);
            return;
        }

        // ============================================================
        // Trie descent cases (E, F, G, H). `prev` may be set if the user
        // was in a punc window and pressed a non-punc key.
        // ============================================================

        // Case E: descend into a child of the current node.
        if (self.node.getChild(self.trie, key)) |node| {
            const key_index = self.node.indexOfChild(self.trie, key).?;

            self.node = node;
            self.startTriePager(node);
            self.pressed_keys[self.pressed_keys_len] = key_index;
            self.pressed_keys_len += 1;

            const total = self.pager.?.totalOptions();

            // E1: exactly one option and it needs no more keys — commit it.
            if (total == 1 and self.anchor_opts[0].hintSlice() == null) {
                self.setCommitWithPrefix(prev, self.anchor_opts[0].value);
                self.endComposition();
                return;
            }

            self.state.options_count = total;
            if (prev) |p| self.setCommit(p, null, 0);
            return;
        } else if (self.root_node.getChild(self.trie, key)) |node| {
            // Case F: the current node has no child with `key`, but the
            // root does — commit the anchor option, then jump.
            //
            // `prev` cannot be set here: it is set only when we exited a
            // punc window, which resets `self.node` to the root — and then
            // the branch above would have matched.
            std.debug.assert(prev == null);

            // Read before the new pager overwrites `anchor_opts`. Safe to
            // hold: option values are immortal blob pointers.
            const prev_value = self.anchorOption(0).?.value;

            self.node = node;
            self.startTriePager(node);
            self.pressed_keys_len = 0;
            self.pressed_keys[self.pressed_keys_len] = self.root_node.indexOfChild(self.trie, key).?;
            self.pressed_keys_len += 1;

            const total = self.pager.?.totalOptions();

            // F1: the jumped-to node auto-commits too — both segments.
            if (total == 1 and self.anchor_opts[0].hintSlice() == null) {
                self.setCommit(prev_value, self.anchor_opts[0].value, 0);
                self.endComposition();
                return;
            }

            self.state.options_count = total;
            self.setCommit(prev_value, null, 0);
            return;
        }

        // Case G: at the root and the key has no child — commit
        // (`prev` if any, plus) the key byte.
        if (self.node == self.root_node) {
            self.setCommit(prev, null, key);
            self.endComposition();
            return;
        }

        // Case H: deep in the trie with no matching descent — commit the
        // anchor option with `key` appended. `prev` cannot be set here
        // (that would require `self.node == self.root_node`).
        std.debug.assert(prev == null);
        self.setCommit(self.anchorOption(0).?.value, null, key);
        self.endComposition();
    }

    /// Undo the most recent trie descent, or close an open punctuation
    /// window. Never produces a commit.
    pub fn backspace(self: *Self) void {
        self.clearCommit();

        // In a punc candidate window, backspace just closes it.
        if (self.pager) |*p| {
            if (p.* == .punc) {
                self.endComposition();
                return;
            }
        }

        if (self.pressed_keys_len == 0) return;

        self.pressed_keys_len -= 1;
        self.node = self.root_node;
        for (self.pressed_keys[0..self.pressed_keys_len]) |index| {
            self.node = self.node.getChildByIndex(self.trie, index).?;
        }

        if (self.node == self.root_node) {
            self.endComposition();
            return;
        }

        self.startTriePager(self.node);
        self.state.options_count = self.pager.?.totalOptions();
    }
};

// =========================================================================
// Tests
// =========================================================================

/// Wraps the heap regions a `Context` borrows so each test can build and
/// tear them down without repeating the boilerplate. In production this
/// work is done by `jd_init`.
///
/// The PuncHandle is heap-allocated so its `punc` field's address stays
/// stable when this struct is returned by value from `init`.
const ContextHarness = struct {
    ctx: Context,
    frontier: []pagination.FrontierEntry,
    path_buf: []u8,
    punc_handle: *punc_mod.PuncHandle,

    fn init(allocator: std.mem.Allocator, trie: *const Trie) !ContextHarness {
        return ContextHarness.initWithPunc(allocator, trie, &.{}, &.{});
    }

    fn initWithPunc(
        allocator: std.mem.Allocator,
        trie: *const Trie,
        normals: []const punc_mod.NormalInput,
        paireds: []const punc_mod.PairedInput,
    ) !ContextHarness {
        const frontier = try allocator.alloc(pagination.FrontierEntry, trie.frontier_cap + 1);
        errdefer allocator.free(frontier);
        const path_buf = try allocator.alloc(u8, trie.path_buf_cap + 1);
        errdefer allocator.free(path_buf);
        const punc_handle = try allocator.create(punc_mod.PuncHandle);
        errdefer allocator.destroy(punc_handle);
        punc_handle.* = try punc_mod.buildPunc(allocator, normals, paireds);

        var self = ContextHarness{
            .ctx = undefined,
            .frontier = frontier,
            .path_buf = path_buf,
            .punc_handle = punc_handle,
        };
        self.ctx = Context.init(
            .{ .frontier = frontier, .path_buf = path_buf },
            .{ .trie = trie, .punc = &punc_handle.punc },
        );
        return self;
    }

    fn deinit(self: *ContextHarness, allocator: std.mem.Allocator) void {
        allocator.free(self.frontier);
        allocator.free(self.path_buf);
        self.punc_handle.deinit(allocator);
        allocator.destroy(self.punc_handle);
    }
};

/// Big enough for any commit the tests produce (the longest is
/// 300 + 300 bytes in the long-value tests).
var commit_buf: [1024]u8 = undefined;

/// The joined commit of the last operation, or null.
fn commitOf(ctx: *const Context) ?[]const u8 {
    return joinCommit(&ctx.state, &commit_buf);
}

fn expectCommit(ctx: *const Context, expected: []const u8) !void {
    const got = commitOf(ctx) orelse {
        std.debug.print("expected commit \"{s}\" but nothing was committed\n", .{expected});
        return error.TestExpectedEqual;
    };
    try testing.expectEqualStrings(expected, got);
}

fn expectNoCommit(ctx: *const Context) !void {
    if (commitOf(ctx)) |got| {
        std.debug.print("expected no commit but got \"{s}\"\n", .{got});
        return error.TestExpectedEqual;
    }
}

/// Reads the first `n` options at the anchor, the way a frontend showing a
/// window of `n` would.
fn expectWindow(
    ctx: *Context,
    n: u32,
    expected: []const pagination.ExpectedOption,
) !void {
    var out: [16]QueryOption = undefined;
    const got = ctx.readRange(ctx.state.anchor_index, n, &out);
    try pagination.expectEqualOptions(expected, out[0..got]);
}

const expected_a = [_]pagination.ExpectedOption{
    .{ .value = "甲" },
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

const expected_ac = [_]pagination.ExpectedOption{
    .{ .value = "丙1" },
    .{ .value = "丙2" },
    .{ .value = "丁1", .hint = "d" },
    .{ .value = "丁2", .hint = "d" },
    .{ .value = "丁3", .hint = "d" },
    .{ .value = "丁4", .hint = "e" },
    .{ .value = "FooBar", .hint = ";" },
};

test "works with initial typing" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');

    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 11), ctx.state.options_count);
    try testing.expectEqual(@as(u32, 0), ctx.state.anchor_index);
    try expectWindow(ctx, 3, expected_a[0..3]);
}

test "works with 2nd typing" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('c');

    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 7), ctx.state.options_count);
    try expectWindow(ctx, 3, expected_ac[0..3]);
}

test "digit after composition commits the anchor option + the literal digit" {
    // The engine does NOT pick from '1'-'9' — that's the IME's job per
    // docs/integration.md. Digits fall through to case H.
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('2');

    try expectCommit(ctx, "甲2");
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);
    // Case H shape: one immortal segment plus a literal byte.
    try testing.expect(ctx.state.commit_a != null);
    try testing.expect(ctx.state.commit_b == null);
    try testing.expectEqual(@as(u8, '2'), ctx.state.commit_lit);
}

test "press space to commit the anchor option" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey(' ');

    try expectCommit(ctx, "甲");
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);
    // Case A shape: a single immortal segment, no literal.
    try testing.expect(ctx.state.commit_b == null);
    try testing.expectEqual(@as(u8, 0), ctx.state.commit_lit);
}

test "press space when no other key has been pressed" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey(' ');

    try expectCommit(ctx, " ");
    // Synth shape: literal byte only, no pointers at all.
    try testing.expect(ctx.state.commit_a == null);
    try testing.expect(ctx.state.commit_b == null);
    try testing.expectEqual(@as(u8, ' '), ctx.state.commit_lit);
}

test "`;` descends when the current node has a ';' child" {
    // Node "ac" HAS a ';' child ("ac;" → FooBar), so case B is skipped and
    // this is an ordinary case-E descent that auto-commits (E1).
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('c');
    ctx.pressKey(';');

    try expectCommit(ctx, "FooBar");
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);
}

test "press `;` to commit the anchor's 2nd option" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey(';');

    try expectCommit(ctx, "乙");
}

test "`;` is page-independent: it picks relative to the anchor" {
    // Move the anchor to index 2 (丙1) — `;` must commit index 3 (丙2),
    // not the global option 1.
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.setAnchor(2);
    ctx.pressKey(';');

    try expectCommit(ctx, "丙2");
}

test "press `;` when there are options starting with ';'" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "甲" },
        .{ .keys = "ab", .value = "乙" },
        .{ .keys = "ac", .value = "丙" },
        .{ .keys = "ad;", .value = "Hello World" },
        .{ .keys = "ae;a", .value = "Foo" },
        .{ .keys = "ae;b", .value = "Bar" },
    });
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('e');
    ctx.pressKey(';');

    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 2), ctx.state.options_count);
    try expectWindow(ctx, 2, &.{
        .{ .value = "Foo", .hint = "a" },
        .{ .value = "Bar", .hint = "b" },
    });
}

test "press `;` when there is only one option, with a hint" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "abc", .value = "FooBar" },
    });
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('b');
    ctx.pressKey(';');

    try expectCommit(ctx, "FooBar;");
    // Case B fallback shape: one segment plus the ';' literal.
    try testing.expect(ctx.state.commit_b == null);
    try testing.expectEqual(@as(u8, ';'), ctx.state.commit_lit);
}

test "auto-commit when the only option needs no more keys" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('e');

    try expectCommit(ctx, "Foo");
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);
}

test "no auto-commit when the only option still carries a hint" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "a", .value = "A" },
        .{ .keys = "ab", .value = "B" },
        .{ .keys = "acde", .value = "C" },
    });
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('c');

    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 1), ctx.state.options_count);
    try expectWindow(ctx, 1, &.{.{ .value = "C", .hint = "de" }});
}

test "drill-in: key is not a child of the current node but is of the root" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 11), ctx.state.options_count);

    ctx.pressKey('c');
    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 7), ctx.state.options_count);

    // 'a' is no child of "ac" but is a child of the root: commit the
    // anchor option AND start fresh — the drilled-in state.
    ctx.pressKey('a');
    try expectCommit(ctx, "丙1");
    try testing.expectEqual(@as(u32, 11), ctx.state.options_count);
    try testing.expectEqual(@as(u32, 0), ctx.state.anchor_index);
    try expectWindow(ctx, 3, expected_a[0..3]);

    ctx.pressKey('c');
    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 7), ctx.state.options_count);
}

test "the first key is not in the root's children" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('x');

    try expectCommit(ctx, "x");
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);
    // Case G with no prefix: a bare literal byte.
    try testing.expect(ctx.state.commit_a == null);
    try testing.expectEqual(@as(u8, 'x'), ctx.state.commit_lit);
}

test "key matches neither the current node nor the root" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('c');
    ctx.pressKey('0');

    try expectCommit(ctx, "丙10");
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);

    ctx.pressKey('a');
    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 11), ctx.state.options_count);
}

// =========================================================================
// Tests — anchor vs. cursor separation
//
// The whole point of the redesign: reading candidates must never change
// what the engine's automatic commits resolve to.
// =========================================================================

test "reading far ahead does not move the anchor" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');

    // Prefetch the tail of the list, exactly as an append-only candidate
    // strip would. No jump-back dance is needed.
    var out: [4]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 4), ctx.readRange(4, 4, &out));
    try pagination.expectEqualOptions(expected_a[4..8], out[0..4]);
    try testing.expectEqual(@as(u32, 2), ctx.readRange(9, 4, &out));
    try testing.expectEqual(@as(u32, 0), ctx.state.anchor_index);

    // Space still commits the option the user is looking at.
    ctx.pressKey(' ');
    try expectCommit(ctx, "甲");
}

test "reading far ahead does not disturb `;` or the literal fallback" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    var out: [8]QueryOption = undefined;

    ctx.pressKey('a');
    _ = ctx.readRange(6, 8, &out);
    ctx.pressKey(';');
    try expectCommit(ctx, "乙");

    ctx.pressKey('a');
    _ = ctx.readRange(8, 8, &out);
    ctx.pressKey('5');
    try expectCommit(ctx, "甲5");
}

test "setAnchor moves what the automatic commits resolve to" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');

    ctx.setAnchor(6);
    try testing.expectEqual(@as(u32, 6), ctx.state.anchor_index);
    try expectWindow(ctx, 3, expected_a[6..9]);

    ctx.pressKey(' ');
    try expectCommit(ctx, "丁1");
}

test "setAnchor ignores out-of-range indices and no-ops without a pager" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    // No composition in flight.
    ctx.setAnchor(3);
    try testing.expectEqual(@as(u32, 0), ctx.state.anchor_index);
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);

    ctx.pressKey('a');
    ctx.setAnchor(5);
    ctx.setAnchor(11); // == total, out of range
    try testing.expectEqual(@as(u32, 5), ctx.state.anchor_index);
    ctx.setAnchor(999);
    try testing.expectEqual(@as(u32, 5), ctx.state.anchor_index);
}

test "a new composition resets the anchor" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.setAnchor(8);
    ctx.pressKey('c'); // descend — anchor must go back to 0
    try testing.expectEqual(@as(u32, 0), ctx.state.anchor_index);
    try expectWindow(ctx, 2, expected_ac[0..2]);
}

test "readRange returns nothing when no composition is in flight" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    var out: [4]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 0), ctx.readRange(0, 4, &out));

    ctx.pressKey('a');
    ctx.pressKey(' '); // commits, ending the composition
    try testing.expectEqual(@as(u32, 0), ctx.readRange(0, 4, &out));
}

// =========================================================================
// Tests — backspace
// =========================================================================

test "backspace undoes one descent" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('c');
    try testing.expectEqual(@as(u32, 7), ctx.state.options_count);

    ctx.backspace();
    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 11), ctx.state.options_count);
    try expectWindow(ctx, 3, expected_a[0..3]);

    ctx.pressKey('c');
    try testing.expectEqual(@as(u32, 7), ctx.state.options_count);
}

test "backspace to the root clears the composition" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.backspace();

    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);

    ctx.pressKey('a');
    try testing.expectEqual(@as(u32, 11), ctx.state.options_count);
}

test "backspace at the root does nothing" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.backspace();
    ctx.backspace();

    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);

    ctx.pressKey('a');
    try expectWindow(ctx, 3, expected_a[0..3]);
}

test "backspace resets the anchor to the start of the shorter code" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('c');
    ctx.setAnchor(4);
    ctx.backspace();

    try testing.expectEqual(@as(u32, 0), ctx.state.anchor_index);
    ctx.pressKey(' ');
    try expectCommit(ctx, "甲");
}

test "reset drops both the composition and the recorded commit" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey(' ');
    try expectCommit(ctx, "甲");

    ctx.reset();
    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);
    try testing.expectEqual(@as(u32, 0), ctx.state.anchor_index);
}

// =========================================================================
// Tests — punctuation integration
// =========================================================================

test "single-candidate normal punc commits directly from the root" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const candidates = [_][]const u8{"。"};
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '.', .candidates = &candidates },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('.');
    try expectCommit(ctx, "。");
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);
}

test "single-candidate punc commits trie + punc after a composition" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const candidates = [_][]const u8{"。"};
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '.', .candidates = &candidates },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('.');
    try expectCommit(ctx, "甲。");
    // Two immortal segments, no literal.
    try testing.expect(ctx.state.commit_a != null);
    try testing.expect(ctx.state.commit_b != null);
    try testing.expectEqual(@as(u8, 0), ctx.state.commit_lit);
}

test "multi-candidate punc opens a window" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const candidates = [_][]const u8{ "「", "【", "〔", "［" };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('[');
    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 4), ctx.state.options_count);
    try testing.expectEqual(@as(u32, 0), ctx.state.anchor_index);
    try expectWindow(ctx, 4, &.{
        .{ .value = "「" },
        .{ .value = "【" },
        .{ .value = "〔" },
        .{ .value = "［" },
    });
}

test "punc window: reading ahead and setAnchor behave like the trie case" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const candidates = [_][]const u8{ "「", "【", "〔", "［" };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('[');

    var out: [2]QueryOption = undefined;
    try testing.expectEqual(@as(u32, 2), ctx.readRange(2, 2, &out));
    try pagination.expectEqualOptions(&.{ .{ .value = "〔" }, .{ .value = "［" } }, out[0..2]);
    // The anchor is untouched, so space still commits the first mark.
    try testing.expectEqual(@as(u32, 0), ctx.state.anchor_index);

    ctx.setAnchor(2);
    ctx.pressKey(' ');
    try expectCommit(ctx, "〔");
}

test "paired punc toggles on consecutive presses" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{}, &.{
        .{ .key = '"', .open = "“", .close = "”" },
    });
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('"');
    try expectCommit(ctx, "“");
    ctx.pressKey('"');
    try expectCommit(ctx, "”");
    ctx.pressKey('"');
    try expectCommit(ctx, "“");
}

test "paired toggle survives non-paired commits in between" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{}, &.{
        .{ .key = '"', .open = "“", .close = "”" },
    });
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('"'); // “, toggle for '"' → 1
    ctx.pressKey('a');
    ctx.pressKey(' '); // commit 甲
    ctx.pressKey('"');
    try expectCommit(ctx, "”");
}

test "paired toggle survives reset" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{}, &.{
        .{ .key = '"', .open = "“", .close = "”" },
    });
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('"');
    ctx.reset();
    ctx.pressKey('"');
    try expectCommit(ctx, "”");
}

test "two paired keys have independent toggles" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{}, &.{
        .{ .key = '"', .open = "“", .close = "”" },
        .{ .key = '\'', .open = "‘", .close = "’" },
    });
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('"'); // “
    ctx.pressKey('\''); // ‘
    ctx.pressKey('"');
    try expectCommit(ctx, "”");
    ctx.pressKey('\'');
    try expectCommit(ctx, "’");
}

test "punc window: backspace closes the window" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const candidates = [_][]const u8{ "「", "【" };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('[');
    ctx.backspace();
    try expectNoCommit(ctx);
    try testing.expectEqual(@as(u32, 0), ctx.state.options_count);
}

test "punc window: a trie key commits the anchor mark and starts composing" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const candidates = [_][]const u8{ "「", "【" };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('[');
    ctx.pressKey('a');
    try expectCommit(ctx, "「");
    try testing.expectEqual(@as(u32, 11), ctx.state.options_count);
    try expectWindow(ctx, 1, expected_a[0..1]);
}

test "punc window: space commits the anchor mark" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const candidates = [_][]const u8{ "「", "【" };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('[');
    ctx.pressKey(' ');
    try expectCommit(ctx, "「");
}

test "punc window: pressing the punc key again commits and re-opens" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const candidates = [_][]const u8{ "「", "【" };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('[');
    ctx.pressKey('[');
    try expectCommit(ctx, "「");
    try testing.expectEqual(@as(u32, 2), ctx.state.options_count);
}

test "punc window: `;` commits the mark then opens its own symbol window" {
    // On a punctuation window `;` is NOT a 2nd-candidate selector: the
    // window's anchor mark is committed and `;` starts its own trie scheme.
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = ";", .value = "；" },
        .{ .keys = ";;", .value = "：" },
    });
    defer th.deinit(testing.allocator);
    const candidates = [_][]const u8{ "「", "【" };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '[', .candidates = &candidates },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('[');
    ctx.pressKey(';');
    try expectCommit(ctx, "「");
    try testing.expectEqual(@as(u32, 2), ctx.state.options_count);
}

test "trie composition + paired key commits both" {
    var th = try buildTestTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{}, &.{
        .{ .key = '"', .open = "“", .close = "”" },
    });
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('"');
    try expectCommit(ctx, "甲“");
}

// =========================================================================
// Long-value tests.
//
// These used to exist to prove the fixed commit scratch buffer was sized
// correctly. There is no scratch buffer any more — commits are two
// immortal pointers plus a byte — so they now serve as behavior tests for
// the segment shapes, with values far longer than any buffer would have
// held (the longest real dictionary entry is 300 bytes).
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

test "long values: F1 commits two immortal segments" {
    var th = try buildLongValueTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    // 'a' opens an enumeration whose first option is LONG_A (child a < c).
    ctx.pressKey('a');
    // 'b' is no child of node "a" but is a child of the root, and node "b"
    // has a single hint-less option: commit LONG_A then LONG_B.
    ctx.pressKey('b');

    try testing.expectEqualStrings(LONG_A, std.mem.sliceTo(ctx.state.commit_a.?, 0));
    try testing.expectEqualStrings(LONG_B, std.mem.sliceTo(ctx.state.commit_b.?, 0));
    try testing.expectEqual(@as(u8, 0), ctx.state.commit_lit);
    try expectCommit(ctx, LONG_A ++ LONG_B);
}

test "long values: case H appends a literal byte to a long anchor option" {
    var th = try buildLongValueTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    ctx.pressKey('a');
    ctx.pressKey('1');

    try testing.expectEqualStrings(LONG_A, std.mem.sliceTo(ctx.state.commit_a.?, 0));
    try testing.expect(ctx.state.commit_b == null);
    try testing.expectEqual(@as(u8, '1'), ctx.state.commit_lit);
    try expectCommit(ctx, LONG_A ++ "1");
}

test "long values: case B fallback appends ';' to a long single option" {
    var th = try trie_mod.buildTrie(testing.allocator, &.{
        .{ .keys = "aa", .value = LONG_A },
    });
    defer th.deinit(testing.allocator);
    var harness = try ContextHarness.init(testing.allocator, &th.trie);
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    // Single option WITH a hint ("a"), so no E1 auto-commit.
    ctx.pressKey('a');
    ctx.pressKey(';');
    try expectCommit(ctx, LONG_A ++ ";");
}

test "long values: punctuation after a long composition commits both" {
    var th = try buildLongValueTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const dot = [_][]const u8{"。"};
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '.', .candidates = &dot },
    }, &.{
        .{ .key = '"', .open = "“", .close = "”" },
    });
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    // Case D (normal, single candidate) after a long composition.
    ctx.pressKey('a');
    ctx.pressKey('.');
    try expectCommit(ctx, LONG_A ++ "。");

    // Case C (paired) after a long composition.
    ctx.pressKey('a');
    ctx.pressKey('"');
    try expectCommit(ctx, LONG_A ++ "“");
}

test "long values: E1 auto-commit after abandoning a punc window" {
    var th = try buildLongValueTrie(testing.allocator);
    defer th.deinit(testing.allocator);
    const brackets = [_][]const u8{ "「", "【" };
    var harness = try ContextHarness.initWithPunc(testing.allocator, &th.trie, &.{
        .{ .key = '[', .candidates = &brackets },
    }, &.{});
    defer harness.deinit(testing.allocator);
    const ctx = &harness.ctx;

    // '[' opens a punc window; 'b' abandons it (committing 「) and descends
    // to node "b", whose single hint-less option LONG_B auto-commits.
    ctx.pressKey('[');
    ctx.pressKey('b');
    try expectCommit(ctx, "「" ++ LONG_B);
}
