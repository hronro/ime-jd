use std::env;

fn main() {
    // libjd is located and linked by the `jd` crate's build script
    // (bindings/rust/build.rs). The one directive that can't propagate from
    // a dependency is a linker arg on the final binary: when the engine is
    // dynamically linked (Unix dev builds), the binary needs an rpath
    // pointing at the directory libjd.{dylib,so} lives in. The `jd` crate
    // publishes that directory and the chosen linkage via its `links = "jd"`
    // metadata.
    if env::var("DEP_JD_LINKAGE").as_deref() == Ok("dynamic") {
        let libdir = env::var("DEP_JD_LIBDIR").expect("the jd crate always sets libdir");
        println!("cargo:rustc-link-arg=-Wl,-rpath,{libdir}");
    }
}
