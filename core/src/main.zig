const std = @import("std");
const builtin = @import("builtin");

const query = @import("./query.zig");
const pagination = @import("./pagination.zig");
const trie_mod = @import("trie");
const punc_mod = @import("./punc.zig");
const tables = @import("./tables.zig");
const punc_tables = @import("./punctuation_marks.zig");
const user_dict = @import("./user_dict.zig");
const lookup = @import("./lookup.zig");
const dict = trie_mod.dict;
const Trie = trie_mod.Trie;

const QueryOption = pagination.QueryOption;
const JdState = query.JdState;
const UserDict = user_dict.UserDict;
const UserDictReport = user_dict.Report;
const UserDictNote = user_dict.Note;
const UserDictInfo = user_dict.Info;
const UserDictStatus = user_dict.Status;
const Code = lookup.Code;

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
/// construction over an embedded blob), so the spin window is microscopic.
///
/// Slice headers land in BSS; the bytes they point at live in rodata.
fn OnceCell(comptime T: type, comptime parse: fn () T) type {
    return struct {
        const State = enum(u8) { uninit, initializing, done };

        var value: T = undefined;
        var state: std.atomic.Value(u8) = .init(@backingInt(State.uninit));

        fn get() *const T {
            if (state.load(.acquire) == @backingInt(State.done)) return &value;

            if (state.cmpxchgStrong(
                @backingInt(State.uninit),
                @backingInt(State.initializing),
                .acquire,
                .acquire,
            ) == null) {
                // We won the race — do the parse.
                value = parse();
                state.store(@backingInt(State.done), .release);
                return &value;
            }

            // Another thread is initializing; spin until it publishes.
            while (state.load(.acquire) != @backingInt(State.done)) {
                std.atomic.spinLoopHint();
            }
            return &value;
        }
    };
}

fn parseTrie() Trie {
    return Trie.fromBytes(tables.blob_bytes) catch unreachable;
}

fn parsePunc() punc_mod.Punc {
    return punc_mod.Punc.fromBytes(punc_tables.blob_bytes) catch unreachable;
}

const TrieCell = OnceCell(Trie, parseTrie);
const PuncCell = OnceCell(punc_mod.Punc, parsePunc);

/// The embedded dictionary, or null in a libjd built without one
/// (`-Dbuiltin_dict=false`, shipped as libjd-engine).
fn builtinTrie() ?*const Trie {
    if (comptime !tables.has_builtin) return null;
    return TrieCell.get();
}

/// The dictionary a host's `(ptr, len)` names: its own blob, checked
/// whole, or the embedded one for NULL.
fn resolveDict(ptr: ?*const anyopaque, len: usize, out: *Trie) UserDictStatus {
    if (ptr) |p| {
        const bytes: [*]const u8 = @ptrCast(p);
        out.* = dict.open(bytes[0..len]) catch |err| return dict.statusOf(err);
        return .ok;
    }
    out.* = (builtinTrie() orelse return .no_builtin).*;
    return .ok;
}

// Opaque handle exposed to C consumers as `struct jd_context *`.
pub const JdContext = opaque {};

fn ctxOf(handle: *JdContext) *query.Context {
    return @ptrCast(@alignCast(handle));
}

/// Offsets within the per-context buffer. Layout is:
///   [Context struct] [Trie view] [frontier_buf] [path_buf]
/// with `std.mem.alignForward` padding where needed. The view is the
/// context's dictionary — the embedded one or the host's — and the BFS
/// buffers are sized from it. Everything else the context needs — the
/// anchor cache, the caller-visible state, the read scratch — is an inline
/// field of `Context`.
const Layout = struct {
    total: usize,
    trie_off: usize,
    frontier_off: usize,
    path_off: usize,
};

fn computeLayout(frontier_cap: u32, path_buf_cap: u32) Layout {
    var off: usize = @sizeOf(query.Context);
    off = std.mem.alignForward(usize, off, @alignOf(Trie));
    const trie_off = off;
    off += @sizeOf(Trie);
    off = std.mem.alignForward(usize, off, @alignOf(pagination.FrontierEntry));
    const frontier_off = off;
    off += frontier_cap * @sizeOf(pagination.FrontierEntry);

    // path_buf is []u8, no alignment beyond 1.
    const path_off = off;
    off += path_buf_cap;

    return .{ .total = off, .trie_off = trie_off, .frontier_off = frontier_off, .path_off = path_off };
}

export fn jd_init(
    dict_blob: ?*const anyopaque,
    dict_len: usize,
    user_dict_blob: ?*const anyopaque,
    user_dict_len: usize,
) ?*JdContext {
    // Both dictionaries are the host's memory (or, for a NULL `dict_blob`,
    // the embedded one), validated here in one linear pass each and then
    // only ever read through the views stored in the context. A blob the
    // engine cannot vouch for yields no context at all (`jd_dict_check` and
    // `jd_user_dict_check` tell the host why).
    var base: Trie = undefined;
    if (resolveDict(dict_blob, dict_len, &base) != .ok) return null;
    const p = PuncCell.get();

    var user: ?UserDict = null;
    if (user_dict_blob) |ptr| {
        const bytes: [*]const u8 = @ptrCast(ptr);
        user = UserDict.fromBytes(bytes[0..user_dict_len], base.fingerprint) catch return null;
    }

    const layout = computeLayout(base.frontier_cap, base.path_buf_cap);
    const raw = shared_allocator.alignedAlloc(u8, .@"8", layout.total) catch return null;

    const ctx: *query.Context = @ptrCast(@alignCast(raw.ptr));
    const t: *Trie = @ptrCast(@alignCast(raw.ptr + layout.trie_off));
    t.* = base;

    const frontier_ptr: [*]pagination.FrontierEntry =
        @ptrCast(@alignCast(raw.ptr + layout.frontier_off));

    ctx.* = query.Context.init(.{
        .frontier = frontier_ptr[0..t.frontier_cap],
        .path_buf = raw[layout.path_off..][0..t.path_buf_cap],
    }, .{ .trie = t, .punc = p, .user_dict = user });
    ctx.raw = raw;

    return @ptrCast(ctx);
}

// =========================================================================
// Dictionary — build and check a blob that replaces the embedded one. The
// host owns every byte: `jd_dict_build` writes into the host's buffer, and
// a blob handed to `jd_init` must outlive the context.
// =========================================================================

/// The host's output buffer, or the status that says why there is none.
fn outBuffer(buf: ?*anyopaque, buf_cap: usize, out: *[]align(4) u8) UserDictStatus {
    const ptr = buf orelse return .buffer_too_small;
    if (!std.mem.isAligned(@intFromPtr(ptr), 4)) return .misaligned;
    out.* = @as([*]align(4) u8, @ptrCast(@alignCast(ptr)))[0..buf_cap];
    return .ok;
}

