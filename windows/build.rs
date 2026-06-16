use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    assert_eq!(target_os, "windows", "jd-windows is a Windows-only crate");

    let static_lib_name = "jd_static.lib";

    let libs_dir: PathBuf = if let Ok(libjd_path) = env::var("LIBJD_PATH") {
        PathBuf::from(libjd_path)
    } else {
        let core_dir = {
            let mut p = env::current_dir().unwrap();
            p.pop();
            p.push("core");
            p
        };

        // Pair the core's optimize mode with cargo's debug/release split:
        // Debug for cargo debug (enables the core's per-context DebugAllocator
        // leak detection), ReleaseFast for cargo release.
        let optimize_flag = if cfg!(debug_assertions) {
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

        println!("cargo:rerun-if-changed=../core/src");
        println!("cargo:rerun-if-changed=../core/build.zig");
        println!("cargo:rerun-if-changed=../core/scripts");

        core_dir.join("zig-out").join("lib")
    };

    let static_lib = libs_dir.join(static_lib_name);
    if !static_lib.exists() {
        panic!(
            "{} not found. Build core first or point LIBJD_PATH at a directory containing {}.",
            static_lib.display(),
            static_lib_name,
        );
    }
    println!("cargo:rustc-link-arg={}", static_lib.display());

    // Embed a side-by-side manifest into the cdylib so Windows treats this DLL
    // as a "modern" Win32 component (matches Microsoft's IMEs like input.dll).
    // Without an embedded manifest, the IME is tagged "(desktop only)" in
    // Settings > Add a keyboard and can't be installed.
    embed_resource::compile("jd_ime.rc", embed_resource::NONE)
        .manifest_required()
        .unwrap();

    println!("cargo:rerun-if-changed=app.manifest");
    println!("cargo:rerun-if-changed=jd_ime.rc");
    println!("cargo:rerun-if-env-changed=LIBJD_PATH");
}
