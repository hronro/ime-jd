const std = @import("std");
const builtin = @import("builtin");

const query = @import("./query.zig");
const pagination = @import("./pagination.zig");
const trie_mod = @import("trie");
const punc_mod = @import("./punc.zig");
const tables = @import("./tables.zig");
const punc_tables = @import("./punctuation_marks.zig");

const QueryOption = pagination.QueryOption;
const JdState = query.JdState;

/// Whether we're compiling for a WebAssembly target. Selects the allocator.
const is_wasm = builtin.target.cpu.arch.isWasm();

/// Single process-wide allocator. Each `jd_init` makes exactly one
/// allocation via this allocator (the per-context buffer); each `jd_deinit`
/// makes exactly one matching `free`. Nothing else in the library calls
/// into an allocator at runtime — all internal containers are either
/// pre-sized slices carved from the per-context buffer or inline fields.
///
/// `smp_allocator` is thread-safe but reaches for the OS page allocator
/// (mmap / VirtualAlloc) and a CPU-count probe, none of which exist on
/// `wasm32-freestanding`. WebAssembly gets `wasm_allocator` instead — pure
/// Zig, backed by the `memory.grow` intrinsic and single-threaded (which
/// every wasm build here is). The `if` is comptime-folded, so non-wasm
/// builds never analyze `wasm_allocator` — its vtable is a `@compileError`
/// off-wasm.
const shared_allocator = if (is_wasm) std.heap.wasm_allocator else std.heap.smp_allocator;

/// One-time, thread-safe initialization of a process-wide immutable value.
/// The first caller runs `parse`; a caller arriving mid-parse spins until
/// the result is published. The parse itself is O(1) (just slice-header
/// construction over the embedded blob), so the spin window is microscopic.
///
/// Slice headers land in BSS; the bytes they point at live in rodata.
fn OnceCell(comptime T: type, comptime parse: fn () T) type {
    return struct {
        const State = enum(u8) { uninit, initializing, done };

        var value: T = undefined;
        var state: std.atomic.Value(u8) = .init(@intFromEnum(State.uninit));

        fn get() *const T {
            if (state.load(.acquire) == @intFromEnum(State.done)) return &value;

            if (state.cmpxchgStrong(
                @intFromEnum(State.uninit),
                @intFromEnum(State.initializing),
                .acquire,
                .acquire,
            ) == null) {
                // We won the race — do the parse.
                value = parse();
                state.store(@intFromEnum(State.done), .release);
                return &value;
            }

            // Another thread is initializing; spin until it publishes.
            while (state.load(.acquire) != @intFromEnum(State.done)) {
                std.atomic.spinLoopHint();
            }
            return &value;
        }
    };
}

fn parseTrie() trie_mod.Trie {
    return trie_mod.Trie.fromBytes(tables.blob_bytes) catch unreachable;
}

fn parsePunc() punc_mod.Punc {
    return punc_mod.Punc.fromBytes(punc_tables.blob_bytes) catch unreachable;
}

const TrieCell = OnceCell(trie_mod.Trie, parseTrie);
const PuncCell = OnceCell(punc_mod.Punc, parsePunc);

// Opaque handle exposed to C consumers as `struct jd_context *`.
pub const JdContext = opaque {};

fn ctxOf(handle: *JdContext) *query.Context {
    return @ptrCast(@alignCast(handle));
}

/// Offsets within the per-context buffer. Layout is:
///   [Context struct] [frontier_buf] [path_buf]
/// with `std.mem.alignForward` padding where needed. Everything else the
/// context needs — the anchor cache, the caller-visible state, the read
/// scratch — is an inline field of `Context`.
const Layout = struct {
    total: usize,
    frontier_off: usize,
    path_off: usize,
};

fn computeLayout(frontier_cap: u32, path_buf_cap: u32) Layout {
    var off: usize = @sizeOf(query.Context);
    off = std.mem.alignForward(usize, off, @alignOf(pagination.FrontierEntry));
    const frontier_off = off;
    off += frontier_cap * @sizeOf(pagination.FrontierEntry);

    // path_buf is []u8, no alignment beyond 1.
    const path_off = off;
    off += path_buf_cap;

    return .{ .total = off, .frontier_off = frontier_off, .path_off = path_off };
}

export fn jd_init() ?*JdContext {
    const t = TrieCell.get();
    const p = PuncCell.get();

    const layout = computeLayout(t.frontier_cap, t.path_buf_cap);
    const raw = shared_allocator.alignedAlloc(u8, .@"8", layout.total) catch return null;

    const ctx: *query.Context = @ptrCast(@alignCast(raw.ptr));

    const frontier_ptr: [*]pagination.FrontierEntry =
        @ptrCast(@alignCast(raw.ptr + layout.frontier_off));

    ctx.* = query.Context.init(.{
        .frontier = frontier_ptr[0..t.frontier_cap],
        .path_buf = raw[layout.path_off..][0..t.path_buf_cap],
    }, .{ .trie = t, .punc = p });
    ctx.raw = raw;

    return @ptrCast(ctx);
}