export fn jd_dict_blob_bound(text: ?[*]const u8, text_len: usize) usize {
    return dict.blobBound(textSlice(text, text_len));
}

export fn jd_dict_build(
    text: ?[*]const u8,
    text_len: usize,
    source_tag: u64,
    buf: ?*anyopaque,
    buf_cap: usize,
    blob_len: ?*usize,
    report: ?*UserDictReport,
) u32 {
    var local: UserDictReport = undefined;
    const rep = report orelse &local;
    rep.* = UserDictReport.empty;
    if (blob_len) |l| l.* = 0;

    var out: []align(4) u8 = undefined;
    const st = outBuffer(buf, buf_cap, &out);
    if (st != .ok) {
        rep.status = @backingInt(st);
        return rep.status;
    }
    const len = dict.build(textSlice(text, text_len), out, source_tag, rep);
    if (blob_len) |l| l.* = len;
    return rep.status;
}

export fn jd_dict_check(blob: ?*const anyopaque, blob_len: usize, info: ?*UserDictInfo) u32 {
    const ptr = blob orelse return @backingInt(UserDictStatus.corrupt);
    const bytes: [*]const u8 = @ptrCast(ptr);
    return @backingInt(dict.check(bytes[0..blob_len], info));
}

// =========================================================================
// User dictionary — build and check blobs for jd_init. The host owns every
// byte involved: `jd_user_dict_build` writes into the host's buffer, and a
// blob handed to `jd_init` must outlive the context.
// =========================================================================

fn textSlice(ptr: ?[*]const u8, len: usize) []const u8 {
    return if (ptr) |p| p[0..len] else "";
}

export fn jd_user_dict_blob_bound(phrases: ?[*]const u8, phrases_len: usize) usize {
    return user_dict.blobBound(textSlice(phrases, phrases_len));
}

export fn jd_user_dict_build(
    dict_blob: ?*const anyopaque,
    dict_len: usize,
    phrases: ?[*]const u8,
    phrases_len: usize,
    source_tag: u64,
    buf: ?*anyopaque,
    buf_cap: usize,
    blob_len: ?*usize,
    report: ?*UserDictReport,
) u32 {
    var local: UserDictReport = undefined;
    const rep = report orelse &local;
    rep.* = UserDictReport.empty;
    if (blob_len) |l| l.* = 0;

    var out: []align(4) u8 = undefined;
    var st = outBuffer(buf, buf_cap, &out);
    var base: Trie = undefined;
    if (st == .ok) st = resolveDict(dict_blob, dict_len, &base);
    if (st != .ok) {
        rep.status = @backingInt(st);
        return rep.status;
    }
    const len = user_dict.build(
        textSlice(phrases, phrases_len),
        out,
        &base,
        base.fingerprint,
        source_tag,
        rep,
    );
    if (blob_len) |l| l.* = len;
    return rep.status;
}

export fn jd_user_dict_check(
    dict_blob: ?*const anyopaque,
    dict_len: usize,
    blob: ?*const anyopaque,
    blob_len: usize,
    info: ?*UserDictInfo,
) u32 {
    var base: Trie = undefined;
    const st = resolveDict(dict_blob, dict_len, &base);
    if (st != .ok) return @backingInt(st);
    const ptr = blob orelse return @backingInt(UserDictStatus.corrupt);
    const bytes: [*]const u8 = @ptrCast(ptr);
    return @backingInt(UserDict.check(bytes[0..blob_len], base.fingerprint, info));
}

export fn jd_user_dict_hash(bytes: ?*const anyopaque, len: usize) u64 {
    const ptr = bytes orelse return user_dict.hash("");
    const slice: [*]const u8 = @ptrCast(ptr);
    return user_dict.hash(slice[0..len]);
}

// =========================================================================
// Memory for hosts without an allocator of their own — a WebAssembly host
// cannot allocate inside linear memory, yet the user-dictionary calls take
// host buffers. These wrap the library's allocator; the keystroke path
// still never allocates.
// =========================================================================

/// Alignment of `jd_alloc` blocks: enough for a user-dictionary blob and
/// for any scalar a host might lay out in one.
const HOST_ALLOC_ALIGN: std.mem.Alignment = .@"16";

export fn jd_alloc(size: usize) ?*anyopaque {
    if (size == 0) return null;
    const block = shared_allocator.alignedAlloc(u8, HOST_ALLOC_ALIGN, size) catch return null;
    return @ptrCast(block.ptr);
}

