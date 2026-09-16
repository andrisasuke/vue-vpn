fn main() {
    println!("cargo:rerun-if-changed=../native/src/AppBridge.mm");
    println!("cargo:rerun-if-changed=../native/include/Protocol.h");
    println!("cargo:rerun-if-changed=../native/include/ServicePolicy.hpp");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .cpp(true)
            .file("../native/src/AppBridge.mm")
            .include("../native/include")
            .flag("-std=c++17")
            .flag("-fobjc-arc")
            .flag("-mmacosx-version-min=13.0")
            .compile("vuevpn_bridge");
        for framework in [
            "Foundation",
            "AppKit",
            "Security",
            "ServiceManagement",
            "SystemConfiguration",
            "LocalAuthentication",
        ] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
    }
    tauri_build::build()
}
