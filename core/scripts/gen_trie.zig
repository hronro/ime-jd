//! Build-time generator of the embedded dictionary.
//!
//! Usage (driven by build.zig, not run by hand):
//!   gen_trie <out_dir> <target_endian> <table.txt> [<table.txt> ...]
//!
//! Joins the table files (lines of "<value>\t<keys>" with '#' comments)
//! into one text and builds it with `dict.build` — the builder a host uses
//! at runtime, with the same line rules — so the embedded dictionary is
//! exactly what a host would get from the same text. Unlike a host's build,
//! this one is strict: a line the builder would skip or drop fails the
//! build, naming the file and line.
//!
//! `target_endian` is "le" or "be" — gen_trie runs on the host, so when the
//! target's endianness differs from the host's, every u32 field is
//! byte-swapped before the blob is written.
//!
//! Writes:
//!
//!   <out_dir>/trie.bin              — the blob (see src/blob_format.zig)
//!   <out_dir>/trie_blob_module.zig  — a tiny wrapper that exposes
//!                                     `pub const bytes = @embedFile("trie.bin");`
//!
//! The wrapper sits next to trie.bin so `@embedFile` resolves correctly when
//! the consumer module imports it.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
// `trie` is wired in by build.zig as a named module so this script doesn't
// need to reach across the package boundary into ../src/.
const trie = @import("trie");
const dict = trie.dict;

/// The table files joined into one text, and where each one starts in it,
/// so a line of the text can be traced back to its file.
const Joined = struct {
    text: []const u8,
    /// 1-based line in `text` that each file's first line became.
    first_lines: []const u32,
    paths: []const []const u8,

    /// The file and 1-based line within it of `line` of the text.
    fn locate(self: Joined, line: u32) struct { []const u8, u32 } {
        var i: usize = self.first_lines.len;
        while (i > 1 and self.first_lines[i - 1] > line) i -= 1;
        return .{ self.paths[i - 1], line - self.first_lines[i - 1] + 1 };
    }
};

/// Join `files` — each one's contents, by `paths` — into one text, each
/// ending with a newline so no line runs into the next file.
fn join(arena: std.mem.Allocator, paths: []const []const u8, files: []const []const u8) !Joined {
    var text: std.ArrayList(u8) = .empty;
    const first_lines = try arena.alloc(u32, files.len);
    var line: u32 = 1;
    for (files, first_lines) |data, *first| {
        first.* = line;
        try text.appendSlice(arena, data);
        if (data.len != 0 and data[data.len - 1] != '\n') try text.append(arena, '\n');
        line += @intCast(std.mem.count(u8, data, "\n") + @intFromBool(data.len != 0 and data[data.len - 1] != '\n'));
    }
    return .{ .text = text.items, .first_lines = first_lines, .paths = paths };
}

fn noteReason(flags: u32) []const u8 {
    if (flags & dict.NoteFlag.malformed != 0) return "no TAB between value and keys";
    if (flags & dict.NoteFlag.bad_keys != 0) return "keys must be 1-6 of a-z and ';', with no ';' after a letter";
    if (flags & dict.NoteFlag.bad_value != 0) return "value must be 1-1023 bytes of UTF-8 without control characters";
    if (flags & dict.NoteFlag.repeats_line != 0) return "repeats an earlier line";
    return "unknown problem";
}

/// Write every note to stderr as `path:line: reason`. A dictionary that
/// earns any note fails the build.
fn reportNotes(joined: Joined, notes: []const dict.Note) void {
    for (notes) |n| {
        const path, const line = joined.locate(n.line);
        if (n.flags & dict.NoteFlag.repeats_line != 0) {
            const other_path, const other_line = joined.locate(n.other);
            diag("{s}:{d}: {s} ({s}:{d})\n", .{ path, line, noteReason(n.flags), other_path, other_line });
        } else {
            diag("{s}:{d}: {s}\n", .{ path, line, noteReason(n.flags) });
        }
    }
}

