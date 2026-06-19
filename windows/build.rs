use std::env;
use std::fs;
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

    // Generate the resource script at build time. It carries two things:
    //   1. The side-by-side manifest, so Windows treats this DLL as a "modern"
    //      Win32 component (matches Microsoft's IMEs like input.dll). Without
    //      an embedded manifest the IME is tagged "(desktop only)" in
    //      Settings > Add a keyboard and can't be installed.
    //   2. A VERSIONINFO block, so the DLL reports a version in Explorer's
    //      Properties > Details. The version is read from core/build.zig.zon —
    //      the single source of truth — so this crate's own Cargo.toml version
    //      stays a deliberate `0.0.0` placeholder.
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    let zon = fs::read_to_string(manifest_dir.join("../core/build.zig.zon"))
        .expect("read ../core/build.zig.zon");
    let version = zon_version(&zon);
    // VERSIONINFO's numeric fields must be integers; drop any -prerelease/+build.
    let core = version.split(|c| c == '-' || c == '+').next().unwrap();
    let mut parts = core.split('.').map(|s| s.parse::<u16>().unwrap_or(0));
    let major = parts.next().unwrap_or(0);
    let minor = parts.next().unwrap_or(0);
    let patch = parts.next().unwrap_or(0);

    // Copy app.manifest beside the generated .rc so its relative reference
    // resolves regardless of the resource compiler's working directory.
    fs::copy(
        manifest_dir.join("app.manifest"),
        out_dir.join("app.manifest"),
    )
    .expect("copy app.manifest into OUT_DIR");

    // `#pragma code_page(65001)` makes the resource compiler read this file as
    // UTF-8 (the product name is non-ASCII).
    let rc = format!(
        "#pragma code_page(65001)\n\
         #include <winuser.h>\n\
         \n\
         ISOLATIONAWARE_MANIFEST_RESOURCE_ID RT_MANIFEST \"app.manifest\"\n\
         \n\
         1 VERSIONINFO\n\
         FILEVERSION {major},{minor},{patch},0\n\
         PRODUCTVERSION {major},{minor},{patch},0\n\
         FILEFLAGSMASK 0x3fL\n\
         FILEFLAGS 0x0L\n\
         FILEOS 0x40004L\n\
         FILETYPE 0x2L\n\
         FILESUBTYPE 0x0L\n\
         BEGIN\n\
         BLOCK \"StringFileInfo\"\n\
         BEGIN\n\
         BLOCK \"040904b0\"\n\
         BEGIN\n\
         VALUE \"CompanyName\", \"hronro\"\n\
         VALUE \"FileDescription\", \"键道输入法\"\n\
         VALUE \"FileVersion\", \"{major}.{minor}.{patch}.0\"\n\
         VALUE \"InternalName\", \"jd_ime\"\n\
         VALUE \"OriginalFilename\", \"jd_ime.dll\"\n\
         VALUE \"ProductName\", \"键道输入法\"\n\
         VALUE \"ProductVersion\", \"{version}\"\n\
         END\n\
         END\n\
         BLOCK \"VarFileInfo\"\n\
         BEGIN\n\
         VALUE \"Translation\", 0x409, 1200\n\
         END\n\
         END\n",
    );
    let rc_path = out_dir.join("jd_ime.rc");
    fs::write(&rc_path, rc).expect("write generated jd_ime.rc");

    embed_resource::compile(&rc_path, embed_resource::NONE)
        .manifest_required()
        .unwrap();

    println!("cargo:rerun-if-changed=app.manifest");
    println!("cargo:rerun-if-changed=../core/build.zig.zon");
    println!("cargo:rerun-if-env-changed=LIBJD_PATH");
}

/// Extract the `.version = "X.Y.Z"` string from a build.zig.zon's text.
fn zon_version(zon: &str) -> String {
    for line in zon.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix(".version") {
            if let Some(start) = rest.find('"') {
                let after = &rest[start + 1..];
                if let Some(end) = after.find('"') {
                    return after[..end].to_string();
                }
            }
        }
    }
    panic!("no `.version` field found in core/build.zig.zon");
}
