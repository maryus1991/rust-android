# Installation and local builds

## Using GitHub Actions only (recommended)
You need: a GitHub account, `git`, `bash` and `jq`. On Windows use Git for Windows (Git Bash) and `winget install jqlang.jq`; on macOS `brew install jq`; on Debian/Ubuntu `sudo apt install jq`.

1. Fork → enable Actions → clone → `bash scripts/setup.sh` → `git push` (see README).
2. Watch **Actions → Release**. Files appear under **Releases**.

## Local builds
`bash scripts/build-local.sh --check` reports, per platform, what is missing. Typical prerequisites:

| Platform | Host | Needs |
|---|---|---|
| Linux | Linux | Rust (rustup), Tauri CLI (`cargo install tauri-cli --version '^2' --locked`), `libwebkit2gtk-4.1-dev build-essential pkg-config libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf` |
| Windows | Windows | Rust, Tauri CLI, WebView2 runtime, Visual Studio Build Tools (C++), WiX/NSIS are downloaded by Tauri |
| Android | Linux/macOS/Windows | Rust + Android targets, Tauri CLI, JDK 17, Android SDK + NDK (`ANDROID_HOME`, `NDK_HOME`) |
| iOS | macOS | Rust + `aarch64-apple-ios`, Tauri CLI, Xcode, signing secrets as environment variables |

Rust is pinned in `rust-toolchain.toml`; rustup installs it automatically. Output goes to `dist/`, logs to `build-logs/`.
Desktop apps are not cross-compiled; use Actions for platforms your machine cannot build.