export fn jd_free(ptr: ?*anyopaque, size: usize) void {
    const p = ptr orelse return;
    if (size == 0) return;
    const block: [*]align(HOST_ALLOC_ALIGN.toByteUnits()) u8 = @ptrCast(@alignCast(p));
    shared_allocator.free(block[0..size]);
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

/// The codes `value` is typed with in this context — its built-in tables
/// and its user dictionary. A pure read: the composition is untouched.
export fn jd_lookup_codes(
    handle: *JdContext,
    value: ?[*]const u8,
    value_len: usize,
    out: ?[*]Code,
    out_cap: u32,
) u32 {
    const ctx = ctxOf(handle);
    const user: ?*const UserDict = if (ctx.user_dict) |*d| d else null;
    const dest: []Code = if (out) |p| p[0..out_cap] else &.{};
    return lookup.codesOf(ctx.trie, user, textSlice(value, value_len), dest);
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
    /// Every dictionary's values are capped at `dict.VALUE_MAX`, so the
    /// bound holds whatever the host loads.
    max_commit_len = 4,
    sizeof_user_dict_report = 5,
    user_dict_max_entries = 6,
    user_dict_value_max = 7,
    sizeof_user_dict_info = 8,
    sizeof_user_dict_note = 9,
    sizeof_code = 10,
    code_cap = 11,
    user_dict_text_max = 12,
    dict_max_entries = 13,
    dict_value_max = 14,
    dict_text_max = 15,
    /// Entries in the embedded dictionary; 0 in libjd-engine.
    builtin_dict_entries = 16,
};

export fn jd_abi_layout(what: u32) u32 {
    return switch (what) {
        @backingInt(AbiQuery.sizeof_state) => @sizeOf(JdState),
        @backingInt(AbiQuery.sizeof_option) => @sizeOf(QueryOption),
        @backingInt(AbiQuery.hint_cap) => @intCast(pagination.HINT_CAP),
        @backingInt(AbiQuery.scratch_options) => @intCast(query.SCRATCH_OPTIONS),
        @backingInt(AbiQuery.max_commit_len) => 2 * @max(PuncCell.get().max_value_len, dict.VALUE_MAX) + 1,
        @backingInt(AbiQuery.sizeof_user_dict_report) => @sizeOf(UserDictReport),
        @backingInt(AbiQuery.user_dict_max_entries) => user_dict.MAX_ENTRIES,
        @backingInt(AbiQuery.user_dict_value_max) => user_dict.VALUE_MAX,
        @backingInt(AbiQuery.sizeof_user_dict_info) => @sizeOf(UserDictInfo),
        @backingInt(AbiQuery.sizeof_user_dict_note) => @sizeOf(UserDictNote),
        @backingInt(AbiQuery.sizeof_code) => @sizeOf(Code),
        @backingInt(AbiQuery.code_cap) => @intCast(lookup.CODE_CAP),
        @backingInt(AbiQuery.user_dict_text_max) => @intCast(user_dict.TEXT_MAX),
        @backingInt(AbiQuery.dict_max_entries) => dict.MAX_ENTRIES,
        @backingInt(AbiQuery.dict_value_max) => dict.VALUE_MAX,
        @backingInt(AbiQuery.dict_text_max) => @intCast(dict.TEXT_MAX),
        @backingInt(AbiQuery.builtin_dict_entries) => if (builtinTrie()) |t| @intCast(t.values.len) else 0,
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

/// Skip a test that types on the embedded dictionary in a libjd built
/// without one.
fn requireBuiltin() !void {
    if (!tables.has_builtin) return error.SkipZigTest;
}

test "embedded trie max_value_len matches the actual longest value" {
    const t = builtinTrie() orelse return error.SkipZigTest;
    var max: u32 = 0;
    for (t.values) |v| max = @max(max, v.str_len);
    try std.testing.expectEqual(max, t.max_value_len);
}

test "the embedded dictionary passes the check a host's must" {
    const t = builtinTrie() orelse return error.SkipZigTest;
    const checked = try dict.open(tables.blob_bytes);
    try std.testing.expectEqual(t.fingerprint, checked.fingerprint);
    try std.testing.expectEqual(t.values.len, checked.values.len);
}

test "embedded punc max_value_len matches the actual longest string" {
    const p = PuncCell.get();
    var max: u32 = 0;
    var it = std.mem.splitScalar(u8, p.strings, 0);
    while (it.next()) |s| max = @max(max, @as(u32, @intCast(s.len)));
    try std.testing.expectEqual(max, p.max_value_len);
}

test "commit segments stay valid across later calls on the same context" {
    try requireBuiltin();
    // The contract's central claim: every pointer a caller receives is
    // immortal (it points into an embedded blob), so unlike the old scratch
    // buffer a commit can be read long after the next keystroke. Driven
    // here on the real dictionary through the C ABI.
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
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
    try requireBuiltin();
    // Regression: gen_punc's comment rule used to swallow normal.txt's
    // `#` mapping line, so the shipped blob silently lacked the key and
    // '#' fell through to the trie as a literal ASCII byte.
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    jd_press_key(handle, '#');
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("＃", joined(handle, &buf) orelse return error.NoCommit);
}

test "multiple contexts share blobs but have independent state" {
    try requireBuiltin();
    const a = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
    defer jd_deinit(a);
    const b = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
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
    try requireBuiltin();
    // `j` is the worst case in the shipped dictionary: ~11.9K candidates.
    // Walking it in windows must touch each candidate exactly once — this
    // is the property that turns a candidate-strip scroll from O(N²) into
    // O(N), so it is worth locking down against the real data.
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
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
    try requireBuiltin();
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
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

test "`;` on a last page holding one candidate commits it and opens the symbol window" {
    try requireBuiltin();
    // `j` has thousands of candidates. A frontend that pages to the end,
    // where the last page holds only the final one, leaves `;` no 2nd
    // candidate to pick — so it acts as in a one-candidate window.
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
    defer jd_deinit(handle);
    jd_press_key(handle, 'j');
    const total = jd_state_ptr(handle).options_count;
    try std.testing.expect(total > 1);

    // On any full page, `;` picks the page's 2nd candidate.
    var page: [2]QueryOption = undefined;
    jd_set_anchor(handle, total - 2);
    try std.testing.expectEqual(@as(u32, 2), jd_read_range(handle, total - 2, 2, &page, 2));
    const second = try std.testing.allocator.dupe(u8, std.mem.sliceTo(page[1].value, 0));
    defer std.testing.allocator.free(second);
    jd_press_key(handle, ';');
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(second, joined(handle, &buf) orelse return error.NoCommit);
    try std.testing.expectEqual(@as(u32, 0), jd_state_ptr(handle).options_count);

    // On the last page, `;` commits its one candidate and opens what a
    // fresh `;` opens.
    jd_press_key(handle, 'j');
    jd_set_anchor(handle, total - 1);
    try std.testing.expectEqual(@as(u32, 1), jd_read_range(handle, total - 1, 2, &page, 2));
    const last = try std.testing.allocator.dupe(u8, std.mem.sliceTo(page[0].value, 0));
    defer std.testing.allocator.free(last);
    jd_press_key(handle, ';');
    try std.testing.expectEqualStrings(last, joined(handle, &buf) orelse return error.NoCommit);
    try std.testing.expectEqual(@as(u8, 0), jd_state_ptr(handle).commit_lit);
    try std.testing.expectEqual(@as(u32, 0), jd_state_ptr(handle).anchor_index);

    const fresh = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
    defer jd_deinit(fresh);
    jd_press_key(fresh, ';');
    try std.testing.expect(jd_state_ptr(fresh).options_count > 1);
    try std.testing.expectEqual(jd_state_ptr(fresh).options_count, jd_state_ptr(handle).options_count);
    var mine: [1]QueryOption = undefined;
    try std.testing.expectEqual(@as(u32, 1), jd_read_range(handle, 0, 1, &mine, 1));
    try std.testing.expectEqualStrings("；", std.mem.sliceTo(mine[0].value, 0));
}

test "jd_scratch_ptr is writable and holds a full window" {
    try requireBuiltin();
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
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
        jd_abi_layout(@backingInt(AbiQuery.sizeof_state)),
    );
    try std.testing.expectEqual(
        @as(u32, @sizeOf(QueryOption)),
        jd_abi_layout(@backingInt(AbiQuery.sizeof_option)),
    );
    try std.testing.expectEqual(
        @as(u32, pagination.HINT_CAP),
        jd_abi_layout(@backingInt(AbiQuery.hint_cap)),
    );
    try std.testing.expectEqual(
        @as(u32, query.SCRATCH_OPTIONS),
        jd_abi_layout(@backingInt(AbiQuery.scratch_options)),
    );
    // 2 × the 1023-byte longest value any dictionary may hold + 1 literal.
    try std.testing.expectEqual(
        @as(u32, 2047),
        jd_abi_layout(@backingInt(AbiQuery.max_commit_len)),
    );
    try std.testing.expectEqual(
        @as(u32, @sizeOf(UserDictReport)),
        jd_abi_layout(@backingInt(AbiQuery.sizeof_user_dict_report)),
    );
    try std.testing.expectEqual(user_dict.MAX_ENTRIES, jd_abi_layout(@backingInt(AbiQuery.user_dict_max_entries)));
    try std.testing.expectEqual(user_dict.VALUE_MAX, jd_abi_layout(@backingInt(AbiQuery.user_dict_value_max)));
    try std.testing.expectEqual(user_dict.TEXT_MAX, jd_abi_layout(@backingInt(AbiQuery.user_dict_text_max)));
    try std.testing.expectEqual(
        @as(u32, @sizeOf(UserDictInfo)),
        jd_abi_layout(@backingInt(AbiQuery.sizeof_user_dict_info)),
    );
    try std.testing.expectEqual(
        @as(u32, @sizeOf(UserDictNote)),
        jd_abi_layout(@backingInt(AbiQuery.sizeof_user_dict_note)),
    );
    try std.testing.expectEqual(@as(u32, @sizeOf(Code)), jd_abi_layout(@backingInt(AbiQuery.sizeof_code)));
    try std.testing.expectEqual(@as(u32, lookup.CODE_CAP), jd_abi_layout(@backingInt(AbiQuery.code_cap)));
    try std.testing.expectEqual(dict.MAX_ENTRIES, jd_abi_layout(@backingInt(AbiQuery.dict_max_entries)));
    try std.testing.expectEqual(dict.VALUE_MAX, jd_abi_layout(@backingInt(AbiQuery.dict_value_max)));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), jd_abi_layout(@backingInt(AbiQuery.dict_text_max)));
    const builtin_entries: u32 = if (builtinTrie()) |t| @intCast(t.values.len) else 0;
    try std.testing.expectEqual(builtin_entries, jd_abi_layout(@backingInt(AbiQuery.builtin_dict_entries)));
    try std.testing.expectEqual(tables.has_builtin, builtin_entries > 100_000);
    // Unknown queries are a benign 0 rather than a trap.
    try std.testing.expectEqual(@as(u32, 0), jd_abi_layout(9999));
}

// =========================================================================
// Tests — user dictionary through the C ABI, against the real blobs.
// =========================================================================

/// A built blob in host-style memory: the host sizes it by the bound and
/// keeps it alive for as long as any context made from it.
const HostBlob = struct {
    buf: []align(4) u8,
    len: usize,
    report: UserDictReport,

    const TAG: u64 = 0xFEED_FACE_CAFE_BEEF;

    fn build(phrases: []const u8) !HostBlob {
        const cap = jd_user_dict_blob_bound(phrases.ptr, phrases.len);
        const buf = try std.testing.allocator.alignedAlloc(u8, .@"4", cap);
        errdefer std.testing.allocator.free(buf);
        var len: usize = 0;
        var report: UserDictReport = undefined;
        const status = jd_user_dict_build(null, 0, phrases.ptr, phrases.len, TAG, buf.ptr, cap, &len, &report);
        try std.testing.expectEqual(status, report.status);
        return .{ .buf = buf, .len = len, .report = report };
    }

    /// The notes, read where the report says they are — in the same
    /// buffer, past the blob.
    fn notes(self: *const HostBlob) []const UserDictNote {
        const r = self.report;
        if (r.notes == 0) return &.{};
        return std.mem.bytesAsSlice(
            UserDictNote,
            @as([]align(4) const u8, @alignCast(self.buf[r.notes_offset..][0 .. r.notes * @sizeOf(UserDictNote)])),
        );
    }

    fn deinit(self: *HostBlob) void {
        std.testing.allocator.free(self.buf);
    }

    fn init(self: *const HostBlob) ?*JdContext {
        return jd_init(null, 0, self.buf.ptr, self.len);
    }
};

fn baseHasPath(keys: []const u8) bool {
    const t = builtinTrie().?;
    var node = t.root();
    for (keys) |k| node = node.getChild(t, k) orelse return false;
    return true;
}

/// Built-in words on exactly this code.
fn baseWordCount(keys: []const u8) u32 {
    const t = builtinTrie().?;
    var node = t.root();
    for (keys) |k| node = node.getChild(t, k) orelse return 0;
    return @intCast(node.values(t).len());
}

test "a user dictionary built through the ABI merges into the real dictionary" {
    try requireBuiltin();
    // "zzzzzz" must be free in the built-in tables for this test to mean
    // anything; "b" carries 不 as its first candidate.
    try std.testing.expect(!baseHasPath("zzzzzz"));

    var blob = try HostBlob.build(
        "# user phrases\n" ++
            "测试词\tb\n" ++
            "不\tb\n" ++ // built-in on the same code → dropped
            "键道\tzzzzzz\n",
    );
    defer blob.deinit();
    try std.testing.expectEqual(@as(u32, 0), blob.report.status);
    try std.testing.expectEqual(@as(u32, 2), blob.report.entries);
    try std.testing.expectEqual(@as(u32, 1), blob.report.dropped);
    // Two notes, ascending: 测试词 shares b with the built-in words (重码),
    // 不 repeats one of them. The context from the same buffer below is
    // created while the notes are still readable — jd_init reads only the
    // blob prefix.
    try std.testing.expectEqual(@as(u32, 1), blob.report.shared);
    const words_on_b = baseWordCount("b");
    try std.testing.expect(words_on_b >= 1);
    const want_notes = [_]UserDictNote{
        .{ .line = 2, .flags = user_dict.NoteFlag.code_in_builtin, .other = 0, .builtin = words_on_b, .peers = 0 },
        .{ .line = 3, .flags = user_dict.NoteFlag.repeats_builtin, .other = 0, .builtin = words_on_b, .peers = 0 },
    };
    try std.testing.expectEqualDeep(@as([]const UserDictNote, &want_notes), blob.notes());

    var info: UserDictInfo = undefined;
    try std.testing.expectEqual(@as(u32, 0), jd_user_dict_check(null, 0, blob.buf.ptr, blob.len, &info));
    try std.testing.expectEqual(HostBlob.TAG, info.source_tag);
    try std.testing.expectEqual(@as(u32, 2), info.entries);

    const handle = blob.init() orelse return error.InitFailed;
    defer jd_deinit(handle);

    // The user word leads the built-in candidates on the same code.
    jd_press_key(handle, 'b');
    var out: [2]QueryOption = undefined;
    try std.testing.expectEqual(@as(u32, 2), jd_read_range(handle, 0, 2, &out, 2));
    try std.testing.expectEqualStrings("测试词", std.mem.sliceTo(out[0].value, 0));
    try std.testing.expectEqualStrings("不", std.mem.sliceTo(out[1].value, 0));
    jd_press_key(handle, ' ');
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("测试词", joined(handle, &buf) orelse return error.NoCommit);

    // A user-only code composes like a built-in one. Its sole candidate is
    // not committed on the last key: the next key commits it, and composes
    // on its own.
    for ("zzzzzz") |k| jd_press_key(handle, k);
    try std.testing.expect(joined(handle, &buf) == null);
    try std.testing.expectEqual(@as(u32, 1), jd_state_ptr(handle).options_count);
    jd_press_key(handle, 'h');
    try std.testing.expectEqualStrings("键道", joined(handle, &buf) orelse return error.NoCommit);
    {
        // The composition is now just "h": the same list a fresh `h` gets.
        const fresh = blob.init() orelse return error.InitFailed;
        defer jd_deinit(fresh);
        jd_press_key(fresh, 'h');
        try std.testing.expect(jd_state_ptr(fresh).options_count > 0);
        try std.testing.expectEqual(jd_state_ptr(fresh).options_count, jd_state_ptr(handle).options_count);
    }

    // With no 2nd candidate to pick, `;` commits the sole one and opens the
    // `;` symbol window, exactly as a fresh `;` does.
    jd_reset(handle);
    for ("zzzzzz;") |k| jd_press_key(handle, k);
    try std.testing.expectEqualStrings("键道", joined(handle, &buf) orelse return error.NoCommit);
    {
        const fresh = blob.init() orelse return error.InitFailed;
        defer jd_deinit(fresh);
        jd_press_key(fresh, ';');
        try std.testing.expect(jd_state_ptr(fresh).options_count > 1);
        try std.testing.expectEqual(jd_state_ptr(fresh).options_count, jd_state_ptr(handle).options_count);
        var mine: [1]QueryOption = undefined;
        var theirs: [1]QueryOption = undefined;
        try std.testing.expectEqual(@as(u32, 1), jd_read_range(handle, 0, 1, &mine, 1));
        try std.testing.expectEqual(@as(u32, 1), jd_read_range(fresh, 0, 1, &theirs, 1));
        try std.testing.expectEqualStrings("；", std.mem.sliceTo(theirs[0].value, 0));
        try std.testing.expectEqualStrings("；", std.mem.sliceTo(mine[0].value, 0));
    }

    // The commit pointed into the host's blob, which is still alive — and
    // the notes past it are untouched by the context.
    const held = jd_state_ptr(handle).commit_a orelse return error.NoCommit;
    try std.testing.expect(@intFromPtr(held) >= @intFromPtr(blob.buf.ptr));
    try std.testing.expect(@intFromPtr(held) < @intFromPtr(blob.buf.ptr) + blob.len);
    try std.testing.expectEqualDeep(@as([]const UserDictNote, &want_notes), blob.notes());
}

test "the same context without a user dictionary is unchanged" {
    try requireBuiltin();
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
    defer jd_deinit(handle);
    jd_press_key(handle, 'b');
    var out: [1]QueryOption = undefined;
    try std.testing.expectEqual(@as(u32, 1), jd_read_range(handle, 0, 1, &out, 1));
    try std.testing.expectEqualStrings("不", std.mem.sliceTo(out[0].value, 0));
}

test "jd_init refuses a stale, corrupt or misaligned user dictionary" {
    try requireBuiltin();
    var blob = try HostBlob.build("测试词\tb\n");
    defer blob.deinit();

    // Fingerprint of another release.
    const fp_off = 12;
    blob.buf[fp_off] ^= 0xFF;
    try std.testing.expectEqual(@backingInt(UserDictStatus.stale), jd_user_dict_check(null, 0, blob.buf.ptr, blob.len, null));
    try std.testing.expect(blob.init() == null);
    blob.buf[fp_off] ^= 0xFF;
    try std.testing.expectEqual(@as(u32, 0), jd_user_dict_check(null, 0, blob.buf.ptr, blob.len, null));

    // Truncated.
    try std.testing.expectEqual(@backingInt(UserDictStatus.corrupt), jd_user_dict_check(null, 0, blob.buf.ptr, blob.len - 1, null));
    try std.testing.expect(jd_init(null, 0, blob.buf.ptr, blob.len - 1) == null);

    // Misaligned.
    const off_by_one: [*]const u8 = blob.buf.ptr + 1;
    try std.testing.expectEqual(@backingInt(UserDictStatus.misaligned), jd_user_dict_check(null, 0, off_by_one, blob.len - 1, null));
    try std.testing.expect(jd_init(null, 0, off_by_one, blob.len - 1) == null);

    // NULL with a length is simply "no dictionary".
    const handle = jd_init(null, 16, null, 16) orelse return error.OutOfMemory;
    jd_deinit(handle);
}

test "jd_user_dict_build notes bad lines and reports buffer problems" {
    try requireBuiltin();
    var report: UserDictReport = undefined;
    var len: usize = 1;
    var buf: [256]u8 align(4) = undefined;

    // A line that does not parse is skipped and noted, not fatal. "zzzzzz"
    // is free in the built-in tables, so the only note is the bad line's.
    const bad = "键道\tzzzzzz\noops\n";
    try std.testing.expectEqual(
        @as(u32, 0),
        jd_user_dict_build(null, 0, bad.ptr, bad.len, 0, &buf, buf.len, &len, &report),
    );
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(@as(u32, 1), report.entries);
    try std.testing.expectEqual(@as(u32, 1), report.invalid);
    try std.testing.expectEqual(@as(u32, 1), report.notes);
    const note: *const UserDictNote = @ptrCast(@alignCast(&buf[report.notes_offset]));
    try std.testing.expectEqualDeep(
        UserDictNote{ .line = 2, .flags = user_dict.NoteFlag.malformed, .other = 0, .builtin = 0, .peers = 0 },
        note.*,
    );
    try std.testing.expectEqual(@as(u32, 0), jd_user_dict_check(null, 0, &buf, len, null));

    const ok = "好\thz\n";
    try std.testing.expectEqual(
        @backingInt(UserDictStatus.buffer_too_small),
        jd_user_dict_build(null, 0, ok.ptr, ok.len, 0, &buf, 8, &len, &report),
    );
    try std.testing.expectEqual(
        @backingInt(UserDictStatus.buffer_too_small),
        jd_user_dict_build(null, 0, ok.ptr, ok.len, 0, null, 0, &len, &report),
    );
    try std.testing.expectEqual(
        @backingInt(UserDictStatus.misaligned),
        jd_user_dict_build(null, 0, ok.ptr, ok.len, 0, @as([*]u8, &buf) + 2, buf.len - 2, &len, &report),
    );

    // The report is optional; the status still comes back.
    try std.testing.expectEqual(
        @as(u32, 0),
        jd_user_dict_build(null, 0, ok.ptr, ok.len, 0, &buf, buf.len, &len, null),
    );
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(@as(u32, 0), jd_user_dict_check(null, 0, &buf, len, null));

    // An empty text is a valid, empty dictionary.
    try std.testing.expectEqual(@as(u32, 0), jd_user_dict_build(null, 0, null, 0, 0, &buf, buf.len, &len, &report));
    try std.testing.expectEqual(@as(u32, 0), report.notes);
    try std.testing.expectEqual(@as(u32, 0), report.entries);
    const handle = jd_init(null, 0, &buf, len) orelse return error.InitFailed;
    jd_deinit(handle);
}

test "jd_alloc hands out aligned blocks a host can build into and free" {
    try requireBuiltin();
    try std.testing.expect(jd_alloc(0) == null);
    jd_free(null, 0);

    const phrases = "测试词\tb\n";
    const cap = jd_user_dict_blob_bound(phrases.ptr, phrases.len);
    const block = jd_alloc(cap) orelse return error.OutOfMemory;
    defer jd_free(block, cap);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(block), 16));

    var len: usize = 0;
    var report: UserDictReport = undefined;
    try std.testing.expectEqual(
        @as(u32, 0),
        jd_user_dict_build(null, 0, phrases.ptr, phrases.len, 7, block, cap, &len, &report),
    );
    try std.testing.expectEqual(@as(u32, 1), report.entries);
    const handle = jd_init(null, 0, block, len) orelse return error.InitFailed;
    defer jd_deinit(handle);
    jd_press_key(handle, 'b');
    var out: [1]QueryOption = undefined;
    try std.testing.expectEqual(@as(u32, 1), jd_read_range(handle, 0, 1, &out, 1));
    try std.testing.expectEqualStrings("测试词", std.mem.sliceTo(out[0].value, 0));
}

