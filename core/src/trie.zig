const std = @import("std");

const testing = std.testing;
const ArrayList = std.ArrayList;

pub const NodeInitOptions = struct {
    compressed: bool = false,
};

pub fn Node(comptime options: NodeInitOptions) type {
    if (options.compressed) {
        return struct {
            const Self = @This();

            values: []const [:0]const u8,
            count: u32,

            _width: u8,
            _child_keys: [*]const u8,
            _children: [*]const *Self,

            pub fn init() Self {
                return Self{
                    .values = &.{},
                    .count = 0,
                    ._width = 0,
                    ._child_keys = "",
                    ._children = &[0]*Self{},
                };
            }

            pub fn add(comptime self: *Self, comptime keys: []const u8, comptime value: [:0]const u8) void {
                var cursor = self;

                iter_cursor: for (keys) |key| {
                    const insert_key_index = get_key_index: {
                        for (0..cursor._width) |i| {
                            const child_key = cursor._child_keys[i];

                            if (child_key == key) {
                                cursor = cursor._children[i];
                                continue :iter_cursor;
                            }

                            if (key < child_key and key >= 'a' and key <= 'z') {
                                break :get_key_index i;
                            }
                        }
                        break :get_key_index cursor._width;
                    };

                    if (insert_key_index == cursor._width) {
                        cursor._child_keys = cursor._child_keys ++ [_]u8{key};
                        comptime var child = Self.init();
                        cursor._children = cursor._children ++ &[_]*Self{&child};
                        cursor._width += 1;
                    } else {
                        cursor._child_keys = cursor._child_keys[0..insert_key_index] ++ [_]u8{key} ++ cursor._child_keys[insert_key_index..cursor._width];

                        comptime var child = Self.init();
                        // TODO: use array concatenation when the compiler issue is solved:
                        // https://github.com/ziglang/zig/issues/16000
                        // cursor.children = cursor.children[0..insert_key_index] ++ &[_]*Self{&child} ++ cursor.children[insert_key_index..];
                        var new_children: [cursor._width + 1]*Self = undefined;
                        @memcpy(new_children[0..insert_key_index], cursor._children[0..insert_key_index]);
                        new_children[insert_key_index] = &child;
                        @memcpy(new_children[insert_key_index + 1 ..], cursor._children[insert_key_index..cursor._width]);
                        cursor._children = &new_children;
                        cursor._width += 1;
                    }

                    cursor = cursor._children[insert_key_index];
                }

                const new_values = cursor.values ++ [_][:0]const u8{value};

                cursor.values = new_values[0..];
            }

            pub fn calculateCount(comptime self: *Self) void {
                var count = 0;
                for (0..self._width) |i| {
                    const child = self._children[i];
                    child.calculateCount();
                    count += child.count;
                }
                count += self.values.len;
                self.count = count;
            }

            pub fn getChild(self: *const Self, key: u8) ?*const Self {
                if (self.indexOfChild(key)) |index| {
                    return self._children[index];
                } else {
                    return null;
                }
            }

            pub fn getChildByIndex(self: *const Self, index: usize) ?*const Self {
                if (index >= self._width) {
                    return null;
                }

                return self._children[index];
            }

            pub fn indexOfChild(self: *const Self, key: u8) ?usize {
                for (0..self._width) |i| {
                    const child_key = self._child_keys[i];
                    if (child_key == key) {
                        return i;
                    }
                }

                return null;
            }

            pub fn keyOfChildByIndex(self: *const Self, index: usize) ?u8 {
                if (index >= self._width) {
                    return null;
                }

                return self._child_keys[index];
            }

            pub fn getWidth(self: *const Self) u8 {
                return self._width;
            }
        };
    } else {
        const WIDTH = 27;

        return struct {
            const Self = @This();

            values: []const [:0]const u8,
            count: u32,

            _children: [WIDTH]?*Self,

            pub fn init() Self {
                return Self{
                    .values = &.{},
                    .count = 0,
                    ._children = [_]?*Self{null} ** WIDTH,
                };
            }

            pub fn add(comptime self: *Self, comptime keys: []const u8, comptime value: [:0]const u8) void {
                var cursor = self;

                for (keys) |key| {
                    const index = self.indexOfChild(key).?;

                    if (cursor._children[index] == null) {
                        comptime var child = Self.init();
                        cursor._children[index] = &child;
                    }

                    cursor = cursor._children[index].?;
                }

                const new_values = cursor.values ++ [_][:0]const u8{value};

                cursor.values = new_values[0..];
            }

            pub fn calculateCount(comptime self: *Self) void {
                var count = 0;
                for (self._children) |nullable_child| {
                    if (nullable_child) |child| {
                        child.calculateCount();
                        count += child.count;
                    }
                }
                count += self.values.len;
                self.count = count;
            }

            pub fn getChild(self: *const Self, key: u8) ?*const Self {
                if (self.indexOfChild(key)) |index| {
                    return self._children[index];
                } else {
                    return null;
                }
            }

            pub fn getChildByIndex(self: *const Self, index: usize) ?*const Self {
                if (index >= self._children.len) {
                    return null;
                }

                return self._children[index];
            }

            pub fn indexOfChild(self: *const Self, key: u8) ?usize {
                _ = self;
                return switch (key) {
                    'a'...'z' => @intCast(key - 'a'),
                    ';' => 26,
                    else => null,
                };
            }

            pub fn keyOfChildByIndex(self: *const Self, index: usize) ?u8 {
                _ = self;
                return switch (index) {
                    0...25 => @as(u8, @intCast(index)) + 'a',
                    26 => ';',
                    else => null,
                };
            }

            pub fn getWidth(self: *const Self) u8 {
                _ = self;
                return WIDTH;
            }
        };
    }
}

