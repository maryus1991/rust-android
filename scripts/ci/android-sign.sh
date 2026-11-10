#!/usr/bin/env bash
# Signs the Android outputs WITHOUT touching generated Gradle files.
#   APK: zipalign + apksigner      AAB: jarsigner
# With the four ANDROID_* secrets -> release-signed outputs (store ready).
# Without them -> APK signed with a throw-away key ("testsign": installable, NOT for stores/updates);
#                 the AAB is NOT published (an unsigned AAB cannot be uploaded to Google Play).
# Usage: android-sign.sh <slug> <version>
# Env: ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD ANDROID_HOME
set -euo pipefail
SLUG="$1"; VERSION="$2"
GEN="${ANDROID_GEN_DIR:-src-tauri/gen/android}"
mkdir -p dist dist-status
STATUS=dist-status/android.md; : >"$STATUS"

APK_IN="$(find "$GEN/app/build/outputs/apk" -type f -name '*.apk' | grep -i universal | head -n1 || true)"
[ -n "$APK_IN" ] || APK_IN="$(find "$GEN/app/build/outputs/apk" -type f -name '*.apk' | head -n1 || true)"
AAB_IN="$(find "$GEN/app/build/outputs/bundle" -type f -name '*.aab' 2>/dev/null | head -n1 || true)"
[ -n "$APK_IN" ] || { echo "::error::no APK was produced" >&2; exit 1; }

BT="$(find "${ANDROID_HOME:?}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n1)"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
KS="$TMP/web2app-signing.jks"

if [ -n "${ANDROID_KEYSTORE_BASE64:-}" ] && [ -n "${ANDROID_KEYSTORE_PASSWORD:-}" ] && [ -n "${ANDROID_KEY_ALIAS:-}" ] && [ -n "${ANDROID_KEY_PASSWORD:-}" ]; then
  MODE=release
  printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -d >"$KS" || { echo "::error::ANDROID_KEYSTORE_BASE64 is not valid base64" >&2; exit 1; }
  APK_OUT="$SLUG-v$VERSION-android.apk"; AAB_OUT="$SLUG-v$VERSION-android.aab"
else
  MODE=testsign
  echo "::warning::Android signing secrets are not set: producing a TEST-SIGNED APK only (throw-away key, no AAB)." >&2
  export ANDROID_KEYSTORE_PASSWORD="testsign-$RANDOM$RANDOM" ANDROID_KEY_PASSWORD
  ANDROID_KEY_PASSWORD="$ANDROID_KEYSTORE_PASSWORD"; export ANDROID_KEY_ALIAS=testsign
  keytool -genkeypair -keystore "$KS" -alias testsign -keyalg RSA -keysize 2048 -validity 3650 \
    -storepass "$ANDROID_KEYSTORE_PASSWORD" -keypass "$ANDROID_KEY_PASSWORD" -dname "CN=Web2App Test" >/dev/null 2>&1
  APK_OUT="$SLUG-v$VERSION-android-testsign.apk"; AAB_OUT=""
fi

ALIGNED="$TMP/aligned.apk"
"$BT/zipalign" -f -p 4 "$APK_IN" "$ALIGNED"
"$BT/apksigner" sign --ks "$KS" --ks-key-alias "$ANDROID_KEY_ALIAS" \
  --ks-pass env:ANDROID_KEYSTORE_PASSWORD --key-pass env:ANDROID_KEY_PASSWORD --out "dist/$APK_OUT" "$ALIGNED"
"$BT/apksigner" verify --verbose "dist/$APK_OUT" >/dev/null
echo "- Android APK: \`$APK_OUT\`" >>"$STATUS"

if [ "$MODE" = release ]; then
  if [ -n "$AAB_IN" ]; then
    cp "$AAB_IN" "dist/$AAB_OUT"
    jarsigner -keystore "$KS" -storepass:env ANDROID_KEYSTORE_PASSWORD -keypass:env ANDROID_KEY_PASSWORD \
      -sigalg SHA256withRSA -digestalg SHA-256 "dist/$AAB_OUT" "$ANDROID_KEY_ALIAS" >/dev/null
    jarsigner -verify "dist/$AAB_OUT" >/dev/null
    echo "- Android AAB: \`$AAB_OUT\` (signed, ready for Google Play upload)" >>"$STATUS"
  else
    echo "::error::no AAB was produced" >&2; exit 1
  fi
  echo "- Signing: **release key** (from repository secrets)." >>"$STATUS"
else
  {
    echo "- Signing: **TEST ONLY** - signed with a throw-away key generated in CI. It installs on devices but cannot update a previously installed build and must not be published to stores."
    echo "- Android AAB: **not published** - set the four ANDROID_* secrets (see README) to get a signed, Play-ready AAB."
  } >>"$STATUS"
fi
rm -f "$KS" "$ALIGNED"
ls -l dist
