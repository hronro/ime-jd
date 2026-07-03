//! Locates (or builds) libjd and emits its link directives. This is the one
//! place the Rust frontends acquire the core engine: they depend on this
//! crate, and Cargo's `links = "jd"` mechanism carries the native library
//! into their final link.
//!
//! Two pieces of metadata are published for dependents' build scripts:
//!   - `DEP_JD_LIBDIR`  — the directory the libraries were found in
//!   - `DEP_JD_LINKAGE` — "static" or "dynamic"
//! The only thing that can't propagate from here is a linker arg on the
//! final binary, so a dependent that needs an rpath (the CLI's dynamic dev
//! builds) emits it itself from those two values.

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    let is_windows = target_os == "windows";
    // The cargo profile of the *target* build. (`cfg!(debug_assertions)`
    // would reflect how this build script itself was compiled, which only
    // coincidentally tracks the target profile.)
    let is_debug_profile = env::var("PROFILE").as_deref() == Ok("debug");

    // Where the libs live. Either supplied via LIBJD_PATH (CI hands us a
    // prebuilt bundle), or we build the core ourselves with zig and use
    // core/zig-out/lib.
    let libs_dir: PathBuf = if let Ok(libjd_path) = env::var("LIBJD_PATH") {
        PathBuf::from(libjd_path)
    } else {
        let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
        let core_dir = manifest_dir.join("..").join("..").join("core");

        // Pair the core's optimize mode with cargo's debug/release split:
        // Debug for cargo debug (enables the core's per-context DebugAllocator
        // leak detection), ReleaseFast for cargo release.
        let optimize_flag = if is_debug_profile {
            "-Doptimize=Debug"
        } else {
            "-Doptimize=ReleaseFast"
        };
        if !Command::new("zig")
            .args(["build", optimize_flag])
            .current_dir(&core_dir)
            .status()
            .unwrap()
            .success()
        {
            panic!("Failed to build core");
        }

        println!("cargo:rerun-if-changed=../../core/src");
        println!("cargo:rerun-if-changed=../../core/build.zig");
        println!("cargo:rerun-if-changed=../../core/scripts");

        core_dir.join("zig-out").join("lib")
    };

    // Cargo release → static link. Cargo debug → dynamic link on Unix
    // (faster relinks during iteration). Windows always static-links: the
    // rpath trick used on Unix doesn't apply, and forcing jd.dll next to the
    // binary at test time is more friction than it's worth.
    if is_debug_profile && !is_windows {
        println!("cargo:rustc-link-search=native={}", libs_dir.display());
        println!("cargo:rustc-link-lib=dylib=jd");
        // The rpath below applies only to this crate's own test binaries;
        // link args don't propagate to dependents (see module docs).
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", libs_dir.display());
        println!("cargo:linkage=dynamic");
    } else {
        // Static linking. Apple's ld64 ignores rustc's "static" link kind
        // and silently prefers libjd.dylib when both files sit in the same
        // search dir (and CI's prebuilt bundles contain both), so we copy
        // the archive into OUT_DIR and search only there. On Windows the
        // archive is named jd_static.lib to avoid colliding with the DLL's
        // import library jd.lib — see core/docs/integration.md.
        let (archive, lib_name) = if is_windows {
            ("jd_static.lib", "jd_static")
        } else {
            ("libjd.a", "jd")
        };
        let static_lib = libs_dir.join(archive);
        if !static_lib.exists() {
            panic!(
                "{} not found. Build core first or point LIBJD_PATH at a directory containing {}.",
                static_lib.display(),
                archive,
            );
        }
        let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
        fs::copy(&static_lib, out_dir.join(archive)).expect("copy static libjd into OUT_DIR");
        println!("cargo:rustc-link-search=native={}", out_dir.display());
        println!("cargo:rustc-link-lib=static={lib_name}");
        println!("cargo:linkage=static");
    }

    println!("cargo:libdir={}", libs_dir.display());
    println!("cargo:rerun-if-env-changed=LIBJD_PATH");
}
