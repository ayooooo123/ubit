use std::env;
use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    println!("cargo:rerun-if-changed=sdk/include/ubit.h");
    println!("cargo:rerun-if-changed=sdk/src/ubit_sdk.cpp");
    for hdr in [
        "crypto_http.hpp",
        "engine.hpp",
        "extractors.hpp",
        "json.hpp",
        "models.hpp",
        "mux.hpp",
        "softcrypto.hpp",
    ] {
        println!("cargo:rerun-if-changed=linux/src/{hdr}");
    }

    let mut build = cc::Build::new();
    build
        .cpp(true)
        .std("c++20")
        .define("UBIT_SDK", None)
        .include(manifest.join("sdk/include"))
        .include(manifest.join("linux/src"))
        .file(manifest.join("sdk/src/ubit_sdk.cpp"))
        .warnings(false);

    // Strip build-host paths from __FILE__ / unwind strings so published FFI binaries stay clean.
    let remap_manifest = format!("-ffile-prefix-map={}=", manifest.display());
    build.flag_if_supported(&remap_manifest);
    if let Ok(home) = env::var("HOME") {
        let remap_home = format!("-ffile-prefix-map={home}=~");
        build.flag_if_supported(&remap_home);
    }

    build.compile("ubit_sdk");
}
