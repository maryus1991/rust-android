# Signing secrets

Add them in **GitHub → your fork → Settings → Secrets and variables → Actions → New repository secret**. Never commit them.

## Android (APK + AAB)
| Secret | Content |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | your `.jks` keystore, base64 encoded (single line) |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | key alias |
| `ANDROID_KEY_PASSWORD` | key password |

Create everything with `bash scripts/make-android-keystore.sh` (needs a JDK; writes outside the repo and prints the values). **Back up the keystore** – losing it means you can no longer update the app on Google Play.

Without these secrets the workflow still succeeds: it publishes an APK signed with a throw-away key (`…-android-testsign.apk`, installable for testing, **not** updatable/publishable) and **no AAB**. The release notes say so.

## iOS (IPA)
| Secret | Content | Passed to Tauri as |
|---|---|---|
| `APPLE_CERTIFICATE` | Apple Distribution `.p12`, base64 | `IOS_CERTIFICATE` |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` password | `IOS_CERTIFICATE_PASSWORD` |
| `APPLE_PROVISIONING_PROFILE` | `.mobileprovision`, base64 | `IOS_MOBILE_PROVISION` |
| `APPLE_TEAM_ID` | 10-character team id | `APPLE_DEVELOPMENT_TEAM` |
| `APPLE_SIGNING_IDENTITY` | optional | `APPLE_SIGNING_IDENTITY` |

`base64 -i file | pbcopy` on macOS (`base64 -w0 file` on Linux). The export method comes from `config/platforms.json` → `ios.exportMethod` (`release-testing` = ad-hoc, `app-store-connect`, `debugging`). The bundle id of the provisioning profile must equal `app.identifier`.
Without these secrets no IPA is produced; CI only verifies that the app compiles for iOS, and says so in the release notes.