test "add child nodes with single letter key" {
    comptime var root_node = Node(.{}).init();

    comptime root_node.add("n", "你");
    comptime root_node.add("i", "上");

    try testing.expectEqualStrings("你", root_node.getChild('n').?.values[0][0..]);
    try testing.expectEqualStrings("上", root_node.getChild('i').?.values[0][0..]);
}

test "add child nodes with single letter key in compressed trie" {
    comptime var root_node = Node(.{ .compressed = true }).init();

    comptime root_node.add("n", "你");

    comptime root_node.add("i", "上");

    try testing.expectEqualStrings("你", root_node.getChild('n').?.values[0][0..]);
    try testing.expectEqualStrings("上", root_node.getChild('i').?.values[0][0..]);
}

test "add child nodes with multiple letter key" {
    comptime var root_node = Node(.{}).init();

    comptime root_node.add("nkiuai", "你");
    comptime root_node.add("hzauai", "好");

    try testing.expectEqualSlices(u8, "你", root_node.getChild('n').?.getChild('k').?.getChild('i').?.getChild('u').?.getChild('a').?.getChild('i').?.values[0]);
    try testing.expectEqualSlices(u8, "好", root_node.getChild('h').?.getChild('z').?.getChild('a').?.getChild('u').?.getChild('a').?.getChild('i').?.values[0]);
}

test "add child nodes with multiple letter key in compressed trie" {
    comptime var root_node = Node(.{ .compressed = true }).init();

    comptime root_node.add("nkiuai", "你");
    comptime root_node.add("hzauai", "好");

    try testing.expectEqualSlices(u8, "你", root_node.getChild('n').?.getChild('k').?.getChild('i').?.getChild('u').?.getChild('a').?.getChild('i').?.values[0]);
    try testing.expectEqualSlices(u8, "好", root_node.getChild('h').?.getChild('z').?.getChild('a').?.getChild('u').?.getChild('a').?.getChild('i').?.values[0]);
}

test "add child nodes with multi-letter value" {
    comptime var root_node = Node(.{}).init();

    comptime root_node.add("nkhz", "你好");
    comptime root_node.add("ekjd", "世界");

    try testing.expectEqualSlices(u8, "你好", root_node.getChild('n').?.getChild('k').?.getChild('h').?.getChild('z').?.values[0]);
    try testing.expectEqualSlices(u8, "世界", root_node.getChild('e').?.getChild('k').?.getChild('j').?.getChild('d').?.values[0]);
}

test "add child nodes with multi-letter value in compressed trie" {
    comptime var root_node = Node(.{ .compressed = true }).init();

    comptime root_node.add("nkhz", "你好");
    comptime root_node.add("ekjd", "世界");

    try testing.expectEqualSlices(u8, "你好", root_node.getChild('n').?.getChild('k').?.getChild('h').?.getChild('z').?.values[0]);
    try testing.expectEqualSlices(u8, "世界", root_node.getChild('e').?.getChild('k').?.getChild('j').?.getChild('d').?.values[0]);
}