// =========================================================================
// Tests — reverse lookup through the C ABI, against the real tables.
// =========================================================================

fn codeKeys(code: *const Code) []const u8 {
    return std.mem.sliceTo(&code.keys, 0);
}

/// What typing `keys` into a fresh `handle` lists at candidate `index` —
/// the property every code `jd_lookup_codes` reports must satisfy.
fn candidateAfterTyping(handle: *JdContext, keys: []const u8, index: u32) ?[]const u8 {
    jd_reset(handle);
    for (keys) |k| jd_press_key(handle, k);
    if (jd_state_ptr(handle).commit_a != null) return null; // a key committed instead of composing
    var one: [1]QueryOption = undefined;
    if (jd_read_range(handle, index, 1, &one, 1) != 1) return null;
    return std.mem.sliceTo(one[0].value, 0);
}

fn expectCodes(handle: *JdContext, value: []const u8, want: []const []const u8) !void {
    var out: [16]Code = undefined;
    const n = jd_lookup_codes(handle, value.ptr, value.len, &out, out.len);
    try std.testing.expectEqual(@as(u32, @intCast(want.len)), n);
    for (want, out[0..want.len]) |keys, *c| {
        try std.testing.expectEqualStrings(keys, codeKeys(c));
        try std.testing.expectEqualStrings(value, candidateAfterTyping(handle, keys, c.index) orelse return error.NotTypeable);
    }
}

