#!/usr/bin/env bash
# Builds the iOS app. With Apple signing secrets -> a signed IPA. Without -> compile check only
# (no IPA is produced or advertised). Usage: ios-build.sh <slug> <version> <export-method>
# Env (mapped from repo secrets by the workflow): APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD
#   APPLE_PROVISIONING_PROFILE APPLE_TEAM_ID (APPLE_SIGNING_IDENTITY optional)
set -euo pipefail
SLUG="$1"; VERSION="$2"; METHOD="$3"
mkdir -p dist dist-status
STATUS=dist-status/ios.md; : >"$STATUS"

if [ -n "${APPLE_CERTIFICATE:-}" ] && [ -n "${APPLE_CERTIFICATE_PASSWORD:-}" ] && [ -n "${APPLE_PROVISIONING_PROFILE:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  export IOS_CERTIFICATE="$APPLE_CERTIFICATE" IOS_CERTIFICATE_PASSWORD="$APPLE_CERTIFICATE_PASSWORD" \
         IOS_MOBILE_PROVISION="$APPLE_PROVISIONING_PROFILE" APPLE_DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
  [ -z "${APPLE_SIGNING_IDENTITY:-}" ] || export APPLE_SIGNING_IDENTITY
  tauri ios build --export-method "$METHOD" --ci
  IPA="$(find src-tauri/gen/apple -type f -name '*.ipa' | head -n1 || true)"
  [ -n "$IPA" ] || { echo "::error::the iOS build finished but no IPA was found" >&2; exit 1; }
  cp "$IPA" "dist/$SLUG-v$VERSION-ios.ipa"
  {
    echo "- iOS IPA: \`$SLUG-v$VERSION-ios.ipa\` (signed, export method \`$METHOD\`)"
    [ "$METHOD" = app-store-connect ] && echo "- Upload to App Store Connect (Transporter / TestFlight)." || echo "- Install via ad-hoc/enterprise distribution: your device UDID must be in the provisioning profile."
  } >>"$STATUS"
else
  echo "::warning::Apple signing secrets are not set: verifying that the iOS app COMPILES. No IPA will be produced." >&2
  rustup target add aarch64-apple-ios
  cargo check --locked --target aarch64-apple-ios -p web2app --lib
  {
    echo "- iOS: **no IPA** - the app compiles for iOS, but an IPA cannot be installed without signing."
    echo "- Set APPLE_CERTIFICATE, APPLE_CERTIFICATE_PASSWORD, APPLE_PROVISIONING_PROFILE and APPLE_TEAM_ID (see README) to get a signed IPA."
  } >>"$STATUS"
fi
