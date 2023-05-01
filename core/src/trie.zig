const std = @import("std");

const testing = std.testing;

pub const WIDTH = 27;

pub fn alphabetToNumber(letter: u8) ?u8 {
    return switch (letter) {
        'a'...'z' => letter - 'a',
        ';' => 26,
        else => null,
    };
}

pub fn numberToAlphabet(number: u8) u8 {
    if (number > 26) {
        unreachable;
    }

    if (number == 26) {
        return ';';
    }

    return number + 'a';
}

test "map alphabet to number" {
    try testing.expectEqual(alphabetToNumber('a'), 0);
    try testing.expectEqual(alphabetToNumber('z'), 25);
    try testing.expectEqual(alphabetToNumber(';'), 26);
    try testing.expectEqual(alphabetToNumber('A'), null);
}

pub const Node = struct {
    const Self = @This();

    values: []const [:0]const u8,
    children: [WIDTH]?*Self,
    count: u32,

    pub fn init() Self {
        return Self{
            .values = ([0][:0]const u8{})[0..],
            .children = [_]?*Self{null} ** WIDTH,
            .count = 0,
        };
    }

    pub fn add(comptime self: *Self, comptime key: []const u8, comptime value: [:0]const u8) void {
        var cursor = self;

        for (key) |letter| {
            const index = alphabetToNumber(letter).?;

            if (cursor.children[index] == null) {
                comptime var child = Self.init();
                cursor.children[index] = &child;
            }

            cursor = cursor.children[index].?;
        }

        const new_values = cursor.values ++ [_][:0]const u8{value};

        cursor.values = new_values[0..];
    }

    pub fn calculateCount(comptime self: *Self) void {
        var count = 0;
        for (self.children) |nullable_child| {
            if (nullable_child) |child| {
                child.calculateCount();
                count += child.count;
            }
        }
        count += self.values.len;
        self.count = count;
    }

    pub fn get_child(self: *const Self, key: u8) ?*const Self {
        if (alphabetToNumber(key)) |index| {
            return self.children[index];
        } else {
            return null;
        }
    }
};

test "add child nodes with single letter key" {
    comptime var root_node = Node.init();

    comptime root_node.add("n", "你");
    comptime root_node.add("i", "上");

    const n = alphabetToNumber('n').?;
    const i = alphabetToNumber('i').?;

    try testing.expectEqualStrings("你", root_node.children[n].?.values[0][0..]);
    try testing.expectEqualStrings("上", root_node.children[i].?.values[0][0..]);
}

test "add child nodes with multiple letter key" {
    comptime var root_node = Node.init();

    comptime root_node.add("nkiuai", "你");
    comptime root_node.add("hzauai", "好");

    const n = alphabetToNumber('n').?;
    const k = alphabetToNumber('k').?;
    const i = alphabetToNumber('i').?;
    const u = alphabetToNumber('u').?;
    const a = alphabetToNumber('a').?;
    const h = alphabetToNumber('h').?;
    const z = alphabetToNumber('z').?;

    try testing.expectEqualSlices(u8, "你", root_node.children[n].?.children[k].?.children[i].?.children[u].?.children[a].?.children[i].?.values[0]);
    try testing.expectEqualSlices(u8, "好", root_node.children[h].?.children[z].?.children[a].?.children[u].?.children[a].?.children[i].?.values[0]);
}

test "add child nodes with multi-letter value" {
    comptime var root_node = Node.init();

    comptime root_node.add("nkhz", "你好");
    comptime root_node.add("ekjd", "世界");

    const n = alphabetToNumber('n').?;
    const k = alphabetToNumber('k').?;
    const h = alphabetToNumber('h').?;
    const z = alphabetToNumber('z').?;
    const e = alphabetToNumber('e').?;
    const j = alphabetToNumber('j').?;
    const d = alphabetToNumber('d').?;

    try testing.expectEqualSlices(u8, "你好", root_node.children[n].?.children[k].?.children[h].?.children[z].?.values[0]);
    try testing.expectEqualSlices(u8, "世界", root_node.children[e].?.children[k].?.children[j].?.children[d].?.values[0]);
}

test "add child nodes with same key" {
    comptime var root_node = Node.init();

    comptime root_node.add("i", "上");
    comptime root_node.add("i", "打");
    comptime root_node.add("i", "龵");

    const i = alphabetToNumber('i').?;

    try testing.expectEqualSlices(u8, "上", root_node.children[i].?.values[0]);
    try testing.expectEqualSlices(u8, "打", root_node.children[i].?.values[1]);
    try testing.expectEqualSlices(u8, "龵", root_node.children[i].?.values[2]);
}

test "add child nodes with multi-letter value and same key" {
    comptime var root_node = Node.init();

    comptime root_node.add("nkhz", "你好");
    comptime root_node.add("nkhz", "拟好");

    const n = alphabetToNumber('n').?;
    const k = alphabetToNumber('k').?;
    const h = alphabetToNumber('h').?;
    const z = alphabetToNumber('z').?;

    try testing.expectEqualSlices(u8, "你好", root_node.children[n].?.children[k].?.children[h].?.children[z].?.values[0]);
    try testing.expectEqualSlices(u8, "拟好", root_node.children[n].?.children[k].?.children[h].?.children[z].?.values[1]);
}

test "calculate count" {
    comptime var root_node = Node.init();

    comptime root_node.add("nk", "你");
    comptime root_node.add("nkhz", "你好");
    comptime root_node.add("i", "上");

    comptime root_node.calculateCount();

    const n = alphabetToNumber('n').?;
    const k = alphabetToNumber('k').?;
    const h = alphabetToNumber('h').?;
    const z = alphabetToNumber('z').?;
    const i = alphabetToNumber('i').?;

    try testing.expectEqual(root_node.count, 3);
    try testing.expectEqual(root_node.children[n].?.count, 2);
    try testing.expectEqual(root_node.children[n].?.children[k].?.count, 2);
    try testing.expectEqual(root_node.children[n].?.children[k].?.children[h].?.count, 1);
    try testing.expectEqual(root_node.children[n].?.children[k].?.children[h].?.children[z].?.count, 1);
    try testing.expectEqual(root_node.children[i].?.count, 1);
}

test "get child" {
    comptime var root_node = Node.init();
    comptime root_node.add("nk", "你");
    comptime root_node.add("i", "上");
    comptime root_node.calculateCount();

    const node1 = root_node.get_child('n').?.get_child('k').?;
    const node2 = root_node.get_child('i').?;

    try testing.expectEqualSlices(u8, "你", node1.values[0]);
    try testing.expectEqualSlices(u8, "上", node2.values[0]);
}
