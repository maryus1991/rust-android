# Delivery report - phase 1

## Implemented
* Tauri 2 / Rust core: exact-match origin policy, navigation guard (external browser / block, dangerous schemes blocked), allow-listed bridge with feature gates,
  permission policy, desktop downloads with sanitised names, popups (desktop), offline/error pages (en + fa, RTL), reachability probe, load watchdog, auto-reconnect with backoff, hang recovery with a recovery cap, in-page splash.
* Official plugins wired: opener, notification (Notification API shim + bridge), clipboard-manager (write only).
* Local Android plugin (Kotlin): DownloadManager downloads, merged manifest permissions, best-effort bar colors.
* `scripts/setup.sh` wizard (interactive + non-interactive, validation, image import/validation, backup + automatic rollback, report), `validate.sh`, `sync-config.sh`, `generate-icons.sh`, `build-local.sh`, `make-android-keystore.sh`.
* Workflows: `validate.yml`; `release.yml` with four independent build jobs, a prepare job (release planning, duplicate-release protection) and a release job; Android post-build signing (no generated-file edits), honest unsigned/test-signed/no-IPA behaviour.
* Docs (README, README.fa, INSTALLATION, CONFIGURATION, FEATURES (generated), ARCHITECTURE, SECURITY, LIMITATIONS, SECRETS, TROUBLESHOOTING, CONTRIBUTING).

## Platform limited / unsupported / planned
See `docs/FEATURES.md` (generated) and `docs/LIMITATIONS.md`. Planned (cannot be enabled): biometric, NFC, haptics, deep links, pull-to-refresh, Web Share, file sharing, push notifications, private/multiple profiles.
iOS downloads, native splash customisation, Linux camera/microphone/geolocation consent prompt: not implemented.

## Executed (Linux x86_64 sandbox, Ubuntu 24.04, Rust 1.91.1)
* `cargo fmt --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --locked --workspace --lib`: **27 Rust unit tests pass** (config validation, look-alike domains, navigation decisions, filename sanitising, bridge authorisation/feature gates, permission policy, capability file == runtime policy, reachability probe).
* Debug build of the app on Linux and **real runs under Xvfb/WebKitGTK**:
  1. unreachable site -> watchdog -> DNS probe -> bundled offline page rendered (screenshot verified);
  2. local test site: the page could call `app.info`; `plugin:fs|read_dir` and `plugin:opener|open_url` were **denied**; an unknown bridge action was rejected; disabled-feature APIs (`notify`, `copyText`) were absent; navigation to an out-of-scope site did not replace the page.
* 36 shell tests (`tests/run-all.sh`): config validation incl. negative cases, setup wizard (interactive, non-interactive, JPEG/SVG/PNG, invalid images, rollback, idempotency), generated manifest/plist/tauri.conf, capability generation, feature-registry consistency, release planning logic (duplicates, tag mismatch, modes, slug), artifact collection, no-secrets scan, workflow least-privilege checks.
* `shellcheck` (all scripts), `actionlint` (all workflows), YAML parsing, `tauri icon` generation from PNG and SVG.

## NOT executed (be aware)
* Any **Windows**, **macOS/iOS** or **Android** build or run. The Kotlin plugin and its Gradle files (taken from the official `tauri plugin new` template) have **never been compiled**; `tauri android init/build`, APK/AAB signing (`apksigner`/`jarsigner`), `tauri ios init/build` and the iOS compile check are untested.
* Linux bundle creation (`deb`/`AppImage`/`rpm`) and MSI/NSIS packaging.
* The workflows on real GitHub runners, the release job and `gh release create`.
* `cargo audit` (runs in `validate.yml`; not run here), mobile-target `cargo check`.
* Desktop download handler, popup creation, notification and clipboard bridge actions at runtime (they compile and are unit-tested only for authorisation).
* Android WebView behaviours (file chooser/capture, permissions, geolocation, fullscreen, back navigation) are **based on reading wry 0.57.1 source**, not on running it.
* Version pinning: Rust 1.91.0, Tauri crate 2.12.5 (`Cargo.lock`), CLI 2.12.4. Gradle/AGP/Kotlin versions come from the templates of the pinned CLI (`tauri android init`) and are not pinned separately.

Expect first-run fixes on the Android and iOS jobs; the scripts print clear errors and keep status files per platform.
