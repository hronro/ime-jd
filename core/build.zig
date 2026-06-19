const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // EOL of the table .txt files. Normally "\n" on Unix; pass "\r\n" if your
    // checkout has CRLF endings on Windows.
    const tables_eol_option = b.option([]const u8, "tables_eol", "EOL for src/tables/*.txt files (default: lf)") orelse "lf";

    // Pass the target's endianness so the generators can byte-swap fields
    // when the host and target differ. They run on the host, so they can't
    // infer this on their own.
    const target_endian_arg: []const u8 = switch (target.result.cpu.arch.endian()) {
        .little => "le",
        .big => "be",
    };

    // ========== Trie blob (existing) ==========

    // Shared format module (host + target).
    const blob_format_target_mod = b.createModule(.{
        .root_source_file = b.path("src/blob_format.zig"),
        .target = target,
    });
    const blob_format_host_mod = b.createModule(.{
        .root_source_file = b.path("src/blob_format.zig"),
        .target = b.graph.host,
    });

    // Trie module (target side, embedded in the lib).
    const trie_target_mod = b.createModule(.{
        .root_source_file = b.path("src/trie.zig"),
        .target = target,
    });
    trie_target_mod.addImport("blob_format", blob_format_target_mod);

    // Host-side gen_trie.
    const trie_host_mod = b.createModule(.{
        .root_source_file = b.path("src/trie.zig"),
        .target = b.graph.host,
    });
    trie_host_mod.addImport("blob_format", blob_format_host_mod);

    const gen_trie_mod = b.createModule(.{
        .root_source_file = b.path("scripts/gen_trie.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    gen_trie_mod.addImport("trie", trie_host_mod);

    const gen_trie_exe = b.addExecutable(.{ .name = "gen_trie", .root_module = gen_trie_mod });

    const gen_trie_run = b.addRunArtifact(gen_trie_exe);
    const trie_out_dir = gen_trie_run.addOutputDirectoryArg("trie_data");
    gen_trie_run.addArg(tables_eol_option);
    gen_trie_run.addArg(target_endian_arg);
    // Add every table file as an explicit input so cache invalidation works.
    const tables = [_][]const u8{
        "src/tables/1.single.txt",
        "src/tables/2.phrase.txt",
        "src/tables/3.symbol.txt",
        "src/tables/4.supplement.txt",
        "src/tables/5.link.txt",
        "src/tables/6.english.txt",
        "src/tables/7.css.txt",
    };
    for (tables) |t| gen_trie_run.addFileArg(b.path(t));

    // Blob module wrapping trie.bin via @embedFile, exposed as `trie_blob`.
    const trie_blob_module = b.createModule(.{
        .root_source_file = trie_out_dir.path(b, "trie_blob_module.zig"),
        .target = target,
    });

    // ========== Punctuation-marks blob ==========

    // Shared format module (host + target).
    const punc_format_target_mod = b.createModule(.{
        .root_source_file = b.path("src/punc_format.zig"),
        .target = target,
    });
    const punc_format_host_mod = b.createModule(.{
        .root_source_file = b.path("src/punc_format.zig"),
        .target = b.graph.host,
    });

    // Punc module (target side).
    const punc_target_mod = b.createModule(.{
        .root_source_file = b.path("src/punc.zig"),
        .target = target,
    });
    punc_target_mod.addImport("punc_format", punc_format_target_mod);

    // Host-side gen_punc.
    const punc_host_mod = b.createModule(.{
        .root_source_file = b.path("src/punc.zig"),
        .target = b.graph.host,
    });
    punc_host_mod.addImport("punc_format", punc_format_host_mod);

    const gen_punc_mod = b.createModule(.{
        .root_source_file = b.path("scripts/gen_punc.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    gen_punc_mod.addImport("punc", punc_host_mod);

    const gen_punc_exe = b.addExecutable(.{ .name = "gen_punc", .root_module = gen_punc_mod });

    const gen_punc_run = b.addRunArtifact(gen_punc_exe);
    const punc_out_dir = gen_punc_run.addOutputDirectoryArg("punc_data");
    gen_punc_run.addArg(tables_eol_option);
    gen_punc_run.addArg(target_endian_arg);
    gen_punc_run.addFileArg(b.path("src/punctuation-marks/normal.txt"));
    gen_punc_run.addFileArg(b.path("src/punctuation-marks/paired.txt"));

    // Blob module wrapping punc.bin via @embedFile, exposed as `punc_blob`.
    const punc_blob_module = b.createModule(.{
        .root_source_file = punc_out_dir.path(b, "punc_blob_module.zig"),
        .target = target,
    });

    // ========== Library root module ==========

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("trie", trie_target_mod);
    lib_mod.addImport("blob_format", blob_format_target_mod);
    lib_mod.addImport("trie_blob", trie_blob_module);
    lib_mod.addImport("punc_format", punc_format_target_mod);
    lib_mod.addImport("punc_blob", punc_blob_module);

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

    // ========== Tests ==========
    // We run the trie tests, plus the query/pagination/punc tests via tests.zig.
    // Each test module gets the same module wiring as the lib so imports work.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("trie", trie_target_mod);
    test_mod.addImport("blob_format", blob_format_target_mod);
    test_mod.addImport("punc_format", punc_format_target_mod);

    const main_tests = b.addTest(.{ .root_module = test_mod });
    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // Generator scripts have their own test blocks (parser unit tests).
    // They live in host-targeted modules so they share the host-side
    // `trie` / `punc` imports used by the executables.
    const gen_trie_test_mod = b.createModule(.{
        .root_source_file = b.path("scripts/gen_trie.zig"),
        .target = b.graph.host,
    });
    gen_trie_test_mod.addImport("trie", trie_host_mod);
    const gen_trie_tests = b.addTest(.{ .root_module = gen_trie_test_mod });
    const run_gen_trie_tests = b.addRunArtifact(gen_trie_tests);
    test_step.dependOn(&run_gen_trie_tests.step);

    const gen_punc_test_mod = b.createModule(.{
        .root_source_file = b.path("scripts/gen_punc.zig"),
        .target = b.graph.host,
    });
    gen_punc_test_mod.addImport("punc", punc_host_mod);
    const gen_punc_tests = b.addTest(.{ .root_module = gen_punc_test_mod });
    const run_gen_punc_tests = b.addRunArtifact(gen_punc_tests);
    test_step.dependOn(&run_gen_punc_tests.step);
}