export fn jd_press_key(handle: *JdContext, key: u8) void {
    ctxOf(handle).pressKey(key);
}

export fn jd_backspace(handle: *JdContext) void {
    ctxOf(handle).backspace();
}

export fn jd_reset(handle: *JdContext) void {
    ctxOf(handle).reset();
}

export fn jd_set_anchor(handle: *JdContext, index: u32) void {
    ctxOf(handle).setAnchor(index);
}

/// Address of the context's state block. Stable for the context's whole
/// lifetime — read it once and keep it.
export fn jd_state_ptr(handle: *JdContext) *const JdState {
    return &ctxOf(handle).state;
}

/// A `JD_SCRATCH_OPTIONS`-long buffer owned by the context, for hosts that
/// can't hand `jd_read_range` a buffer of their own (a WebAssembly host has
/// no allocator inside linear memory).
export fn jd_scratch_ptr(handle: *JdContext) [*]QueryOption {
    return &ctxOf(handle).scratch;
}

export fn jd_read_range(
    handle: *JdContext,
    start: u32,
    count: u32,
    out: [*]QueryOption,
    out_cap: u32,
) u32 {
    return ctxOf(handle).readRange(start, count, out[0..out_cap]);
}

export fn jd_deinit(handle: *JdContext) void {
    shared_allocator.free(ctxOf(handle).raw);
}

// =========================================================================
// ABI layout guard.
//
// `include/jd.h` is hand-written and `bindings/rust` hand-writes its own
// `#[repr(C)]` declarations, so either can silently drift from the Zig
// `extern struct`s and corrupt memory with no diagnostic. Bindings compare
// these numbers against their own compiled view once at init.
// =========================================================================

const AbiQuery = enum(u32) {
    sizeof_state = 0,
    sizeof_option = 1,
    hint_cap = 2,
    scratch_options = 3,
    /// Upper bound on the joined length of a commit, in bytes, excluding a
    /// NUL terminator: two longest values back to back plus one literal.
    /// Lets a C consumer size a stack buffer for joining the segments.
    max_commit_len = 4,
};

export fn jd_abi_layout(what: u32) u32 {
    return switch (what) {
        @intFromEnum(AbiQuery.sizeof_state) => @sizeOf(JdState),
        @intFromEnum(AbiQuery.sizeof_option) => @sizeOf(QueryOption),
        @intFromEnum(AbiQuery.hint_cap) => @intCast(pagination.HINT_CAP),
        @intFromEnum(AbiQuery.scratch_options) => @intCast(query.SCRATCH_OPTIONS),
        @intFromEnum(AbiQuery.max_commit_len) => 2 *
            @max(TrieCell.get().max_value_len, PuncCell.get().max_value_len) + 1,
        // Unknown queries are a benign 0 rather than a trap.
        else => 0,
    };
}

// =========================================================================
// Tests — unlike the harness-based unit tests in query.zig, these run
// against the real embedded blobs through the C ABI surface, exercising the
// exact single-allocation layout that production uses.
// =========================================================================

fn joined(handle: *JdContext, buf: []u8) ?[]const u8 {
    return query.joinCommit(jd_state_ptr(handle), buf);
}

test "embedded trie max_value_len matches the actual longest value" {
    const t = TrieCell.get();
    var max: u32 = 0;
    for (t.values) |v| max = @max(max, v.str_len);
    try std.testing.expectEqual(max, t.max_value_len);
}

test "embedded punc max_value_len matches the actual longest string" {
    const p = PuncCell.get();
    var max: u32 = 0;
    var it = std.mem.splitScalar(u8, p.strings, 0);
    while (it.next()) |s| max = @max(max, @as(u32, @intCast(s.len)));
    try std.testing.expectEqual(max, p.max_value_len);
}

test "commit segments stay valid across later calls on the same context" {
    // The contract's central claim: every pointer a caller receives is
    // immortal (it points into an embedded blob), so unlike the old scratch
    // buffer a commit can be read long after the next keystroke. Driven
    // here on the real dictionary through the C ABI.
    const handle = jd_init() orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    for ("jjj") |k| jd_press_key(handle, k);

    // Case H: anchor option + a literal digit.
    jd_press_key(handle, '1');
    const state = jd_state_ptr(handle);
    const held = state.commit_a orelse return error.NoCommit;
    const before = std.mem.sliceTo(held, 0);
    const copy = try std.testing.allocator.dupe(u8, before);
    defer std.testing.allocator.free(copy);
    try std.testing.expectEqual(@as(u8, '1'), state.commit_lit);

    // Drive several more operations through the same context, including
    // ones that would have clobbered the old shared scratch.
    jd_press_key(handle, 'y');
    jd_press_key(handle, 'k');
    var scratch: [32]QueryOption = undefined;
    _ = jd_read_range(handle, 0, 32, &scratch, 32);
    jd_reset(handle);

    // The originally-held pointer still reads back identically.
    try std.testing.expectEqualStrings(copy, std.mem.sliceTo(held, 0));
}

