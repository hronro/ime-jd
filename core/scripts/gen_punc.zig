//! Build-time punctuation-marks blob generator.
//!
//! Usage (driven by build.zig, not run by hand):
//!   gen_punc <out_dir> <eol> <target_endian> <normal.txt> <paired.txt>
//!
//! `target_endian` is "le" or "be" — gen_punc runs on the host, so when the
//! target's endianness differs from the host's, `punc.buildBlob` byte-swaps
//! every multi-byte field before writing the blob to disk.
//!
//! File formats (tab-separated, '#' comments, blank lines ignored):
//!
//!   normal.txt: <key>\t<value>[\t<value>...]
//!     One line per key. Multiple values on the same line become a
//!     candidate window in source order.
//!
//!   paired.txt: <key>\t<open>\t<close>
//!     Exactly three fields. <open> is emitted on the first press of
//!     <key>, <close> on the second, alternating.
//!
//! Writes:
//!   <out_dir>/punc.bin              — the on-disk format (see punc_format.zig)
//!   <out_dir>/punc_blob_module.zig  — a tiny wrapper that exposes
//!                                     `pub const bytes = @embedFile("punc.bin");`

const std = @import("std");
const testing = std.testing;
const punc = @import("punc");

const ReservedKey = struct {
    key: u8,
    why: []const u8,
};

const RESERVED_KEYS = [_]ReservedKey{
    .{ .key = ' ', .why = "reserved by pressKey Case A (space commits first option)" },
    .{ .key = ';', .why = "reserved by pressKey Case B (';' commits second option)" },
    .{ .key = '1', .why = "reserved as IME-side candidate-selector key (see docs/integration.md)" },
    .{ .key = '2', .why = "reserved as IME-side candidate-selector key (see docs/integration.md)" },
    .{ .key = '3', .why = "reserved as IME-side candidate-selector key (see docs/integration.md)" },
    .{ .key = '4', .why = "reserved as IME-side candidate-selector key (see docs/integration.md)" },
    .{ .key = '5', .why = "reserved as IME-side candidate-selector key (see docs/integration.md)" },
    .{ .key = '6', .why = "reserved as IME-side candidate-selector key (see docs/integration.md)" },
    .{ .key = '7', .why = "reserved as IME-side candidate-selector key (see docs/integration.md)" },
    .{ .key = '8', .why = "reserved as IME-side candidate-selector key (see docs/integration.md)" },
    .{ .key = '9', .why = "reserved as IME-side candidate-selector key (see docs/integration.md)" },
};

fn isReservedKey(key: u8) ?[]const u8 {
    for (RESERVED_KEYS) |r| if (r.key == key) return r.why;
    return null;
}

fn parseKeyField(field: []const u8, path: []const u8, line: []const u8) !u8 {
    if (field.len != 1) {
        std.debug.print("error: punc key must be exactly one ASCII byte, got {d} bytes in {s}: {s}\n", .{ field.len, path, line });
        return error.MalformedPuncKey;
    }
    const k = field[0];
    if (k >= 128) {
        std.debug.print("error: punc key must be ASCII (< 128), got byte 0x{x} in {s}: {s}\n", .{ k, path, line });
        return error.NonAsciiPuncKey;
    }
    if (isReservedKey(k)) |why| {
        std.debug.print("error: punc key '{c}' (0x{x}) is reserved — {s} (in {s})\n", .{ k, k, why, path });
        return error.ReservedPuncKey;
    }
    return k;
}

