use std::env;
use std::process::Command;

fn main() {
    let core_dir = {
        let mut p = env::current_dir().unwrap();
        p.pop();
        p.push("core");
        p
    };

    if let Ok(libjd_path) = env::var("LIBJD_PATH") {
        println!("cargo:rustc-link-search=native={}", libjd_path);
        println!("cargo:rustc-link-lib=static=jd");
    } else {
        let out_dir = {
            let mut p = core_dir.clone();
            p.push("zig-out");
            p.push("lib");
            p
        };

        let zig_build_option = if cfg!(debug_assertions) {
            vec!["build"]
        } else {
            vec!["build", "-Doptimize=ReleaseSmall"]
        };

        if cfg!(debug_assertions) {
            println!("Debugging enabled");
        } else {
            println!("Debugging disabled");
        }

        if !Command::new("zig")
            .args(zig_build_option)
            .current_dir(core_dir)
            .status()
            .unwrap()
            .success()
        {
            panic!("Failed to build core");
        }

        println!("cargo:rustc-link-search=native={}", out_dir.display());
        println!("cargo:rustc-link-lib=static=jd");
        println!("cargo:rerun-if-changed=../core/src");
    }
}
