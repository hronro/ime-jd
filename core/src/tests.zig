const testing = @import("std").testing;

test "jd" {
    // `trie.zig` has its own test artifact in build.zig (its tests can't be
    // collected via a named-module `refAllDecls` — Zig only runs test blocks
    // reachable through relative-path `@import` from a test root). The other
    // three modules are pulled in by relative path here, so their tests run.
    testing.refAllDecls(@import("./pagination.zig"));
    testing.refAllDecls(@import("./punc.zig"));
    testing.refAllDecls(@import("./query.zig"));
}