/// Parses lines `<key>\t<value>[\t<value>...]` from `data`, appending one
/// `NormalInput` per line. Within the file, each key may appear at most
/// once (duplicates are a build-time error).
fn parseNormal(
    arena: std.mem.Allocator,
    out: *std.ArrayList(punc.NormalInput),
    data: []const u8,
    eol: []const u8,
    path: []const u8,
) !void {
    var seen: [256]bool = @splat(false);

    var it = std.mem.splitSequence(u8, data, eol);
    while (it.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, trimmed, '\t');
        const key_field = std.mem.trim(u8, fields.first(), " ");
        if (key_field.len == 0) {
            std.debug.print("error: missing key in {s}: {s}\n", .{ path, trimmed });
            return error.MalformedNormalLine;
        }

        const key = try parseKeyField(key_field, path, trimmed);

        if (seen[key]) {
            std.debug.print("error: duplicate key '{c}' (0x{x}) in {s}\n", .{ key, key, path });
            return error.DuplicateNormalKey;
        }
        seen[key] = true;

        var candidates: std.ArrayList([]const u8) = .empty;
        while (fields.next()) |value_raw| {
            const value = std.mem.trim(u8, value_raw, " ");
            if (value.len == 0) continue;
            const value_copy = try arena.dupe(u8, value);
            try candidates.append(arena, value_copy);
        }
        if (candidates.items.len == 0) {
            std.debug.print("error: no values for key in {s}: {s}\n", .{ path, trimmed });
            return error.MalformedNormalLine;
        }

        try out.append(arena, .{
            .key = key,
            .candidates = try candidates.toOwnedSlice(arena),
        });
    }
}

/// Parses lines `<key>\t<open>\t<close>` from `data`. Exactly three
/// tab-separated fields are required. Within the file, each key may
/// appear at most once.
fn parsePaired(
    arena: std.mem.Allocator,
    out: *std.ArrayList(punc.PairedInput),
    data: []const u8,
    eol: []const u8,
    path: []const u8,
) !void {
    var seen: [256]bool = @splat(false);

    var it = std.mem.splitSequence(u8, data, eol);
    while (it.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var fields = std.mem.splitScalar(u8, trimmed, '\t');
        const key_field = fields.first();
        const open_field = fields.next() orelse {
            std.debug.print("error: paired line needs <key>\\t<open>\\t<close> in {s}: {s}\n", .{ path, trimmed });
            return error.MalformedPairedLine;
        };
        const close_field = fields.next() orelse {
            std.debug.print("error: paired line needs <key>\\t<open>\\t<close> in {s}: {s}\n", .{ path, trimmed });
            return error.MalformedPairedLine;
        };
        if (fields.next() != null) {
            std.debug.print("error: paired line has too many fields in {s}: {s}\n", .{ path, trimmed });
            return error.MalformedPairedLine;
        }

        const key_str = std.mem.trim(u8, key_field, " ");
        const open = std.mem.trim(u8, open_field, " ");
        const close = std.mem.trim(u8, close_field, " ");
        if (key_str.len == 0 or open.len == 0 or close.len == 0) {
            std.debug.print("error: empty field in paired line in {s}: {s}\n", .{ path, trimmed });
            return error.MalformedPairedLine;
        }

        const key = try parseKeyField(key_str, path, trimmed);

        if (seen[key]) {
            std.debug.print("error: duplicate key '{c}' (0x{x}) in {s}\n", .{ key, key, path });
            return error.DuplicatePairedKey;
        }
        seen[key] = true;

        try out.append(arena, .{
            .key = key,
            .open = try arena.dupe(u8, open),
            .close = try arena.dupe(u8, close),
        });
    }
}

