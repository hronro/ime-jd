const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const tables_eol_option = b.option([]const u8, "tables_eol", "The EOL character for table files in the `src/tables/` directory. Normally it's \"\\n\" in Unix and Unix-like OSs and \"\\r\\n\" in Windows.");
    const tables_eol = b.addOptions();
    tables_eol.addOption(?[]const u8, "tables_eol", tables_eol_option);

    const lite_option = b.option(bool, "lite", "Whether to build the lite version of the library. Lite version uses less memory but is a little bit slower.");
    const lite = b.addOptions();
    lite.addOption(?bool, "lite", lite_option);

    const static_lib = b.addStaticLibrary(.{
        .name = "jd",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const dynamic_lib = b.addSharedLibrary(.{
        .name = "jd",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    static_lib.addOptions("tables_eol", tables_eol);
    static_lib.addOptions("lite", lite);
    dynamic_lib.addOptions("tables_eol", tables_eol);
    dynamic_lib.addOptions("lite", lite);

    static_lib.pie = true;

    if (optimize == .Debug) {
        static_lib.bundle_compiler_rt = true;
        dynamic_lib.bundle_compiler_rt = true;
    } else {
        static_lib.strip = true;
        dynamic_lib.strip = true;
    }

    // This declares intent for the library to be installed into the standard
    // location when the user invokes the "install" step (the default step when
    // running `zig build`).
    b.installArtifact(static_lib);
    b.installArtifact(dynamic_lib);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const main_tests = b.addTest(.{
        // we choose `src/tests.zig` as root instead of `src/main.zig`,
        // because we want to avoid the the compile-time trie generation,
        // which would spend a lot of time.
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build test`
    // This will evaluate the `test` step rather than the default, which is "install".
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
