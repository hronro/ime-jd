const std = @import("std");

const query = @import("./query.zig");
const pagination = @import("./pagination.zig");
const trie_mod = @import("trie");
const punc_mod = @import("./punc.zig");
const tables = @import("./tables.zig");
const punc_tables = @import("./punctuation_marks.zig");

const QueryOption = pagination.QueryOption;

/// Single process-wide allocator. Each `jd_init` makes exactly one
/// allocation via this allocator (the per-context buffer); each `jd_deinit`
/// makes exactly one matching `free`. Nothing else in the library calls
/// into an allocator at runtime — all internal containers are pre-sized
/// slices and FixedBufferAllocators carved from the per-context buffer.
const shared_allocator = std.heap.smp_allocator;

/// The trie is parsed once from the embedded blob on the first jd_init call
/// and shared read-only across every context. Slice headers live in BSS;
/// the bytes they point at live in rodata. A 3-state atomic flag handles
/// the one-time-init race: the first caller does the parse, any caller that
/// arrives mid-parse spins until done. The parse itself is O(1) (just slice
/// header construction), so the spin is microscopic in practice.
///
/// The same scheme is applied independently to the punc blob.
const TrieInitState = enum(u8) { uninit, initializing, done };
var trie_value: trie_mod.Trie = undefined;
var trie_init_state: std.atomic.Value(u8) = .init(@intFromEnum(TrieInitState.uninit));

var punc_value: punc_mod.Punc = undefined;
var punc_init_state: std.atomic.Value(u8) = .init(@intFromEnum(TrieInitState.uninit));

fn ensureTrieInit() void {
    if (trie_init_state.load(.acquire) == @intFromEnum(TrieInitState.done)) return;

    if (trie_init_state.cmpxchgStrong(
        @intFromEnum(TrieInitState.uninit),
        @intFromEnum(TrieInitState.initializing),
        .acquire,
        .acquire,
    ) == null) {
        // We won the race — do the parse.
        trie_value = trie_mod.Trie.fromBytes(tables.blob_bytes) catch unreachable;
        trie_init_state.store(@intFromEnum(TrieInitState.done), .release);
        return;
    }

    // Another thread is initializing; spin until it publishes the result.
    while (trie_init_state.load(.acquire) != @intFromEnum(TrieInitState.done)) {
        std.atomic.spinLoopHint();
    }
}

fn ensurePuncInit() void {
    if (punc_init_state.load(.acquire) == @intFromEnum(TrieInitState.done)) return;

    if (punc_init_state.cmpxchgStrong(
        @intFromEnum(TrieInitState.uninit),
        @intFromEnum(TrieInitState.initializing),
        .acquire,
        .acquire,
    ) == null) {
        punc_value = punc_mod.Punc.fromBytes(punc_tables.blob_bytes) catch unreachable;
        punc_init_state.store(@intFromEnum(TrieInitState.done), .release);
        return;
    }

    while (punc_init_state.load(.acquire) != @intFromEnum(TrieInitState.done)) {
        std.atomic.spinLoopHint();
    }
}

// Opaque handle exposed to C consumers as `struct jd_context *`.
pub const JdContext = opaque {};

fn ctxOf(handle: *JdContext) *query.Context {
    return @ptrCast(@alignCast(handle));
}

/// Offsets within the per-context buffer. Layout is:
///   [Context struct] [frontier_buf] [path_buf] [page_buf] [commit_scratch]
/// with `std.mem.alignForward` padding between regions where needed.
const Layout = struct {
    total: usize,
    frontier_off: usize,
    path_off: usize,
    page_off: usize,
    scratch_off: usize,
};

fn computeLayout(frontier_cap: u32, path_buf_cap: u32, page_cap: usize, scratch_cap: usize) Layout {
    var off: usize = @sizeOf(query.Context);
    off = std.mem.alignForward(usize, off, @alignOf(pagination.FrontierEntry));
    const frontier_off = off;
    off += frontier_cap * @sizeOf(pagination.FrontierEntry);

    // path_buf is []u8, no alignment beyond 1.
    const path_off = off;
    off += path_buf_cap;

    off = std.mem.alignForward(usize, off, @alignOf(QueryOption));
    const page_off = off;
    off += page_cap;

    // commit_scratch is []u8, no alignment beyond 1.
    const scratch_off = off;
    off += scratch_cap;

    return .{
        .total = off,
        .frontier_off = frontier_off,
        .path_off = path_off,
        .page_off = page_off,
        .scratch_off = scratch_off,
    };
}

