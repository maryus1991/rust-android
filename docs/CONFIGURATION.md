# Configuration (`config/app.json`)

Edit through `bash scripts/setup.sh` (recommended) or by hand followed by `bash scripts/sync-config.sh && bash scripts/validate.sh`.
CI validates and regenerates derived files itself, so a hand edit + push also works as long as validation passes.

| Key | Meaning |
|---|---|
| `app.name`, `app.identifier`, `app.version` | display name, package id (`com.company.app`, letters/digits/underscore), semantic version (drives release tag `v<version>`) |
| `app.description/author/copyright/defaultLanguage/defaultTheme` | metadata; language (`en`, `fa`) selects the offline-page language and RTL; theme `system|light|dark` (desktop window theme) |
| `site.url` | start page, **https** unless `security.httpsOnly=false` |
| `site.includeSubdomains` | also allow `*.<host of site.url>` |
| `site.allowedDomains` | extra hosts: `login.example.org`, `*.cdn.example.net`, `host:8443` (no scheme, no path) |
| `site.userAgent` | optional UA override |
| `appearance.*` | colors `#RRGGBB`; `iconSource` / `logoSource` are managed by the wizard (`assets/icon`, `assets/splash`) |
| `platforms.*` | enable/disable each build job |
| `features.*` | see FEATURES.md; `planned` features are rejected |
| `security.outOfScopeLinks` | `system-browser` (default) or `block` for links outside the allowed hosts |
| `security.externalSchemes` | schemes opened in other apps (needs `features.externalApps`), default `tel,mailto,sms` |
| `security.paymentSchemes` | custom schemes for payment-app handoff (needs `features.paymentHandoff`) |
| `behavior.*` | load timeout, hang timeout, watchdog on/off, max automatic recoveries per 5 minutes |
| `release.mode` | `both`, `branch`, `tag` |

`config/platforms.json` holds build details: bundle formats, Android ABIs (default `aarch64`, `armv7`), iOS export method.
Derived files (never edit): `src-tauri/tauri.conf.json` (identity fields), `src-tauri/capabilities/remote.json`, `src-tauri/Info.ios.plist`, `plugins/web2app-native/android/src/main/AndroidManifest.xml`, `src-tauri/splash-logo.png`, `src-tauri/icons/`.
