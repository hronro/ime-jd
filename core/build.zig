const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // EOL of the table .txt files. Normally "\n" on Unix; pass "\r\n" if your
    // checkout has CRLF endings on Windows.
    const tables_eol_option = b.option([]const u8, "tables_eol", "EOL for src/tables/*.txt files (default: lf)") orelse "lf";

    // ---- Shared format module (host + target) ----
    // blob_format.zig defines the on-disk layout. Both the generator (host)
    // and the library (target) compile against it.
    const blob_format_target_mod = b.createModule(.{
        .root_source_file = b.path("src/blob_format.zig"),
        .target = target,
    });
    const blob_format_host_mod = b.createModule(.{
        .root_source_file = b.path("src/blob_format.zig"),
        .target = b.graph.host,
    });

    // ---- Trie module (target side, embedded in the lib) ----
    // Has to be its own module so the host-side gen_trie can also import it,
    // using a separate host-targeted copy below.
    const trie_target_mod = b.createModule(.{
        .root_source_file = b.path("src/trie.zig"),
        .target = target,
    });
    trie_target_mod.addImport("blob_format", blob_format_target_mod);

    // ---- Host-side generator ----
    // gen_trie is a normal Zig executable that runs at build time. It needs
    // its own host-targeted copy of trie.zig (which it uses for buildBlob).
    const trie_host_mod = b.createModule(.{
        .root_source_file = b.path("src/trie.zig"),
        .target = b.graph.host,
    });
    trie_host_mod.addImport("blob_format", blob_format_host_mod);

    const gen_mod = b.createModule(.{
        .root_source_file = b.path("scripts/gen_trie.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    gen_mod.addImport("trie", trie_host_mod);

    const gen_exe = b.addExecutable(.{ .name = "gen_trie", .root_module = gen_mod });

    // ---- gen_trie run step: produces trie.bin + trie_blob_module.zig ----
    const gen_run = b.addRunArtifact(gen_exe);
    const trie_out_dir = gen_run.addOutputDirectoryArg("trie_data");
    gen_run.addArg(tables_eol_option);
    // Pass the target's endianness so the generator can byte-swap u32 fields
    // when the host and target differ. gen_trie itself always runs on the
    // host, so it can't infer this on its own.
    const target_endian_arg: []const u8 = switch (target.result.cpu.arch.endian()) {
        .little => "le",
        .big => "be",
    };
    gen_run.addArg(target_endian_arg);
    // Add every table file as an explicit input so cache invalidation works.
    const tables = [_][]const u8{
        "src/tables/1.danzi.txt",
        "src/tables/2.cizu.txt",
        "src/tables/3.fuhao.txt",
        "src/tables/4.buchong.txt",
        "src/tables/5.lianjie.txt",
        "src/tables/6.yingwen.txt",
        "src/tables/7.chaojizici.txt",
        "src/tables/8.wxw.txt",
    };
    for (tables) |t| gen_run.addFileArg(b.path(t));

    // ---- Blob module: wraps trie.bin via @embedFile, exposed as `trie_blob`. ----
    const blob_module = b.createModule(.{
        .root_source_file = trie_out_dir.path(b, "trie_blob_module.zig"),
        .target = target,
    });

    // ---- Library root module ----
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("trie", trie_target_mod);
    lib_mod.addImport("blob_format", blob_format_target_mod);
    lib_mod.addImport("trie_blob", blob_module);

    // On Windows, both a static lib and a DLL's import lib are named `<name>.lib`,
    // so installing both as "jd" would overwrite one. Rename the static archive
    // to avoid the collision.
    const static_lib_name = if (target.result.os.tag == .windows) "jd_static" else "jd";
    const static_lib = b.addLibrary(.{
        .name = static_lib_name,
        .root_module = lib_mod,
        .linkage = .static,
    });
    // PIE only applies to the static lib (shared libs are PIC by definition).
    static_lib.pie = true;

    const dynamic_lib = b.addLibrary(.{
        .name = "jd",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });

    // `bundle_compiler_rt` was set in Debug builds in the original build.zig
    // to inline compiler-rt into the archive, but on macOS that produces an
    // additional archive member that knocks the main object out of 8-byte
    // alignment, which Apple's `ld` rejects. The consumer (cli/, etc.) gets
    // compiler-rt symbols from libSystem on macOS / libgcc on Linux anyway,
    // so leaving this off is fine.

    b.installArtifact(static_lib);
    // On iOS the linker complains about missing symbols for shared libs.
    if (target.result.os.tag != .ios) {
        b.installArtifact(dynamic_lib);
    }

    // ---- Tests ----
    // We run the trie tests, plus the query/pagination tests via tests.zig.
    // Each test module gets the same module wiring as the lib so imports work.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("trie", trie_target_mod);
    test_mod.addImport("blob_format", blob_format_target_mod);

    const main_tests = b.addTest(.{ .root_module = test_mod });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
