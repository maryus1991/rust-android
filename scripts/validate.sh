#!/usr/bin/env bash
# Validates config/*.json and generated files. Exit code 0 = valid.
# Usage: bash scripts/validate.sh [--quiet] [--config-only]
#   --config-only  skip the generated-file consistency checks (used by setup before it regenerates them)
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_jq

QUIET=0; CONFIG_ONLY=0
for a in "$@"; do case "$a" in --quiet) QUIET=1 ;; --config-only) CONFIG_ONLY=1 ;; esac; done
ERRORS=()
fail() { ERRORS+=("$1"); }

for f in "$APP_JSON" "$PLATFORMS_JSON" "$FEATURES_JSON"; do
  jq -e . "$f" >/dev/null 2>&1 || fail "$(basename "$f") is not valid JSON"
done
[ ${#ERRORS[@]} -eq 0 ] || { printf '%s\n' "${ERRORS[@]}" | while read -r e; do err "$e"; done; exit 1; }

# Everything below runs one jq program that prints one error per line.
JQ_ERRORS="$(jq -r --slurpfile reg "$FEATURES_JSON" '
  def hex: test("^#[0-9a-fA-F]{6}$");
  def host: test("^(\\*\\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*(:[0-9]{1,5})?$"; "i");
  def blocked: ["javascript","data","file","content","intent","ftp","view-source","vbscript","ms-msdt"];
  [
    (if ((.app.name // "") | gsub("\\s";"") | length) == 0 then "app.name must not be empty" else empty end),
    (if ((.app.identifier // "") | test("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")) | not then "app.identifier must look like com.company.app (letters/digits/underscore, each part starts with a letter)" else empty end),
    (if ((.app.version // "") | test("^[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.-]+)?$")) | not then "app.version must be semantic (e.g. 1.0.0)" else empty end),
    (if ((.site.url // "") | test("^https://[^/@\\s]+(/.*)?$")) or (((.security.httpsOnly | if . == null then true else . end) | not) and ((.site.url // "") | test("^http://[^/@\\s]+(/.*)?$"))) then empty else "site.url must be an https URL without credentials (http only if security.httpsOnly=false)" end),
    ((.site.allowedDomains // [])[] | select((host | not) or (startswith("*.") and ((.[2:] | split(":")[0] | contains(".")) | not))) | "site.allowedDomains: invalid entry \"\(.)\" (use host, *.host or host:port; no scheme/path)"),
    (.appearance | to_entries[] | select(.key | test("Color$")) | select(.value | hex | not) | "appearance.\(.key) must be #RRGGBB"),
    (if ([.platforms[]] | any) then empty else "enable at least one platform in platforms" end),
    (.platforms | to_entries[] | select(.value | type != "boolean") | "platforms.\(.key) must be true/false"),
    (.features | to_entries[] | . as $f
      | ($reg[0].features[$f.key]) as $r
      | if $r == null then "unknown feature \"\($f.key)\""
        elif ($f.value | type) != "boolean" then "features.\($f.key) must be true/false"
        elif ($f.value and $r.status == "planned") then "feature \"\($f.key)\" is not implemented yet (planned) and cannot be enabled"
        elif ($f.value and ($r.toggle | not)) then "feature \"\($f.key)\" cannot be toggled (it is derived)"
        else empty end),
    ((.security.outOfScopeLinks // "system-browser") as $o | if ($o == "system-browser" or $o == "block") then empty else "security.outOfScopeLinks must be system-browser or block" end),
    ((((.security.externalSchemes // []) + (.security.paymentSchemes // []))[] | select((test("^[a-z][a-z0-9+.-]*$") | not) or (. as $s | blocked | index($s))) | "security scheme \"\(.)\" is invalid or always blocked")),
    ((.behavior.loadTimeoutSecs // 20) as $t | if ($t >= 5 and $t <= 120) then empty else "behavior.loadTimeoutSecs must be 5..120" end),
    ((.behavior.hangTimeoutSecs // 120) as $t | if ($t >= 30 and $t <= 3600) then empty else "behavior.hangTimeoutSecs must be 30..3600" end),
    ((.release.mode // "both") as $m | if (["both","branch","tag"] | index($m)) then empty else "release.mode must be both, branch or tag" end)
  ] | .[]' "$APP_JSON")" || fail "config/app.json has an unexpected structure"
while IFS= read -r line; do [ -n "$line" ] && fail "$line"; done <<<"$JQ_ERRORS"

# Icon + logo files
ICON="$W2A_ROOT/$(jq -r '.appearance.iconSource' "$APP_JSON")"
case "$(image_kind "$ICON")" in
  png)
    if size="$(png_size "$ICON")"; then
      read -r w h <<<"$size"
      [ "$w" -eq "$h" ] || fail "icon must be square (found ${w}x${h}): $ICON"
      [ "$w" -ge 512 ] || fail "icon must be at least 512x512 (found ${w}x${h}); 1024x1024 recommended"
    else fail "icon PNG is corrupt: $ICON"; fi ;;
  svg) : ;;
  jpeg) fail "JPEG icons must be converted first; run scripts/setup.sh (needs ImageMagick) or supply PNG/SVG: $ICON" ;;
  missing) fail "icon file not found: $ICON" ;;
  *) fail "icon is not a valid PNG or SVG: $ICON" ;;
esac

if [ "$CONFIG_ONLY" -eq 0 ]; then
# Required Tauri / plugin files that CI relies on
for f in src-tauri/tauri.conf.json src-tauri/Cargo.toml src-tauri/capabilities/local.json src-tauri/capabilities/remote.json ui/offline.html ui/error.html; do
  [ -f "$W2A_ROOT/$f" ] || fail "missing required file: $f"
done
if [ -f "$W2A_ROOT/src-tauri/tauri.conf.json" ]; then
  want_id="$(jq -r '.app.identifier' "$APP_JSON")"; have_id="$(jq -r '.identifier' "$W2A_ROOT/src-tauri/tauri.conf.json")"
  want_v="$(jq -r '.app.version' "$APP_JSON")"; have_v="$(jq -r '.version' "$W2A_ROOT/src-tauri/tauri.conf.json")"
  [ "$want_id" = "$have_id" ] || fail "src-tauri/tauri.conf.json identifier is out of date ($have_id != $want_id) - run: bash scripts/sync-config.sh"
  [ "$want_v" = "$have_v" ] || fail "src-tauri/tauri.conf.json version is out of date ($have_v != $want_v) - run: bash scripts/sync-config.sh"
fi

fi

# No secrets in committed config
if grep -RIlE '(KEYSTORE_PASSWORD|KEY_PASSWORD|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|BEGIN CERTIFICATE)' "$W2A_ROOT/config" 2>/dev/null | grep -q .; then
  fail "config/ must not contain secrets (keystore/certificate material found)"
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
  for e in "${ERRORS[@]}"; do err "$e"; done
  exit 1
fi
[ "$QUIET" -eq 1 ] || ok "configuration is valid ($(jq -r '.app.name + " " + .app.version + " -> " + .site.url' "$APP_JSON"))"
