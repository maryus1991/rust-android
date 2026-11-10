# Architecture

```
config/app.json ──► scripts/sync-config.sh ─► tauri.conf.json, Android manifest (plugin), Info.ios.plist, splash logo
        │                                      └► build.rs ─► capabilities/remote.json (allowed origins)
        └─(embedded at compile time)─► src-tauri (Rust core)
```

* **One source of truth**: `config/app.json`. It is validated by `scripts/validate.sh` (before every build) and again by the
  Rust core at start-up. `config/features.json` is the registry of features and their honest status.
* **The website runs in the OS WebView** (WebView2 / WebKitGTK / Android System WebView / WKWebView). Rust never proxies site traffic.
  The window is created in code (`src-tauri/src/window.rs`) with `WebviewUrl::External(<site url>)`; `ui/` only holds the offline and error pages.
* **Core modules** (`src-tauri/src`)
  | module | role |
  |---|---|
  | `config.rs` | typed config + validation (rejects unknown / `planned` features) |
  | `security.rs` | exact-match origin policy, navigation decision, filename sanitising (pure, unit tested) |
  | `window.rs` | builds the window: navigation guard, popups, downloads (desktop), permission policy, init script |
  | `bridge.rs` / `bridge.js` | the single allowlisted native bridge (see SECURITY.md) |
  | `network.rs` | DNS/TCP reachability probe (not used for site traffic) |
  | `supervisor.rs` | load watchdog, offline/error pages, auto-reconnect with backoff, hang recovery |
* **Native plugin** `plugins/web2app-native` (Rust + Kotlin): merges generated Android permissions, attaches a `DownloadManager`
  download listener, applies status/navigation bar colors where Android allows. It exposes **no commands** to web content.
  Official Tauri plugins used: `opener`, `notification` (if enabled), `clipboard-manager` (if enabled).
* **Generated native projects** (`src-tauri/gen/android|apple`) are created by `tauri android init` / `tauri ios init` in CI and are never
  edited. Everything we need to inject goes through plugin-owned files (Android manifest merge, `Info.ios.plist` merge) or post-build steps
  (APK/AAB signing).
* **Adding a native plugin later** (phase 2: biometric, NFC, haptics, deep links, share sheet): add a crate under `plugins/`, register it in
  `lib.rs` behind its feature flag, add an action to the table in `bridge.rs` (`spec()`), flip the feature's status in `config/features.json`.
  The core, setup wizard and workflows do not change.
