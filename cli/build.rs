use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    let is_windows = target_os == "windows";

    // On Windows, build.zig names the static archive `jd_static.lib` to avoid
    // colliding with the DLL's import library `jd.lib`. Unix uses `libjd.a`.
    let static_lib_name = if is_windows {
        "jd_static.lib"
    } else {
        "libjd.a"
    };

    // Where the libs live. Either supplied via LIBJD_PATH, or we build the
    // core ourselves and use core/zig-out/lib.
    let libs_dir: PathBuf = if let Ok(libjd_path) = env::var("LIBJD_PATH") {
        PathBuf::from(libjd_path)
    } else {
        let core_dir = {
            let mut p = env::current_dir().unwrap();
            p.pop();
            p.push("core");
            p
        };

        // Always build the core with ReleaseSmall. We don't pair it with
        // cargo's debug/release split because the trie blob + small library
        // code are tiny — a Debug-optimized core would slow every Rust dev
        // run with no benefit.
        if !Command::new("zig")
            .args(["build", "-Doptimize=ReleaseSmall"])
            .current_dir(&core_dir)
            .status()
            .unwrap()
            .success()
        {
            panic!("Failed to build core");
        }

        println!("cargo:rerun-if-changed=../core/src");
        println!("cargo:rerun-if-changed=../core/build.zig");
        println!("cargo:rerun-if-changed=../core/scripts");

        core_dir.join("zig-out").join("lib")
    };

    // Cargo release → static link. Cargo debug → dynamic link on Unix
    // (faster relinks during iteration). Windows always static-links: the
    // rpath trick used on Unix doesn't apply, and forcing jd.dll next to the
    // binary at test time is more friction than it's worth.
    if cfg!(debug_assertions) && !is_windows {
        // Dynamic linking. On both platforms we need an rpath so the binary
        // can find libjd.{dylib,so} at runtime without DYLD_LIBRARY_PATH /
        // LD_LIBRARY_PATH being set.
        println!("cargo:rustc-link-search=native={}", libs_dir.display());
        println!("cargo:rustc-link-lib=dylib=jd");
        println!("cargo:rustc-link-arg=-Wl,-rpath,{}", libs_dir.display());
    } else {
        // Static linking. We pass the archive path directly because Apple's
        // ld64 ignores rustc's "static" link kind and silently prefers
        // libjd.dylib when both files are in a search dir — handing it the
        // absolute .a path side-steps that. Linux's ld and MSVC's link.exe
        // also accept an absolute path as a positional input file, so the
        // same shape works for all three.
        let static_lib = libs_dir.join(static_lib_name);
        if !static_lib.exists() {
            panic!(
                "{} not found. Build core first or point LIBJD_PATH at a directory containing {}.",
                static_lib.display(),
                static_lib_name,
            );
        }
        println!("cargo:rustc-link-arg={}", static_lib.display());
    }

    println!("cargo:rerun-if-env-changed=LIBJD_PATH");
}
