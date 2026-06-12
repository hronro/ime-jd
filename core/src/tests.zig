const testing = @import("std").testing;

test "jd" {
    // Reference the named `trie` module (not `./trie.zig`) so the same file
    // doesn't get pulled into two modules.
    testing.refAllDecls(@import("trie"));
    testing.refAllDecls(@import("./pagination.zig"));
    testing.refAllDecls(@import("./query.zig"));
}