export fn jd_init(page_size: u8) ?*JdContext {
    // Both paginators divide by page_size (pagination.zig), so a zero must
    // never cross the C boundary — in ReleaseFast that division is UB, not
    // a panic. NULL reuses the existing allocation-failure contract.
    if (page_size == 0) return null;
    ensureTrieInit();
    ensurePuncInit();
    const t = &trie_value;
    const p = &punc_value;

    const page_cap = pagination.pageBufferSize(page_size);
    const scratch_cap = query.commitScratchCap(@max(t.max_value_len, p.max_value_len));
    const layout = computeLayout(t.frontier_cap, t.path_buf_cap, page_cap, scratch_cap);

    const raw = shared_allocator.alignedAlloc(u8, .@"8", layout.total) catch return null;

    const ctx: *query.Context = @ptrCast(@alignCast(raw.ptr));

    const frontier_ptr: [*]pagination.FrontierEntry =
        @ptrCast(@alignCast(raw.ptr + layout.frontier_off));
    const frontier_buf = frontier_ptr[0..t.frontier_cap];
    const path_buf = raw[layout.path_off..][0..t.path_buf_cap];
    const page_buf = raw[layout.page_off..][0..page_cap];
    const commit_scratch = raw[layout.scratch_off..][0..scratch_cap];

    ctx.* = query.Context.init(.{
        .frontier = frontier_buf,
        .path_buf = path_buf,
        .page_buf = page_buf,
        .commit_scratch = commit_scratch,
    }, .{ .trie = t, .punc = p, .page_size = page_size });
    ctx.raw = raw;

    return @ptrCast(ctx);
}

export fn jd_press_key(handle: *JdContext, key: u8) query.QueryResult {
    return ctxOf(handle).pressKey(key);
}

export fn jd_next_page(handle: *JdContext) query.QueryResult {
    return ctxOf(handle).nextPage();
}

export fn jd_prev_page(handle: *JdContext) query.QueryResult {
    return ctxOf(handle).prevPage();
}

export fn jd_jump_to_page(handle: *JdContext, page: u32) query.QueryResult {
    return ctxOf(handle).jumpToPage(page);
}

export fn jd_backspace(handle: *JdContext) query.QueryResult {
    return ctxOf(handle).backspace();
}

export fn jd_reset(handle: *JdContext) void {
    ctxOf(handle).reset();
}

export fn jd_deinit(handle: *JdContext) void {
    shared_allocator.free(ctxOf(handle).raw);
}

// =========================================================================
// Tests — unlike the harness-based unit tests in query.zig, these run
// against the real embedded blobs through the C ABI surface, exercising
// the exact-sized single-allocation layout that production uses.
// =========================================================================

test "embedded trie max_value_len matches the actual longest value" {
    ensureTrieInit();
    var max: u32 = 0;
    for (trie_value.values) |v| max = @max(max, v.str_len);
    try std.testing.expectEqual(max, trie_value.max_value_len);
}

test "embedded punc max_value_len matches the actual longest string" {
    ensurePuncInit();
    var max: u32 = 0;
    var it = std.mem.splitScalar(u8, punc_value.strings, 0);
    while (it.next()) |s| max = @max(max, @as(u32, @intCast(s.len)));
    try std.testing.expectEqual(max, punc_value.max_value_len);
}

test "real-data commit compositions fit the carved scratch buffer" {
    // Regression companion to the long-value tests in query.zig: those
    // prove the `commitScratchCap` formula against synthetic worst-case
    // tries; this one proves the *production* carve in jd_init wires a
    // correctly-sized scratch for the real embedded dictionary, by driving
    // a scratch-composing path (case H: first option + literal byte)
    // end to end through the C ABI.
    const handle = jd_init(9) orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    var last: query.QueryResult = .{
        .commit = null,
        .options = null,
        .options_count = 0,
        .total_pages = 0,
        .current_page = 0,
    };
    for ("jjj") |k| last = jd_press_key(handle, k);
    const opts = last.options orelse return error.NoOptions;

    // `options` is borrowed — copy the first candidate out before the next
    // call into the same context, exactly as the C contract requires.
    const first = std.mem.sliceTo(opts[0].value, 0);
    const first_copy = try std.testing.allocator.dupe(u8, first);
    defer std.testing.allocator.free(first_copy);

    const result = jd_press_key(handle, '1');
    const commit = std.mem.sliceTo(result.commit orelse return error.NoCommit, 0);
    try std.testing.expectEqual(first_copy.len + 1, commit.len);
    try std.testing.expectEqualStrings(first_copy, commit[0..first_copy.len]);
    try std.testing.expectEqual(@as(u8, '1'), commit[first_copy.len]);
}

test "jd_init rejects page_size 0" {
    try std.testing.expect(jd_init(0) == null);
}

test "'#' resolves to full-width ＃ through the punctuation table" {
    // Regression: gen_punc's comment rule used to swallow normal.txt's
    // `#` mapping line, so the shipped blob silently lacked the key and
    // '#' fell through to the trie as a literal ASCII byte.
    const handle = jd_init(9) orelse return error.OutOfMemory;
    defer jd_deinit(handle);
    const result = jd_press_key(handle, '#');
    const commit = std.mem.sliceTo(result.commit orelse return error.NoCommit, 0);
    try std.testing.expectEqualStrings("＃", commit);
}

test "multiple contexts share blobs but have independent state" {
    const a = jd_init(9) orelse return error.OutOfMemory;
    defer jd_deinit(a);
    const b = jd_init(9) orelse return error.OutOfMemory;
    defer jd_deinit(b);

    const ra = jd_press_key(a, 'j');
    try std.testing.expect(ra.options != null);
    // b is untouched by a's composition: space synthesizes a bare " ".
    const rb = jd_press_key(b, ' ');
    const commit = std.mem.sliceTo(rb.commit orelse return error.NoCommit, 0);
    try std.testing.expectEqualStrings(" ", commit);
}