/// Diagnostic print that stays silent under `zig build test`, where
/// `zig build` would render stderr as a (bogus) failed command.
fn diag(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) std.debug.print(fmt, args);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
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
    if (raw_args.len < 4) {
        std.debug.print("usage: gen_trie <out_dir> <target_endian> <table.txt> [<table.txt> ...]\n", .{});
        return error.MissingArgs;
    }
    const out_dir_path = raw_args[1];
    const endian_arg = raw_args[2];
    const table_paths = raw_args[3..];

    const target_endian: std.lang.Endian = blk: {
        if (std.mem.eql(u8, endian_arg, "le")) break :blk .little;
        if (std.mem.eql(u8, endian_arg, "be")) break :blk .big;
        std.debug.print("error: unknown target endianness {s} (expected \"le\" or \"be\")\n", .{endian_arg});
        return error.BadEndianArg;
    };

    const cwd = std.Io.Dir.cwd();
    const files = try arena.alloc([]const u8, table_paths.len);
    for (table_paths, files) |path, *data| {
        data.* = try cwd.readFileAlloc(io, path, arena, .limited(1 << 30));
    }
    const joined = try join(arena, table_paths, files);

    var report: dict.Report = undefined;
    var blob = dict.buildAlloc(gpa.allocator(), joined.text, 0, &report) catch |err| {
        if (err == error.BuildFailed) {
            const path, const line = if (report.line != 0) joined.locate(report.line) else .{ "tables", 0 };
            std.debug.print("{s}:{d}: the dictionary does not build (status {d})\n", .{ path, line, report.status });
        }
        return err;
    };
    defer blob.deinit(gpa.allocator());
    if (blob.report.notes != 0) {
        reportNotes(joined, blob.notes());
        return error.BadTableLines;
    }

    const bytes = blob.buf[0..blob.len];
    // Read the log line's numbers before a cross-endian swap.
    const header = std.mem.bytesToValue(trie.Header, bytes[0..@sizeOf(trie.Header)]);
    if (target_endian != builtin.target.cpu.arch.endian()) {
        dict.byteSwapBlob(bytes, builtin.target.cpu.arch.endian());
    }

    var out_dir = try cwd.createDirPathOpen(io, out_dir_path, .{});
    defer out_dir.close(io);
    try out_dir.writeFile(io, .{ .sub_path = "trie.bin", .data = bytes });
    try out_dir.writeFile(io, .{
        .sub_path = "trie_blob_module.zig",
        .data =
        \\//! Auto-generated by scripts/gen_trie.zig — do not edit.
        \\pub const bytes align(4) = @embedFile("trie.bin").*;
        \\
        ,
    });

    // Surface the worst-case caps the blob embedded. These dictate
    // per-context memory in `jd_init`; logging them gives early visibility
    // into the per-context resident size.
    //
    // Write to stdout (not stderr): zig build's Run step captures stderr when
    // a step has output args, then renders it as a "failed command" even on
    // exit 0. Informational lines belong on stdout.
    const msg = try arena.print(
        "gen_trie: {d} entries → {d} bytes blob (frontier_cap={d}, path_buf_cap={d}, max_value_len={d})\n",
        .{ header.values_count, bytes.len, header.frontier_cap, header.path_buf_cap, header.max_value_len },
    );
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}

// =========================================================================
// Tests
// =========================================================================

test "join keeps every file's lines apart and traceable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = [_][]const u8{ "one.txt", "two.txt", "three.txt", "four.txt" };
    // The second file has no final newline; the third is empty.
    const files = [_][]const u8{ "甲\ta\n# c\n", "乙\tb", "", "丙\tc\r\n丁\td\r\n" };
    const joined = try join(arena, &paths, &files);
    try testing.expectEqualStrings("甲\ta\n# c\n乙\tb\n丙\tc\r\n丁\td\r\n", joined.text);
    const want = [_]struct { u32, []const u8, u32 }{
        .{ 1, "one.txt", 1 },
        .{ 2, "one.txt", 2 },
        .{ 3, "two.txt", 1 },
        .{ 4, "four.txt", 1 },
        .{ 5, "four.txt", 2 },
    };
    for (want) |w| {
        const path, const line = joined.locate(w[0]);
        try testing.expectEqualStrings(w[1], path);
        try testing.expectEqual(w[2], line);
    }
}

test "the joined text builds with no notes, CRLF and all" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = [_][]const u8{ "a.txt", "b.txt" };
    const files = [_][]const u8{ "# header\n\n甲\ta\n：\t;;\n", "  乙  \t  ab  \r\n" };
    const joined = try join(arena, &paths, &files);
    var blob = try dict.buildAlloc(testing.allocator, joined.text, 0, null);
    defer blob.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), blob.report.notes);
    try testing.expectEqual(@as(u32, 3), blob.report.entries);
}

test "a bad line earns a note, traced to its file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const paths = [_][]const u8{ "a.txt", "b.txt" };
    const files = [_][]const u8{ "甲\ta\n", "no tab\n甲\ta\n" };
    const joined = try join(arena, &paths, &files);
    var blob = try dict.buildAlloc(testing.allocator, joined.text, 0, null);
    defer blob.deinit(testing.allocator);
    const notes = blob.notes();
    try testing.expectEqual(@as(usize, 2), notes.len);
    const p0, const l0 = joined.locate(notes[0].line);
    try testing.expectEqualStrings("b.txt", p0);
    try testing.expectEqual(@as(u32, 1), l0);
    try testing.expectEqual(dict.NoteFlag.repeats_line, notes[1].flags);
    const p1, const l1 = joined.locate(notes[1].other);
    try testing.expectEqualStrings("a.txt", p1);
    try testing.expectEqual(@as(u32, 1), l1);
}