test "'#' resolves to full-width ＃ through the punctuation table" {
    // Regression: gen_punc's comment rule used to swallow normal.txt's
    // `#` mapping line, so the shipped blob silently lacked the key and
    // '#' fell through to the trie as a literal ASCII byte.
    const handle = jd_init() orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    jd_press_key(handle, '#');
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("＃", joined(handle, &buf) orelse return error.NoCommit);
}

test "multiple contexts share blobs but have independent state" {
    const a = jd_init() orelse return error.OutOfMemory;
    defer jd_deinit(a);
    const b = jd_init() orelse return error.OutOfMemory;
    defer jd_deinit(b);

    jd_press_key(a, 'j');
    try std.testing.expect(jd_state_ptr(a).options_count > 0);

    // b is untouched by a's composition: space synthesizes a bare " ".
    jd_press_key(b, ' ');
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(" ", joined(b, &buf) orelse return error.NoCommit);
    try std.testing.expect(jd_state_ptr(a).options_count > 0);
}

test "jd_read_range walks the real dictionary forward without replaying" {
    // `j` is the worst case in the shipped dictionary: ~11.9K candidates.
    // Walking it in windows must touch each candidate exactly once — this
    // is the property that turns a candidate-strip scroll from O(N²) into
    // O(N), so it is worth locking down against the real data.
    const handle = jd_init() orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    jd_press_key(handle, 'j');
    const total = jd_state_ptr(handle).options_count;
    try std.testing.expect(total > 10_000);

    pagination.consume_calls = 0;
    var out: [16]QueryOption = undefined;
    var start: u32 = 0;
    while (true) {
        const n = jd_read_range(handle, start, 16, &out, 16);
        if (n == 0) break;
        start += n;
    }
    try std.testing.expectEqual(total, start);
    // Exactly one pass: no rewind, no replay.
    try std.testing.expectEqual(@as(usize, total), pagination.consume_calls);
}

test "reading the whole dictionary list leaves the anchor commit intact" {
    const handle = jd_init() orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    jd_press_key(handle, 'j');

    // Capture the anchor's candidate — what space is supposed to commit.
    var one: [1]QueryOption = undefined;
    try std.testing.expectEqual(@as(u32, 1), jd_read_range(handle, 0, 1, &one, 1));
    const anchor_value = try std.testing.allocator.dupe(u8, std.mem.sliceTo(one[0].value, 0));
    defer std.testing.allocator.free(anchor_value);

    // Prefetch deep into the list — under the old page-based ABI this is
    // exactly what left the paginator parked on a page the user wasn't
    // looking at, so space committed the wrong candidate.
    const total = jd_state_ptr(handle).options_count;
    _ = jd_read_range(handle, total - 8, 8, jd_scratch_ptr(handle), @intCast(query.SCRATCH_OPTIONS));

    jd_press_key(handle, ' ');
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(
        anchor_value,
        joined(handle, &buf) orelse return error.NoCommit,
    );
}

test "jd_scratch_ptr is writable and holds a full window" {
    const handle = jd_init() orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    jd_press_key(handle, 'j');
    const scratch = jd_scratch_ptr(handle);
    const cap: u32 = @intCast(query.SCRATCH_OPTIONS);
    const n = jd_read_range(handle, 0, cap, scratch, cap);
    try std.testing.expectEqual(cap, n);
    // Every entry is a readable UTF-8 string from the blob.
    for (0..n) |i| try std.testing.expect(std.mem.sliceTo(scratch[i].value, 0).len > 0);
}

test "jd_abi_layout reports the real struct sizes" {
    try std.testing.expectEqual(
        @as(u32, @sizeOf(JdState)),
        jd_abi_layout(@intFromEnum(AbiQuery.sizeof_state)),
    );
    try std.testing.expectEqual(
        @as(u32, @sizeOf(QueryOption)),
        jd_abi_layout(@intFromEnum(AbiQuery.sizeof_option)),
    );
    try std.testing.expectEqual(
        @as(u32, pagination.HINT_CAP),
        jd_abi_layout(@intFromEnum(AbiQuery.hint_cap)),
    );
    try std.testing.expectEqual(
        @as(u32, query.SCRATCH_OPTIONS),
        jd_abi_layout(@intFromEnum(AbiQuery.scratch_options)),
    );
    // 2 × 300-byte longest entry + 1 literal.
    try std.testing.expectEqual(
        @as(u32, 601),
        jd_abi_layout(@intFromEnum(AbiQuery.max_commit_len)),
    );
    // Unknown queries are a benign 0 rather than a trap.
    try std.testing.expectEqual(@as(u32, 0), jd_abi_layout(9999));
}