test "jd_lookup_codes finds every built-in code of a value, shortest first" {
    try requireBuiltin();
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    try expectCodes(handle, "的", &.{ "d", "deuiua", "dkuiua" });
    try expectCodes(handle, "键道", &.{"jmdzi"});
    try expectCodes(handle, "：", &.{";;"});
    // The value with the most codes in the tables.
    try expectCodes(handle, "着", &.{ "o", "fe", "qe", "flo", "fzou", "qzou", "feouia", "flouia", "fzouia", "qeouia", "qzouia" });

    var out: [4]Code = undefined;
    try std.testing.expectEqual(@as(u32, 0), jd_lookup_codes(handle, "不在词库里的词".ptr, "不在词库里的词".len, &out, out.len));
    try std.testing.expectEqual(@as(u32, 0), jd_lookup_codes(handle, null, 0, &out, out.len));
    // Counting needs no buffer at all.
    try std.testing.expectEqual(@as(u32, 3), jd_lookup_codes(handle, "的".ptr, "的".len, null, 0));
}

test "jd_lookup_codes leaves the composition alone" {
    try requireBuiltin();
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    jd_press_key(handle, 'b');
    const before = jd_state_ptr(handle).*;
    var out: [4]Code = undefined;
    _ = jd_lookup_codes(handle, "的".ptr, "的".len, &out, out.len);
    try std.testing.expectEqualDeep(before, jd_state_ptr(handle).*);
    jd_press_key(handle, ' ');
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("不", joined(handle, &buf) orelse return error.NoCommit);
}

