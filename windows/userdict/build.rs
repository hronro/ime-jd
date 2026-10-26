use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    assert_eq!(target_os, "windows", "jd-userdict is a Windows-only crate");

    // The window's resources: its dialogs (userdict.rc), the manifest that
    // asks for common controls 6 and per-monitor DPI, the seal icon (also
    // the window's), and a VERSIONINFO carrying the project version from
    // core/build.zig.zon, as the IME DLL's does (../build.rs). Only the
    // binary links them; the library the DLL shares carries none.
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());

    let zon = fs::read_to_string(manifest_dir.join("../../core/build.zig.zon"))
        .expect("read ../../core/build.zig.zon");
    let version = zon_version(&zon);
    let core = version.split(['-', '+']).next().unwrap();
    let mut parts = core.split('.').map(|s| s.parse::<u16>().unwrap_or(0));
    let major = parts.next().unwrap_or(0);
    let minor = parts.next().unwrap_or(0);
    let patch = parts.next().unwrap_or(0);

    // Beside the generated .rc, so its relative names resolve whatever the
    // resource compiler's working directory.
    for (from, to) in [
        (manifest_dir.join("app.manifest"), "app.manifest"),
        (manifest_dir.join("userdict.rc"), "userdict.rc"),
        (manifest_dir.join("../jd.ico"), "jd.ico"),
    ] {
        fs::copy(&from, out_dir.join(to))
            .unwrap_or_else(|e| panic!("copy {} into OUT_DIR: {e}", from.display()));
    }

    let rc = format!(
        "#pragma code_page(65001)\n\
         #include <windows.h>\n\
         #include <commctrl.h>\n\
         \n\
         CREATEPROCESS_MANIFEST_RESOURCE_ID RT_MANIFEST \"app.manifest\"\n\
         \n\
         1 ICON \"jd.ico\"\n\
         \n\
         #include \"userdict.rc\"\n\
         \n\
         1 VERSIONINFO\n\
         FILEVERSION {major},{minor},{patch},0\n\
         PRODUCTVERSION {major},{minor},{patch},0\n\
         FILEFLAGSMASK 0x3fL\n\
         FILEFLAGS 0x0L\n\
         FILEOS 0x40004L\n\
         FILETYPE 0x1L\n\
         FILESUBTYPE 0x0L\n\
         BEGIN\n\
         BLOCK \"StringFileInfo\"\n\
         BEGIN\n\
         BLOCK \"040904b0\"\n\
         BEGIN\n\
         VALUE \"CompanyName\", \"hronro\"\n\
         VALUE \"FileDescription\", \"键道用户自造词\"\n\
         VALUE \"FileVersion\", \"{major}.{minor}.{patch}.0\"\n\
         VALUE \"InternalName\", \"ime_jd_userdict\"\n\
         VALUE \"OriginalFilename\", \"ime_jd_userdict.exe\"\n\
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
    let rc_path = out_dir.join("ime_jd_userdict.rc");
    fs::write(&rc_path, rc).expect("write generated ime_jd_userdict.rc");
    embed_resource::compile(&rc_path, embed_resource::NONE)
        .manifest_required()
        .unwrap();

    println!("cargo:rerun-if-changed=app.manifest");
    println!("cargo:rerun-if-changed=userdict.rc");
    println!("cargo:rerun-if-changed=../jd.ico");
    println!("cargo:rerun-if-changed=../../core/build.zig.zon");
}

/// Extract the `.version = "X.Y.Z"` string from a build.zig.zon's text —
/// the same reading as the IME DLL's build script.
fn zon_version(zon: &str) -> String {
    for line in zon.lines() {
        if let Some(rest) = line.trim().strip_prefix(".version")
            && let Some(start) = rest.find('"')
            && let Some(end) = rest[start + 1..].find('"')
        {
            return rest[start + 1..start + 1 + end].to_string();
        }
    }
    panic!("no `.version` field found in core/build.zig.zon");
}
