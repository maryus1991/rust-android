# Limitations (read before shipping)

* **WebViews differ.** Android System WebView (Chromium), WKWebView (WebKit), WebView2 and WebKitGTK are not browsers: no extensions, service-worker/Push/Web Share/WebAuthn/Bluetooth support varies by OS and version. Nothing here fakes a missing web API.
* **Permissions on Linux:** WebKitGTK denies camera/microphone/geolocation unless the app grants them; this project does **not** grant them silently, so these stay denied on Linux until a consent prompt exists (planned).
* **Camera/microphone/geolocation on macOS/iOS** are controlled by the OS prompt (Info.plist texts are generated); the origin policy cannot intercept them there.
* **Downloads:** desktop = saved to Downloads, no progress UI (Tauri exposes only start/finish). Android = system DownloadManager (background + notification); `blob:`/`data:` downloads are not supported. iOS = not implemented in this release.
* **Error detection is heuristic.** Tauri/wry expose no "load failed" or "renderer crashed" callbacks. The supervisor uses a page heartbeat + reachability probe. It stays passive until the site proved it can talk to the bridge (a strict CSP that blocks IPC disables the heuristic instead of causing reload loops). TLS errors and HTTP error pages are shown by the WebView itself.
* **Multiple windows / popups:** desktop only. On Android/iOS `window.open` links load in the main view; OAuth flows that need `window.opener` should use redirect-based login.
* **Splash screen:** an in-page splash (color + logo) is shown for the first page. The native OS splash is the Tauri default; customising it is not part of this release.
* **Status/navigation bar colors:** applied on Android < 15 only (edge-to-edge is enforced since Android 15). Not implemented on iOS/desktop.
* **Android `intent:` URLs are blocked** by design (arbitrary component launch). Use `paymentSchemes` for plain custom schemes.
* **iOS** needs an Apple Developer account for any installable IPA. Without secrets CI only verifies compilation and says so.
* **Windows** binaries are unsigned (SmartScreen warning). **Linux** RPM is best-effort.
* **Not in this release (planned):** biometric, NFC, haptics, deep links, pull-to-refresh, Web Share / file sharing, push notifications (FCM/APNs), private/multiple profiles.
* **What has and has not been executed** by the authors is listed in the delivery report that ships with this project.
