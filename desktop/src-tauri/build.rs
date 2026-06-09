fn main() {
    // Zpřístupní cílový triple (např. aarch64-apple-darwin) za běhu, ať umíme
    // v dev režimu najít přibalené binárky v `binaries/<name>-<triple>`.
    if let Ok(triple) = std::env::var("TARGET") {
        println!("cargo:rustc-env=YTMP_TARGET_TRIPLE={triple}");
    }
    tauri_build::build()
}