test "add child nodes with same key" {
    comptime var root_node = Node(.{}).init();

    comptime root_node.add("i", "上");
    comptime root_node.add("i", "打");
    comptime root_node.add("i", "龵");

    try testing.expectEqualSlices(u8, "上", root_node.getChild('i').?.values[0]);
    try testing.expectEqualSlices(u8, "打", root_node.getChild('i').?.values[1]);
    try testing.expectEqualSlices(u8, "龵", root_node.getChild('i').?.values[2]);
}

test "add child nodes with same key in compressed trie" {
    comptime var root_node = Node(.{ .compressed = true }).init();

    comptime root_node.add("i", "上");
    comptime root_node.add("i", "打");
    comptime root_node.add("i", "龵");

    try testing.expectEqualSlices(u8, "上", root_node.getChild('i').?.values[0]);
    try testing.expectEqualSlices(u8, "打", root_node.getChild('i').?.values[1]);
    try testing.expectEqualSlices(u8, "龵", root_node.getChild('i').?.values[2]);
}

test "add child nodes with multi-letter value and same key" {
    comptime var root_node = Node(.{}).init();

    comptime root_node.add("nkhz", "你好");
    comptime root_node.add("nkhz", "拟好");

    try testing.expectEqualSlices(u8, "你好", root_node.getChild('n').?.getChild('k').?.getChild('h').?.getChild('z').?.values[0]);
    try testing.expectEqualSlices(u8, "拟好", root_node.getChild('n').?.getChild('k').?.getChild('h').?.getChild('z').?.values[1]);
}

test "add child nodes with multi-letter value and same key in compressed trie" {
    comptime var root_node = Node(.{ .compressed = true }).init();

    comptime root_node.add("nkhz", "你好");
    comptime root_node.add("nkhz", "拟好");

    try testing.expectEqualSlices(u8, "你好", root_node.getChild('n').?.getChild('k').?.getChild('h').?.getChild('z').?.values[0]);
    try testing.expectEqualSlices(u8, "拟好", root_node.getChild('n').?.getChild('k').?.getChild('h').?.getChild('z').?.values[1]);
}

test "calculate count" {
    comptime var root_node = Node(.{}).init();

    comptime root_node.add("nk", "你");
    comptime root_node.add("nkhz", "你好");
    comptime root_node.add("i", "上");

    comptime root_node.calculateCount();

    try testing.expectEqual(root_node.count, 3);
    try testing.expectEqual(root_node.getChild('n').?.count, 2);
    try testing.expectEqual(root_node.getChild('n').?.getChild('k').?.count, 2);
    try testing.expectEqual(root_node.getChild('n').?.getChild('k').?.getChild('h').?.count, 1);
    try testing.expectEqual(root_node.getChild('n').?.getChild('k').?.getChild('h').?.getChild('z').?.count, 1);
    try testing.expectEqual(root_node.getChild('i').?.count, 1);
}

test "calculate count in compressed trie" {
    comptime var root_node = Node(.{ .compressed = true }).init();

    comptime root_node.add("nk", "你");
    comptime root_node.add("nkhz", "你好");
    comptime root_node.add("i", "上");

    comptime root_node.calculateCount();

    try testing.expectEqual(root_node.count, 3);
    try testing.expectEqual(root_node.getChild('n').?.count, 2);
    try testing.expectEqual(root_node.getChild('n').?.getChild('k').?.count, 2);
    try testing.expectEqual(root_node.getChild('n').?.getChild('k').?.getChild('h').?.count, 1);
    try testing.expectEqual(root_node.getChild('n').?.getChild('k').?.getChild('h').?.getChild('z').?.count, 1);
    try testing.expectEqual(root_node.getChild('i').?.count, 1);
}

test "keys should be ordered in compressed trie" {
    comptime var root_node = Node(.{ .compressed = true }).init();

    comptime root_node.add("abc", "1");
    comptime root_node.add("abd", "2");
    comptime root_node.add("aba", "3");
    comptime root_node.add("abb", "4");

    try testing.expectEqual(@as(u8, 4), root_node.getChild('a').?.getChild('b').?._width);
    try testing.expectEqualSlices(u8, &[_]u8{ 'a', 'b', 'c', 'd' }, root_node.getChild('a').?.getChild('b').?._child_keys[0..4]);
}
