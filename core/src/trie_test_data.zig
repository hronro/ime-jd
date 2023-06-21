const Node = @import("./trie.zig").Node;
const NodeInitOptions = @import("./trie.zig").NodeInitOptions;

pub fn generateTestTrie() struct { struct { *Node(.{}), NodeInitOptions }, struct { *Node(.{ .compressed = true }), NodeInitOptions } } {
    var root_node1 = Node(.{}).init();
    var root_node2 = Node(.{ .compressed = true }).init();

    comptime var root_nodes = .{
        .{ &root_node1, NodeInitOptions{} },
        .{ &root_node2, NodeInitOptions{ .compressed = true } },
    };

    inline for (root_nodes) |node| {
        comptime node[0].add("a", "甲");
        comptime node[0].add("ab", "乙");
        comptime node[0].add("ac", "丙1");
        comptime node[0].add("ac", "丙2");
        comptime node[0].add("acd", "丁1");
        comptime node[0].add("acd", "丁2");
        comptime node[0].add("acd", "丁3");
        comptime node[0].add("ace", "丁4");
        comptime node[0].add("ac;", "FooBar");
        comptime node[0].add("ae", "Foo");
        comptime node[0].add("af", "Bar");

        comptime node[0].calculateCount();
    }

    return root_nodes;
}