test "every code jd_lookup_codes reports types its value at its index" {
    try requireBuiltin();
    // Sweep a spread of the real dictionary: look each value up, then type
    // each code it reports into a fresh composition and read the candidate
    // at the reported index. Also check nothing is missed: the codes must
    // be exactly the distinct nodes that hold the value.
    const t = builtinTrie().?;
    const handle = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
    defer jd_deinit(handle);

    var checked: usize = 0;
    var v: u32 = 0;
    while (v < t.values.len) : (v += 97) {
        const value = t.values[v].bytes(t.strings);
        var out: [16]Code = undefined;
        const n = jd_lookup_codes(handle, value.ptr, value.len, &out, out.len);
        try std.testing.expect(n >= 1 and n <= out.len);

        var nodes_with_value: u32 = 0;
        var last: ?u32 = null;
        for (t.valuesEqualTo(value)) |hit| {
            const node = t.nodeOfValue(hit);
            if (last != node) nodes_with_value += 1;
            last = node;
        }
        try std.testing.expectEqual(nodes_with_value, n);

        for (out[0..n], 0..) |*c, i| {
            if (i > 0) {
                const prev = codeKeys(&out[i - 1]);
                try std.testing.expect(prev.len <= codeKeys(c).len);
            }
            try std.testing.expectEqualStrings(value, candidateAfterTyping(handle, codeKeys(c), c.index) orelse return error.NotTypeable);
            checked += 1;
        }
    }
    try std.testing.expect(checked > 1000);
}

