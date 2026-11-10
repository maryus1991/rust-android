# Troubleshooting

| Problem | Fix |
|---|---|
| Nothing happens after `git push` | Enable workflows in the fork (Actions tab). Check `release.mode` and the run's **Release plan** summary. |
| "Release vX already exists" | Bump `app.version` or run the workflow manually with *overwrite*. |
| "Tag does not match config version" | Tag must be exactly `v<app.version>`. |
| `setup.sh`: `jq is required` | Install jq (see INSTALLATION.md). |
| Icon rejected | Must be square, ≥512 px (1024 recommended), PNG or SVG; JPEG needs ImageMagick. |
| Android APK says "not signed"/won't update | You got the `testsign` build. Set the four `ANDROID_*` secrets. |
| No IPA | Apple secrets are missing (see SECRETS.md). |
| Website opens in the browser instead of the app | Its host is not allowed: add it to `site.allowedDomains` (e.g. login or CDN hosts). |
| Login/payment popup does nothing | Desktop: enable `multipleWindows`. Mobile: popups open in the main view; use redirect flows. |
| Camera/microphone denied on Linux | Not supported yet (see LIMITATIONS.md). |
| Download did nothing on Android | `blob:`/`data:` URLs are unsupported; the server must provide an https URL. Check storage permission on Android ≤ 9. |
| Offline page does not appear on a bad certificate | TLS errors are shown by the WebView and are never bypassed. |
| `scripts/validate.sh` reports stale files | Run `bash scripts/sync-config.sh`. |
| Setup failed halfway | Nothing changed (automatic rollback). A copy of the previous state is in `.web2app-backup/`. |
