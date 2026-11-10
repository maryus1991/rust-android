# tauri-plugin-web2app-native

Android helpers for Universal Web2App (Kotlin): merges generated permissions, attaches a DownloadManager download listener,
best-effort status/navigation bar colors. No commands are exposed to JavaScript. Desktop and iOS: no-op.
Configuration comes from `plugins.web2app-native` in `src-tauri/tauri.conf.json` (written by `scripts/sync-config.sh`).
`android/src/main/AndroidManifest.xml` is generated; do not edit it.
