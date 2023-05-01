const testing = @import("std").testing;

test "jd" {
    testing.refAllDecls(@import("./trie.zig"));
    testing.refAllDecls(@import("./pagination.zig"));
    testing.refAllDecls(@import("./query.zig"));
}
