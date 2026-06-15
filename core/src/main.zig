const std = @import("std");
const builtin = @import("builtin");

const query = @import("./query.zig");
const trie_mod = @import("trie");
const tables = @import("./tables.zig");

// In Release every context shares one process-wide thread-safe allocator
// (smp_allocator — pure Zig, no libc dep). In Debug each context owns its
// own inline DebugAllocator so jd_deinit reports leaks per-context. The
// wrapper struct itself is always allocated via the shared allocator (the
// Debug allocator inside the wrapper is the one whose state we want to
// track).
const shared_allocator = std.heap.smp_allocator;

// The trie is parsed once from the embedded blob on the first jd_init call
// and shared read-only across every context. Slice headers live in BSS;
// the bytes they point at live in rodata. A 3-state atomic flag handles
// the one-time-init race: the first caller does the parse, any caller that
// arrives mid-parse spins until done. The parse itself is O(1) (just slice
// header construction), so the spin is microscopic in practice.
const TrieInitState = enum(u8) { uninit, initializing, done };
var trie_value: trie_mod.Trie = undefined;
var trie_init_state: std.atomic.Value(u8) = .init(@intFromEnum(TrieInitState.uninit));

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

// Opaque handle exposed to C consumers as `struct jd_context *`.
pub const JdContext = opaque {};

const ContextWrapper = struct {
    context: query.Context,
    debug_gpa: if (builtin.mode == .Debug) std.heap.DebugAllocator(.{}) else void,
};

fn wrapperOf(handle: *JdContext) *ContextWrapper {
    return @ptrCast(@alignCast(handle));
}

export fn jd_init(page_size: u8) ?*JdContext {
    ensureTrieInit();

    const wrapper = shared_allocator.create(ContextWrapper) catch return null;

    const ctx_allocator: std.mem.Allocator = if (builtin.mode == .Debug) blk: {
        wrapper.debug_gpa = .init;
        break :blk wrapper.debug_gpa.allocator();
    } else shared_allocator;

    wrapper.context = query.Context.init(ctx_allocator, .{
        .trie = &trie_value,
        .page_size = page_size,
    });

    return @ptrCast(wrapper);
}

export fn jd_press_key(handle: *JdContext, key: u8) query.QueryResult {
    return wrapperOf(handle).context.pressKey(key);
}

export fn jd_next_page(handle: *JdContext) query.QueryResult {
    return wrapperOf(handle).context.nextPage();
}

export fn jd_prev_page(handle: *JdContext) query.QueryResult {
    return wrapperOf(handle).context.prevPage();
}

export fn jd_backspace(handle: *JdContext) query.QueryResult {
    return wrapperOf(handle).context.backspace();
}

export fn jd_reset(handle: *JdContext) void {
    wrapperOf(handle).context.reset();
}

export fn jd_deinit(handle: *JdContext) void {
    const wrapper = wrapperOf(handle);
    wrapper.context.deinit();
    if (builtin.mode == .Debug) _ = wrapper.debug_gpa.deinit();
    shared_allocator.destroy(wrapper);
}
