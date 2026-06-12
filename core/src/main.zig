const std = @import("std");

const query = @import("./query.zig");
const trie_mod = @import("trie");
const tables = @import("./tables.zig");

var gpa: std.heap.DebugAllocator(.{}) = .init;
const allocator = gpa.allocator();

// Parsed once on first jd_init. Lives in BSS; the slice headers inside point
// at the rodata-embedded blob bytes, so storage cost is just sizeof(Trie).
var trie_value: trie_mod.Trie = undefined;
var context: query.Context = undefined;

export fn jd_init(page_size: u8) void {
    trie_value = trie_mod.Trie.fromBytes(tables.blob_bytes) catch unreachable;
    context = query.Context.init(allocator, .{
        .trie = &trie_value,
        .page_size = page_size,
    });
}

export fn jd_press_key(key: u8) query.QueryResult {
    return context.pressKey(key);
}

export fn jd_next_page() query.QueryResult {
    return context.nextPage();
}

export fn jd_prev_page() query.QueryResult {
    return context.prevPage();
}

export fn jd_backspace() query.QueryResult {
    return context.backspace();
}

export fn jd_reset() void {
    context.reset();
}

export fn jd_deinit() void {
    context.deinit();
}
