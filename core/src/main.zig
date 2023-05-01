const std = @import("std");

const query = @import("./query.zig");
const root_node = @import("./tables.zig").root_node;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var context: query.Context = undefined;

export fn jd_init(page_size: u8) void {
    context = query.Context.init(allocator, .{
        .root_node = &root_node,
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
