//! Builds Binaryen from its vendored sources (`binaryen/`) with CMake, as a static library in its
//! release configuration, and links it with the C++ standard library it needs.
//!
//! Only the library is built: no tools, no tests and no link-time
//! optimisation (whose objects only the compiler that made them could link). Binaryen keeps its
//! assertions in release builds, so a broken invariant inside it aborts instead of going on.
//!
//! On docs.rs (`DOCS_RS` set), it builds nothing: documenting the crate doesn't link it, and the
//! few minutes Binaryen's build takes would only slow docs.rs down.

use std::env;

fn main() {
    println!("cargo::rerun-if-changed=build.rs");
    println!("cargo::rerun-if-changed=binaryen");
    println!("cargo::rerun-if-env-changed=DOCS_RS");
    if env::var_os("DOCS_RS").is_some() {
        return;
    }

    let install = cmake::Config::new("binaryen")
        .profile("Release")
        .define("BUILD_SHARED_LIBS", "OFF")
        .define("BUILD_TESTS", "OFF")
        .define("BUILD_TOOLS", "OFF")
        .define("BYN_ENABLE_LTO", "OFF")
        .define("ENABLE_WERROR", "OFF")
        .define("CMAKE_INSTALL_LIBDIR", "lib")
        .build();
    println!(
        "cargo::rustc-link-search=native={}",
        install.join("lib").display()
    );
    println!("cargo::rustc-link-lib=static=binaryen");
    if let Some(stdlib) = cpp_stdlib() {
        println!("cargo::rustc-link-lib={stdlib}");
    }
}

/// The C++ standard library of the target's default toolchain, the one CMake compiled Binaryen
/// against: none to name with MSVC, which links its own; libc++ on Apple's platforms; libstdc++
/// everywhere else.
fn cpp_stdlib() -> Option<&'static str> {
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    let target_vendor = env::var("CARGO_CFG_TARGET_VENDOR").unwrap_or_default();
    if target_env == "msvc" {
        None
    } else if target_vendor == "apple" {
        Some("c++")
    } else {
        Some("stdc++")
    }
}
