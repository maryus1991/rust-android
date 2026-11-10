# Features and platform support

_Generated from `config/features.json` by `scripts/gen-features-doc.sh`. Do not edit by hand._

Status meanings:

- **implemented** - Works and is wired to the runtime in this release.
- **platform-limited** - Works only on some platforms; see platforms/notes.
- **planned** - Not implemented yet (planned for a later phase). Cannot be enabled.

Only features with status `implemented` or `platform-limited` can be enabled; `planned` features are rejected by the setup wizard, `scripts/validate.sh` and the app itself.

| Feature (config key) | Status | Toggle | Platforms | Notes |
|---|---|---|---|---|
| File Upload (<input type=file>, multiple, capture) (`fileUpload`) | implemented | yes | windows, linux, android, ios | Provided by the OS WebView; on Android by wry's file chooser (multiple files, MIME filters, camera capture). |
| Camera (getUserMedia video) (`camera`) | platform-limited | yes | windows, android, ios | Policy-gated by origin. Linux: denied (no native consent prompt yet). iOS: needs a signed build; OS prompt. |
| Microphone (getUserMedia audio) (`microphone`) | platform-limited | yes | windows, android, ios | Same rules as camera. |
| Geolocation (`geolocation`) | platform-limited | yes | windows, android, ios | Linux: denied. macOS/iOS: handled by the OS prompt, not by the origin policy. |
| Downloads (`downloads`) | platform-limited | yes | windows, linux, android | Desktop: saved to the Downloads folder (no progress UI). Android: system DownloadManager (background, notification). blob:/data: URLs on Android are unsupported. iOS: not supported in this release. |
| Native Notifications (via bridge + Notification API shim) (`notifications`) | implemented | yes | windows, linux, android, ios | Local notifications only. Push (FCM/APNs) is not part of this release. |
| Clipboard write (bridge) (`clipboard`) | implemented | yes | windows, linux, android, ios | Write only. Reading the clipboard from web content is deliberately not exposed. |
| Open out-of-scope links / tel: mailto: sms: in system apps (`externalApps`) | implemented | yes | windows, linux, android, ios | Allowlist of schemes in security.externalSchemes. |
| Fullscreen (HTML5 / video) (`fullscreen`) | implemented | yes | windows, linux, android, ios | Provided by the OS WebView. |
| Network monitoring, offline page, auto-retry, crash/hang recovery (`networkMonitoring`) | implemented | yes | windows, linux, android, ios | TCP/DNS reachability probe + page heartbeat watchdog (heuristic, not a native crash callback). |
| Multiple windows (window.open popups) (`multipleWindows`) | platform-limited | yes | windows, linux | Desktop only; Android/iOS do not expose popup creation in Tauri. |
| Payment/app handoff via custom URL schemes (`paymentHandoff`) | platform-limited | yes | windows, linux, android, ios | Only schemes listed in security.paymentSchemes. Android intent: URLs are intentionally blocked. |
| Background downloads (`backgroundDownloads`) | platform-limited | no | android | Automatic with downloads on Android (DownloadManager). Not available on desktop. |
| Status/navigation bar colors (`systemBars`) | platform-limited | no | android | Always applied from appearance.statusBarColor/navigationBarColor on Android < 15 only (Android 15+ enforces edge-to-edge). Not implemented on iOS/desktop. |
| Biometric authentication (`biometric`) | planned | no | - | Planned (phase 2). |
| NFC (`nfc`) | planned | no | - | Planned (phase 2). |
| Haptic feedback (`hapticFeedback`) | planned | no | - | Planned (phase 2). navigator.vibrate works natively on Android WebView only. |
| Deep links (`deepLinks`) | planned | no | - | Planned (phase 2). |
| Pull to refresh (`pullToRefresh`) | planned | no | - | Planned (phase 2): needs a native SwipeRefresh/UIRefreshControl integration. |
| Web Share API / share sheet (`webShare`) | planned | no | - | Planned (phase 2). |
| Native file sharing (`fileSharing`) | planned | no | - | Planned (phase 2). |