test "jd_lookup_codes merges the context's user dictionary" {
    try requireBuiltin();
    // "zzzzzz" is free in the built-in tables; 的 sits on `d` first.
    try std.testing.expect(!baseHasPath("zzzzzz"));

    var blob = try HostBlob.build(
        "的\tzzzzzz\n" ++
            "测试词\td\n" ++ // on 的's code: 的 is now candidate 1 there
            "的\td\n" ++ // repeats the built-in word → dropped, not reported twice
            "键道\tjd\n",
    );
    defer blob.deinit();
    const handle = blob.init() orelse return error.InitFailed;
    defer jd_deinit(handle);

    var out: [8]Code = undefined;
    const n = jd_lookup_codes(handle, "的".ptr, "的".len, &out, out.len);
    try std.testing.expectEqual(@as(u32, 4), n);
    const want = [_]struct { []const u8, u32, u32 }{
        .{ "d", 1, 0 },
        .{ "deuiua", 0, 0 },
        .{ "dkuiua", 0, 0 },
        .{ "zzzzzz", 0, lookup.CodeFlag.user },
    };
    for (want, out[0..n]) |w, *c| {
        try std.testing.expectEqualStrings(w[0], codeKeys(c));
        try std.testing.expectEqual(w[1], c.index);
        try std.testing.expectEqual(w[2], c.flags);
        try std.testing.expectEqualStrings("的", candidateAfterTyping(handle, w[0], c.index) orelse return error.NotTypeable);
    }

    try expectCodes(handle, "键道", &.{ "jd", "jmdzi" });
    try expectCodes(handle, "测试词", &.{"d"});

    // The same lookup on a context without the dictionary sees none of it.
    const plain = jd_init(null, 0, null, 0) orelse return error.OutOfMemory;
    defer jd_deinit(plain);
    try std.testing.expectEqual(@as(u32, 0), jd_lookup_codes(plain, "测试词".ptr, "测试词".len, &out, out.len));
    try std.testing.expectEqual(@as(u32, 3), jd_lookup_codes(plain, "的".ptr, "的".len, &out, out.len));
    try std.testing.expectEqualStrings("d", codeKeys(&out[0]));
    try std.testing.expectEqual(@as(u32, 0), out[0].index);
}

test "jd_user_dict_hash: the library's hash, NULL taken for empty" {
    const text = "键道\tjd\n";
    try std.testing.expectEqual(user_dict.hash(text), jd_user_dict_hash(text.ptr, text.len));
    try std.testing.expectEqual(user_dict.hash(""), jd_user_dict_hash(null, 0));
    try std.testing.expectEqual(user_dict.hash(""), jd_user_dict_hash(text.ptr, 0));
}

// =========================================================================
// Tests — a host's own dictionary in place of the embedded one.
// =========================================================================

/// A dictionary blob built through the ABI, in host-style memory.
const HostDict = struct {
    buf: []align(4) u8,
    len: usize,
    report: UserDictReport,

    fn build(text: []const u8) !HostDict {
        const cap = jd_dict_blob_bound(text.ptr, text.len);
        const buf = try std.testing.allocator.alignedAlloc(u8, .@"4", cap);
        errdefer std.testing.allocator.free(buf);
        var len: usize = 0;
        var report: UserDictReport = undefined;
        const status = jd_dict_build(text.ptr, text.len, 0xD1C7, buf.ptr, cap, &len, &report);
        try std.testing.expectEqual(status, report.status);
        try std.testing.expectEqual(@as(u32, 0), status);
        return .{ .buf = buf, .len = len, .report = report };
    }

    fn deinit(self: *HostDict) void {
        std.testing.allocator.free(self.buf);
    }

    /// A user dictionary built on top of this one.
    fn userDict(self: *const HostDict, phrases: []const u8) !HostBlob {
        const cap = jd_user_dict_blob_bound(phrases.ptr, phrases.len);
        const buf = try std.testing.allocator.alignedAlloc(u8, .@"4", cap);
        errdefer std.testing.allocator.free(buf);
        var len: usize = 0;
        var report: UserDictReport = undefined;
        const status = jd_user_dict_build(self.buf.ptr, self.len, phrases.ptr, phrases.len, 0, buf.ptr, cap, &len, &report);
        try std.testing.expectEqual(@as(u32, 0), status);
        return .{ .buf = buf, .len = len, .report = report };
    }
};

fn firstCandidate(handle: *JdContext, keys: []const u8) ?[]const u8 {
    jd_reset(handle);
    for (keys) |k| jd_press_key(handle, k);
    var one: [1]QueryOption = undefined;
    if (jd_read_range(handle, 0, 1, &one, 1) != 1) return null;
    return std.mem.sliceTo(one[0].value, 0);
}

test "a host's dictionary replaces the embedded one" {
    var d = try HostDict.build(
        "# a dictionary of its own\n" ++
            "你\tn\n" ++
            "你好\tnh\n" ++
            "；\t;\n" ++
            "：\t;;\n" ++
            "bad;\tn;\n", // ';' after a letter: skipped
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(u32, 4), d.report.entries);
    try std.testing.expectEqual(@as(u32, 1), d.report.invalid);

    var info: UserDictInfo = undefined;
    try std.testing.expectEqual(@as(u32, 0), jd_dict_check(d.buf.ptr, d.len, &info));
    try std.testing.expectEqual(@as(u64, 0xD1C7), info.source_tag);
    try std.testing.expectEqual(@as(u32, 4), info.entries);

    const handle = jd_init(d.buf.ptr, d.len, null, 0) orelse return error.InitFailed;
    defer jd_deinit(handle);
    try std.testing.expectEqualStrings("你", firstCandidate(handle, "n").?);
    try std.testing.expectEqualStrings("你好", firstCandidate(handle, "nh").?);
    try std.testing.expectEqualStrings("：", firstCandidate(handle, ";;").?);
    // Nothing of the embedded dictionary: "b" is not a code here.
    try std.testing.expect(firstCandidate(handle, "b") == null);

    var out: [4]Code = undefined;
    try std.testing.expectEqual(@as(u32, 1), jd_lookup_codes(handle, "你好".ptr, "你好".len, &out, out.len));
    try std.testing.expectEqualStrings("nh", codeKeys(&out[0]));
    try std.testing.expectEqual(@as(u32, 0), jd_lookup_codes(handle, "不".ptr, "不".len, &out, out.len));
}

test "a user dictionary sits on the dictionary it was built against, and no other" {
    var d = try HostDict.build("你\tn\n拟\tn\n");
    defer d.deinit();
    var blob = try d.userDict("你\tn\n泥\tn\n");
    defer blob.deinit();
    // 你 repeats a word of the host's dictionary; 泥 shares its code.
    try std.testing.expectEqual(@as(u32, 1), blob.report.entries);
    try std.testing.expectEqual(@as(u32, 1), blob.report.dropped);
    try std.testing.expectEqual(@as(u32, 1), blob.report.shared);

    try std.testing.expectEqual(@as(u32, 0), jd_user_dict_check(d.buf.ptr, d.len, blob.buf.ptr, blob.len, null));
    const handle = jd_init(d.buf.ptr, d.len, blob.buf.ptr, blob.len) orelse return error.InitFailed;
    defer jd_deinit(handle);
    jd_reset(handle);
    jd_press_key(handle, 'n');
    var three: [3]QueryOption = undefined;
    try std.testing.expectEqual(@as(u32, 3), jd_read_range(handle, 0, 3, &three, 3));
    try std.testing.expectEqualStrings("泥", std.mem.sliceTo(three[0].value, 0));
    try std.testing.expectEqualStrings("你", std.mem.sliceTo(three[1].value, 0));
    try std.testing.expectEqualStrings("拟", std.mem.sliceTo(three[2].value, 0));

    // On another dictionary — the embedded one, or a different host's — the
    // user dictionary is stale.
    var other = try HostDict.build("你\tn\n");
    defer other.deinit();
    try std.testing.expectEqual(@backingInt(UserDictStatus.stale), jd_user_dict_check(other.buf.ptr, other.len, blob.buf.ptr, blob.len, null));
    try std.testing.expect(jd_init(other.buf.ptr, other.len, blob.buf.ptr, blob.len) == null);
    if (tables.has_builtin) {
        try std.testing.expectEqual(@backingInt(UserDictStatus.stale), jd_user_dict_check(null, 0, blob.buf.ptr, blob.len, null));
        try std.testing.expect(jd_init(null, 0, blob.buf.ptr, blob.len) == null);
    }
}

