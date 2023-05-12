const std = @import("std");
const builtin = @import("builtin");

const trie = @import("./trie.zig");

pub const root_node = blk: {
    comptime var node = trie.Node.init();

    const tables = [_][]const u8{
        @embedFile("./tables/1.danzi.txt"),
        @embedFile("./tables/2.cizu.txt"),
        @embedFile("./tables/3.fuhao.txt"),
        @embedFile("./tables/4.buchong.txt"),
        @embedFile("./tables/5.lianjie.txt"),
        @embedFile("./tables/6.yingwen.txt"),
        @embedFile("./tables/7.chaojizici.txt"),
        @embedFile("./tables/8.wxw.txt"),
    };

    const end_of_line = if (@import("tables_eol").tables_eol) |tables_eol| tables_eol else if (builtin.os.tag == .windows) "\r\n" else "\n";

    @setEvalBranchQuota(100_000_000);
    inline for (tables) |table_content| {
        var lines_iter = std.mem.split(u8, table_content, end_of_line);

        while (lines_iter.next()) |line| {
            const should_skip = std.mem.startsWith(u8, line, "#") or std.mem.trim(u8, line, " ").len == 0;

            if (!should_skip) {
                var split_iter = std.mem.split(u8, line, "\t");
                const value = std.mem.trim(u8, split_iter.next().?, " ") ++ "";
                if (split_iter.next()) |k| {
                    const key = std.mem.trim(u8, k, " ") ++ "";
                    node.add(key, value);
                } else {
                    @compileError(std.fmt.comptimePrint("Unable to find key in the line: {s}\n", .{line}));
                }
            }
        }
    }

    node.calculateCount();

    break :blk node;
};