/// Build-time conflict assertion: no key may appear in both `normal.txt`
/// and `paired.txt`. (Within a single file, duplicates are already rejected
/// by `parseNormal` / `parsePaired`.)
fn assertNoCrossFileConflicts(
    normals: []const punc.NormalInput,
    paireds: []const punc.PairedInput,
) !void {
    var seen_paired: [256]bool = @splat(false);
    for (paireds) |p| seen_paired[p.key] = true;
    for (normals) |n| {
        if (seen_paired[n.key]) {
            std.debug.print(
                "error: punc key '{c}' (0x{x}) appears in both normal.txt and paired.txt — choose one\n",
                .{ n.key, n.key },
            );
            return error.PuncKeyInBothFiles;
        }
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa.allocator(), .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    const raw_args = try init.args.toSlice(arena);
    if (raw_args.len != 6) {
        std.debug.print("usage: gen_punc <out_dir> <eol> <target_endian> <normal.txt> <paired.txt>\n", .{});
        return error.MissingArgs;
    }
    const out_dir_path = raw_args[1];
    const eol_arg = raw_args[2];
    const endian_arg = raw_args[3];
    const normal_path = raw_args[4];
    const paired_path = raw_args[5];

    const eol: []const u8 = if (std.mem.eql(u8, eol_arg, "lf"))
        "\n"
    else if (std.mem.eql(u8, eol_arg, "crlf"))
        "\r\n"
    else
        eol_arg;

    const target_endian: std.builtin.Endian = blk: {
        if (std.mem.eql(u8, endian_arg, "le")) break :blk .little;
        if (std.mem.eql(u8, endian_arg, "be")) break :blk .big;
        std.debug.print("error: unknown target endianness {s} (expected \"le\" or \"be\")\n", .{endian_arg});
        return error.BadEndianArg;
    };

    const cwd = std.Io.Dir.cwd();

    var normals: std.ArrayList(punc.NormalInput) = .empty;
    var paireds: std.ArrayList(punc.PairedInput) = .empty;
    {
        const data = try cwd.readFileAlloc(io, normal_path, arena, .limited(1 << 30));
        try parseNormal(arena, &normals, data, eol, normal_path);
    }
    {
        const data = try cwd.readFileAlloc(io, paired_path, arena, .limited(1 << 30));
        try parsePaired(arena, &paireds, data, eol, paired_path);
    }

    try assertNoCrossFileConflicts(normals.items, paireds.items);

    const blob = try punc.buildBlob(arena, normals.items, paireds.items, target_endian);

    var out_dir = try cwd.createDirPathOpen(io, out_dir_path, .{});
    defer out_dir.close(io);

    try out_dir.writeFile(io, .{ .sub_path = "punc.bin", .data = blob });
    try out_dir.writeFile(io, .{
        .sub_path = "punc_blob_module.zig",
        .data =
        \\//! Auto-generated by scripts/gen_punc.zig — do not edit.
        \\pub const bytes align(4) = @embedFile("punc.bin").*;
        \\
        ,
    });

    std.debug.print(
        "gen_punc: {d} normal + {d} paired → {d} bytes blob\n",
        .{ normals.items.len, paireds.items.len, blob.len },
    );
}

// =========================================================================
// Tests
// =========================================================================

const NormalFixture = struct {
    arena_state: std.heap.ArenaAllocator,
    out: std.ArrayList(punc.NormalInput),

    fn init() NormalFixture {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .out = .empty,
        };
    }

    fn deinit(self: *NormalFixture) void {
        self.arena_state.deinit();
    }

    fn arena(self: *NormalFixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

const PairedFixture = struct {
    arena_state: std.heap.ArenaAllocator,
    out: std.ArrayList(punc.PairedInput),

    fn init() PairedFixture {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
            .out = .empty,
        };
    }

    fn deinit(self: *PairedFixture) void {
        self.arena_state.deinit();
    }

    fn arena(self: *PairedFixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

// ---- parseKeyField ----

test "parseKeyField: valid 1-byte ASCII returns the byte" {
    try testing.expectEqual(@as(u8, 'a'), try parseKeyField("a", "t.txt", "line"));
    try testing.expectEqual(@as(u8, '.'), try parseKeyField(".", "t.txt", "line"));
    try testing.expectEqual(@as(u8, '['), try parseKeyField("[", "t.txt", "line"));
}

test "parseKeyField: multi-byte field rejected" {
    try testing.expectError(error.MalformedPuncKey, parseKeyField("ab", "t.txt", "line"));
    try testing.expectError(error.MalformedPuncKey, parseKeyField("。", "t.txt", "line"));
}

test "parseKeyField: empty field rejected" {
    try testing.expectError(error.MalformedPuncKey, parseKeyField("", "t.txt", "line"));
}

test "parseKeyField: non-ASCII single byte rejected" {
    const high: [1]u8 = .{0x80};
    try testing.expectError(error.NonAsciiPuncKey, parseKeyField(&high, "t.txt", "line"));
}

test "parseKeyField: reserved keys rejected" {
    try testing.expectError(error.ReservedPuncKey, parseKeyField(" ", "t.txt", "line"));
    try testing.expectError(error.ReservedPuncKey, parseKeyField(";", "t.txt", "line"));
    try testing.expectError(error.ReservedPuncKey, parseKeyField("1", "t.txt", "line"));
    try testing.expectError(error.ReservedPuncKey, parseKeyField("5", "t.txt", "line"));
    try testing.expectError(error.ReservedPuncKey, parseKeyField("9", "t.txt", "line"));
}

// ---- parseNormal ----

test "parseNormal: single-candidate line" {
    var f = NormalFixture.init();
    defer f.deinit();

    try parseNormal(f.arena(), &f.out, ".\t。\n,\t，\n", "\n", "normal.txt");
    try testing.expectEqual(@as(usize, 2), f.out.items.len);
    try testing.expectEqual(@as(u8, '.'), f.out.items[0].key);
    try testing.expectEqual(@as(usize, 1), f.out.items[0].candidates.len);
    try testing.expectEqualStrings("。", f.out.items[0].candidates[0]);
    try testing.expectEqual(@as(u8, ','), f.out.items[1].key);
    try testing.expectEqualStrings("，", f.out.items[1].candidates[0]);
}

test "parseNormal: multi-candidate line preserves order" {
    var f = NormalFixture.init();
    defer f.deinit();

    try parseNormal(f.arena(), &f.out, "[\t「\t【\t〔\t［\n", "\n", "normal.txt");
    try testing.expectEqual(@as(usize, 1), f.out.items.len);
    try testing.expectEqual(@as(u8, '['), f.out.items[0].key);
    try testing.expectEqual(@as(usize, 4), f.out.items[0].candidates.len);
    try testing.expectEqualStrings("「", f.out.items[0].candidates[0]);
    try testing.expectEqualStrings("【", f.out.items[0].candidates[1]);
    try testing.expectEqualStrings("〔", f.out.items[0].candidates[2]);
    try testing.expectEqualStrings("［", f.out.items[0].candidates[3]);
}

test "parseNormal: skips comments and blank lines" {
    var f = NormalFixture.init();
    defer f.deinit();

    try parseNormal(
        f.arena(),
        &f.out,
        "# header\n" ++
            "\n" ++
            ".\t。\n" ++
            "# mid\n" ++
            ",\t，\n",
        "\n",
        "normal.txt",
    );
    try testing.expectEqual(@as(usize, 2), f.out.items.len);
}

test "parseNormal: missing key is an error" {
    var f = NormalFixture.init();
    defer f.deinit();

    try testing.expectError(error.MalformedNormalLine, parseNormal(f.arena(), &f.out, "\t。\n", "\n", "normal.txt"));
}

test "parseNormal: key with no values is an error" {
    var f = NormalFixture.init();
    defer f.deinit();

    try testing.expectError(error.MalformedNormalLine, parseNormal(f.arena(), &f.out, ".\n", "\n", "normal.txt"));
}

test "parseNormal: all-empty value fields is an error" {
    var f = NormalFixture.init();
    defer f.deinit();

    try testing.expectError(error.MalformedNormalLine, parseNormal(f.arena(), &f.out, ".\t\t  \t\n", "\n", "normal.txt"));
}

test "parseNormal: empty middle field is dropped silently" {
    var f = NormalFixture.init();
    defer f.deinit();

    try parseNormal(f.arena(), &f.out, "[\t「\t\t【\n", "\n", "normal.txt");
    try testing.expectEqual(@as(usize, 1), f.out.items.len);
    try testing.expectEqual(@as(usize, 2), f.out.items[0].candidates.len);
    try testing.expectEqualStrings("「", f.out.items[0].candidates[0]);
    try testing.expectEqualStrings("【", f.out.items[0].candidates[1]);
}

test "parseNormal: reserved key rejected" {
    var f = NormalFixture.init();
    defer f.deinit();

    try testing.expectError(error.ReservedPuncKey, parseNormal(f.arena(), &f.out, ";\t；\n", "\n", "normal.txt"));
}

test "parseNormal: multi-byte key rejected" {
    var f = NormalFixture.init();
    defer f.deinit();

    try testing.expectError(error.MalformedPuncKey, parseNormal(f.arena(), &f.out, "ab\tvalue\n", "\n", "normal.txt"));
}

test "parseNormal: duplicate key within file is an error" {
    var f = NormalFixture.init();
    defer f.deinit();

    try testing.expectError(error.DuplicateNormalKey, parseNormal(f.arena(), &f.out, ".\t。\n.\t、\n", "\n", "normal.txt"));
}

test "parseNormal: CRLF line endings" {
    var f = NormalFixture.init();
    defer f.deinit();

    try parseNormal(f.arena(), &f.out, ".\t。\r\n,\t，\r\n", "\r\n", "normal.txt");
    try testing.expectEqual(@as(usize, 2), f.out.items.len);
}

// ---- parsePaired ----

test "parsePaired: valid line" {
    var f = PairedFixture.init();
    defer f.deinit();

    try parsePaired(f.arena(), &f.out, "\"\t“\t”\n", "\n", "paired.txt");
    try testing.expectEqual(@as(usize, 1), f.out.items.len);
    try testing.expectEqual(@as(u8, '"'), f.out.items[0].key);
    try testing.expectEqualStrings("“", f.out.items[0].open);
    try testing.expectEqualStrings("”", f.out.items[0].close);
}

test "parsePaired: too few fields is an error" {
    var f = PairedFixture.init();
    defer f.deinit();

    try testing.expectError(error.MalformedPairedLine, parsePaired(f.arena(), &f.out, "\"\t“\n", "\n", "paired.txt"));
}

test "parsePaired: too many fields is an error" {
    var f = PairedFixture.init();
    defer f.deinit();

    try testing.expectError(error.MalformedPairedLine, parsePaired(f.arena(), &f.out, "\"\t“\t”\textra\n", "\n", "paired.txt"));
}

test "parsePaired: empty field is an error" {
    var f = PairedFixture.init();
    defer f.deinit();

    try testing.expectError(error.MalformedPairedLine, parsePaired(f.arena(), &f.out, "\"\t\t”\n", "\n", "paired.txt"));
    try testing.expectError(error.MalformedPairedLine, parsePaired(f.arena(), &f.out, "\"\t“\t\n", "\n", "paired.txt"));
    try testing.expectError(error.MalformedPairedLine, parsePaired(f.arena(), &f.out, "\t“\t”\n", "\n", "paired.txt"));
}

test "parsePaired: reserved key rejected" {
    var f = PairedFixture.init();
    defer f.deinit();

    try testing.expectError(error.ReservedPuncKey, parsePaired(f.arena(), &f.out, ";\to\tc\n", "\n", "paired.txt"));
}

test "parsePaired: duplicate key within file is an error" {
    var f = PairedFixture.init();
    defer f.deinit();

    try testing.expectError(error.DuplicatePairedKey, parsePaired(f.arena(), &f.out, "\"\t“\t”\n\"\t‹\t›\n", "\n", "paired.txt"));
}

test "parsePaired: skips comments and blank lines" {
    var f = PairedFixture.init();
    defer f.deinit();

    try parsePaired(
        f.arena(),
        &f.out,
        "# header\n" ++
            "\n" ++
            "\"\t“\t”\n" ++
            "\n" ++
            "'\t‘\t’\n",
        "\n",
        "paired.txt",
    );
    try testing.expectEqual(@as(usize, 2), f.out.items.len);
}

// ---- assertNoCrossFileConflicts ----

test "assertNoCrossFileConflicts: key in only one file passes" {
    var nf = NormalFixture.init();
    defer nf.deinit();
    var pf = PairedFixture.init();
    defer pf.deinit();

    try parseNormal(nf.arena(), &nf.out, ".\t。\n", "\n", "normal.txt");
    try parsePaired(pf.arena(), &pf.out, "\"\t“\t”\n", "\n", "paired.txt");
    try assertNoCrossFileConflicts(nf.out.items, pf.out.items);
}

test "assertNoCrossFileConflicts: same key in both files is an error" {
    var nf = NormalFixture.init();
    defer nf.deinit();
    var pf = PairedFixture.init();
    defer pf.deinit();

    try parseNormal(nf.arena(), &nf.out, "x\tnormal-x\n", "\n", "normal.txt");
    try parsePaired(pf.arena(), &pf.out, "x\to\tc\n", "\n", "paired.txt");
    try testing.expectError(error.PuncKeyInBothFiles, assertNoCrossFileConflicts(nf.out.items, pf.out.items));
}