test "an empty dictionary leaves the user dictionary alone" {
    // What a client does when its user turns the embedded dictionary off:
    // the user dictionary becomes everything there is, and nothing in it is
    // a repeat of a word no longer there.
    var empty = try HostDict.build("");
    defer empty.deinit();
    var blob = try empty.userDict("不\tb\n测试\tb\n：\t;;\n");
    defer blob.deinit();
    try std.testing.expectEqual(@as(u32, 3), blob.report.entries);
    try std.testing.expectEqual(@as(u32, 0), blob.report.dropped);

    const handle = jd_init(empty.buf.ptr, empty.len, blob.buf.ptr, blob.len) orelse return error.InitFailed;
    defer jd_deinit(handle);
    jd_reset(handle);
    jd_press_key(handle, 'b');
    var three: [3]QueryOption = undefined;
    try std.testing.expectEqual(@as(u32, 2), jd_read_range(handle, 0, 3, &three, 3));
    try std.testing.expectEqualStrings("不", std.mem.sliceTo(three[0].value, 0));
    try std.testing.expectEqualStrings("测试", std.mem.sliceTo(three[1].value, 0));
    try std.testing.expectEqualStrings("：", firstCandidate(handle, ";;").?);
    try std.testing.expect(firstCandidate(handle, "n") == null);
}

test "jd_init and the checks refuse a bad dictionary" {
    var d = try HostDict.build("你\tn\n");
    defer d.deinit();
    // Truncated.
    try std.testing.expectEqual(@backingInt(UserDictStatus.corrupt), jd_dict_check(d.buf.ptr, d.len - 1, null));
    try std.testing.expect(jd_init(d.buf.ptr, d.len - 1, null, 0) == null);
    // Misaligned.
    const off_by_one: [*]const u8 = d.buf.ptr + 1;
    try std.testing.expectEqual(@backingInt(UserDictStatus.misaligned), jd_dict_check(off_by_one, d.len - 1, null));
    // Another format version.
    d.buf[4] ^= 0xFF;
    try std.testing.expectEqual(@backingInt(UserDictStatus.stale), jd_dict_check(d.buf.ptr, d.len, null));
    try std.testing.expect(jd_init(d.buf.ptr, d.len, null, 0) == null);
    // A user dictionary build or check against it fails the same way.
    var buf: [512]u8 align(4) = undefined;
    var report: UserDictReport = undefined;
    try std.testing.expectEqual(
        @backingInt(UserDictStatus.stale),
        jd_user_dict_build(d.buf.ptr, d.len, "x\ta\n", 4, 0, &buf, buf.len, null, &report),
    );
    try std.testing.expectEqual(@backingInt(UserDictStatus.stale), report.status);
    try std.testing.expectEqual(
        @backingInt(UserDictStatus.stale),
        jd_user_dict_check(d.buf.ptr, d.len, &buf, buf.len, null),
    );
    d.buf[4] ^= 0xFF;
    // NULL is corrupt.
    try std.testing.expectEqual(@backingInt(UserDictStatus.corrupt), jd_dict_check(null, 0, null));
}

test "jd_dict_build notes bad lines and reports buffer problems" {
    var buf: [1024]u8 align(4) = undefined;
    var report: UserDictReport = undefined;
    var len: usize = 1;
    const text = "你\tn\n你\tn\noops\n";
    try std.testing.expectEqual(@as(u32, 0), jd_dict_build(text.ptr, text.len, 0, &buf, buf.len, &len, &report));
    try std.testing.expect(len > 0);
    try std.testing.expectEqual(@as(u32, 1), report.entries);
    try std.testing.expectEqual(@as(u32, 1), report.dropped);
    try std.testing.expectEqual(@as(u32, 1), report.invalid);
    try std.testing.expectEqual(@as(u32, 2), report.notes);
    const notes = std.mem.bytesAsSlice(UserDictNote, @as([]align(4) u8, @alignCast(buf[report.notes_offset..][0 .. 2 * @sizeOf(UserDictNote)])));
    try std.testing.expectEqualDeep(UserDictNote{ .line = 2, .flags = user_dict.NoteFlag.repeats_line, .other = 1, .builtin = 0, .peers = 0 }, notes[0]);
    try std.testing.expectEqualDeep(UserDictNote{ .line = 3, .flags = user_dict.NoteFlag.malformed, .other = 0, .builtin = 0, .peers = 0 }, notes[1]);

    try std.testing.expectEqual(@backingInt(UserDictStatus.buffer_too_small), jd_dict_build(text.ptr, text.len, 0, &buf, 8, &len, &report));
    try std.testing.expectEqual(@as(usize, 0), len);
    try std.testing.expectEqual(@backingInt(UserDictStatus.buffer_too_small), jd_dict_build(text.ptr, text.len, 0, null, 0, &len, &report));
    try std.testing.expectEqual(@backingInt(UserDictStatus.misaligned), jd_dict_build(text.ptr, text.len, 0, @as([*]u8, &buf) + 2, buf.len - 2, &len, &report));
    // The report is optional.
    try std.testing.expectEqual(@as(u32, 0), jd_dict_build(null, 0, 0, &buf, buf.len, &len, null));
    try std.testing.expectEqual(@as(u32, 0), jd_dict_check(&buf, len, null));
}

test "without an embedded dictionary, NULL is no dictionary at all" {
    if (tables.has_builtin) return error.SkipZigTest;
    try std.testing.expect(jd_init(null, 0, null, 0) == null);
    var buf: [512]u8 align(4) = undefined;
    var report: UserDictReport = undefined;
    try std.testing.expectEqual(
        @backingInt(UserDictStatus.no_builtin),
        jd_user_dict_build(null, 0, "x\ta\n", 4, 0, &buf, buf.len, null, &report),
    );
    try std.testing.expectEqual(@backingInt(UserDictStatus.no_builtin), jd_user_dict_check(null, 0, &buf, buf.len, null));
    try std.testing.expectEqual(@as(u32, 0), jd_abi_layout(@backingInt(AbiQuery.builtin_dict_entries)));
}
