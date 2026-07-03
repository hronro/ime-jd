const testing = @import("std").testing;

test "jd" {
    // `trie.zig` has its own test artifact in build.zig (its tests can't be
    // collected via a named-module `refAllDecls` — Zig only runs test blocks
    // reachable through relative-path `@import` from a test root). The other
    // three modules are pulled in by relative path here, so their tests run.
    testing.refAllDecls(@import("./pagination.zig"));
    testing.refAllDecls(@import("./punc.zig"));
    testing.refAllDecls(@import("./query.zig"));
    // End-to-end tests against the real embedded blobs (production carve
    // path in jd_init). Needs the trie_blob/punc_blob imports that
    // build.zig adds to the test module.
    testing.refAllDecls(@import("./main.zig"));
}
