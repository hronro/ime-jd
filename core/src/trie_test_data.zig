const Node = @import("./trie.zig").Node;

pub fn generateTestTrie() Node {
    comptime var root_node = Node.init();

    comptime root_node.add("a", "甲");
    comptime root_node.add("ab", "乙");
    comptime root_node.add("ac", "丙1");
    comptime root_node.add("ac", "丙2");
    comptime root_node.add("acd", "丁1");
    comptime root_node.add("acd", "丁2");
    comptime root_node.add("acd", "丁3");
    comptime root_node.add("ace", "丁4");
    comptime root_node.add("ac;", "FooBar");
    comptime root_node.add("ae", "Foo");
    comptime root_node.add("af", "Bar");

    comptime root_node.calculateCount();

    return root_node;
}
