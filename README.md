# Universal Web2App

Turn (almost) any website into installable **Windows, Linux, Android and iOS** apps – without writing code.
The site runs inside the operating system's own WebView; the project adds a small, secure Rust (Tauri 2) shell around it:
origin allow-listing, safe link handling, downloads, offline page with auto-retry, permission policy and an allow-listed native bridge.

> فارسی: خلاصه‌ی راهنما در [README.fa.md](README.fa.md)

## How it works (3 commands)

1. **Fork** this repository on GitHub and **enable Actions** in your fork (Actions tab → "I understand…").
2. Clone and configure:
   ```bash
   git clone https://github.com/USERNAME/universal-web2app.git
   cd universal-web2app
   bash scripts/setup.sh          # interactive wizard
   ```
3. Publish:
   ```bash
   git add .
   git commit -m "Configure application"
   git push origin main
   ```
   GitHub Actions builds four independent jobs (Windows, Linux, Android, iOS) and publishes the files to **Releases** of *your* repository.
   No Rust, Kotlin, Swift or workflow editing is needed. Nothing depends on the original repository.

## What the setup wizard asks
App name, package id, version, description, author, copyright, language, theme, **website URL**, extra allowed domains, optional User-Agent,
colors (primary, background, status bar, navigation bar, splash), **icon** and **logo** (PNG/SVG; JPEG when ImageMagick is installed; validated),
which **platforms** to build, which **features** to enable, link policy and release mode.
Re-running it shows your previous answers as defaults. It backs up every file it manages and **rolls back automatically** if anything fails.
Non-interactive use: `bash scripts/setup.sh --non-interactive --set site.url=https://my.site --set features.camera=true --icon logo.png`.
Everything is stored in `config/app.json` (no secrets). See [docs/CONFIGURATION.md](docs/CONFIGURATION.md).

Requirements for the wizard: `bash` and [`jq`](https://jqlang.github.io/jq/) (Linux/macOS/Git-Bash). Optional: ImageMagick (JPEG/SVG logo), Tauri CLI (local icon generation – CI always regenerates icons).

## Outputs (GitHub Releases)
```
<Name>-v1.0.0-windows-x64.msi          <Name>-v1.0.0-windows-x64-setup.exe
<Name>-v1.0.0-linux-x64.deb  .AppImage .rpm (best effort)
<Name>-v1.0.0-android.apk    <Name>-v1.0.0-android.aab
<Name>-v1.0.0-ios.ipa                   SHA256SUMS.txt
```
`<Name>` is the ASCII-safe form of the app name (falls back to the last part of the package id for non-Latin names).
The version comes from `config/app.json`. The release notes list exactly what each platform produced and how it was signed.

### Release triggers (`release.mode` in config)
* `both` (default): push to `main` publishes `v<version>` if that release does not exist; pushing tag `v<version>` is the official release.
* `branch`: only pushes to `main`. `tag`: only version tags. Tags must equal `v<version>` or the run fails with an explanation.
* A release that already exists is **never** duplicated: bump the version (`bash scripts/setup.sh --non-interactive --set app.version=1.0.1`) or run the workflow manually with *overwrite*.

## Signing (important)
| Platform | Without secrets | With secrets |
|---|---|---|
| Android | APK signed with a throw-away key (`…-android-testsign.apk`, install/test only), **no AAB** | signed APK + Play-ready AAB |
| iOS | **no IPA** – CI only verifies the app compiles | signed IPA |
| Windows | unsigned (SmartScreen warning) | – |
Secrets and how to create them: [docs/SECRETS.md](docs/SECRETS.md) (`bash scripts/make-android-keystore.sh` helps for Android).

## Forks and GitHub Actions limits
Workflows are disabled on new forks until you enable them. Private repositories consume your Actions minutes (macOS minutes cost 10×, Windows 2×).
Workflows triggered by `GITHUB_TOKEN` do not start other workflows (no loops). The release job is the only one with `contents: write`.

## Features and honesty
[docs/FEATURES.md](docs/FEATURES.md) lists every feature with its status: **implemented**, **platform-limited** or **planned** (cannot be enabled).
[docs/LIMITATIONS.md](docs/LIMITATIONS.md) lists WebView and platform limits. Nothing unsupported is faked.

## Security in one paragraph
Remote sites get **no** Tauri IPC except one allow-listed `bridge` command, only for your configured origins, re-validated on every call with exact host matching; invalid TLS is never accepted; out-of-scope links leave the app; dangerous URL schemes are blocked; sensitive permissions need the feature enabled **and** the platform's consent. Details: [docs/SECURITY.md](docs/SECURITY.md).

## Local build
`bash scripts/build-local.sh --check` tells you what this machine can build and what is missing; `bash scripts/build-local.sh` builds. Docs: [docs/INSTALLATION.md](docs/INSTALLATION.md).

## Documentation
[INSTALLATION](docs/INSTALLATION.md) · [CONFIGURATION](docs/CONFIGURATION.md) · [FEATURES](docs/FEATURES.md) · [ARCHITECTURE](docs/ARCHITECTURE.md) · [SECURITY](docs/SECURITY.md) · [LIMITATIONS](docs/LIMITATIONS.md) · [SECRETS](docs/SECRETS.md) · [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) · [CONTRIBUTING / plugins](docs/CONTRIBUTING.md)

## License
MIT
