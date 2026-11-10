#!/usr/bin/env bash
# Universal Web2App - interactive setup wizard.
#
#   bash scripts/setup.sh                      interactive (edits the existing configuration)
#   bash scripts/setup.sh --non-interactive    keep current values, apply --set/--icon/--logo, then validate + generate
#   bash scripts/setup.sh --set site.url=https://my.site --set features.camera=true --non-interactive
#
# Options:
#   --non-interactive     never prompt (values come from config/app.json, --set, --icon, --logo)
#   --set PATH=VALUE      override any config key (dotted path; VALUE may be JSON, e.g. features.camera=true)
#   --icon FILE           icon image (PNG/SVG; JPEG needs ImageMagick)
#   --logo FILE           splash/start-page logo image
#   --skip-icons          do not run the icon generator (CI regenerates icons anyway)
#   -h, --help
#
# Safety: all managed files are backed up first and restored automatically if anything fails.
# Secrets (keystore, Apple certificates, tokens) are NEVER asked for or stored here: they belong
# in GitHub Actions secrets (see README.md).
set -Eeuo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_jq
cd "$W2A_ROOT"

INTERACTIVE=1; SKIP_ICONS=0; ICON_ARG=""; LOGO_ARG=""; SETS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --non-interactive) INTERACTIVE=0 ;;
    --skip-icons) SKIP_ICONS=1 ;;
    --set) shift; [ $# -gt 0 ] || die "--set needs PATH=VALUE"; SETS+=("$1") ;;
    --icon) shift; ICON_ARG="${1:-}" ;;
    --logo) shift; LOGO_ARG="${1:-}" ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

# ------------------------------------------------------------------ backup / rollback
MANAGED=(config/app.json src-tauri/tauri.conf.json src-tauri/capabilities src-tauri/icons src-tauri/splash-logo.png
         src-tauri/Info.ios.plist plugins/web2app-native/android/src/main/AndroidManifest.xml assets/icon assets/splash config/setup-report.md)
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$W2A_ROOT/.web2app-backup/$TS"
DONE=0

backup() {
  mkdir -p "$BACKUP"
  local p
  for p in "${MANAGED[@]}"; do
    [ -e "$p" ] || continue
    mkdir -p "$BACKUP/$(dirname "$p")"
    cp -a "$p" "$BACKUP/$p"
  done
}

rollback() {
  local p
  warn "restoring the previous project state from ${BACKUP#"$W2A_ROOT"/}"
  for p in "${MANAGED[@]}"; do
    if [ -e "$BACKUP/$p" ]; then
      rm -rf "${W2A_ROOT:?}/$p"; mkdir -p "$(dirname "$p")"; cp -a "$BACKUP/$p" "$p"
    else
      rm -rf "${W2A_ROOT:?}/$p"   # did not exist before setup
    fi
  done
}

on_exit() {
  local code=$?
  if [ "$DONE" -ne 1 ]; then
    [ "$code" -ne 0 ] && err "setup failed (exit $code)."
    [ -d "$BACKUP" ] && rollback && warn "nothing was changed."
    exit "${code:-1}"
  fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM
trap 'exit 141' PIPE

# ------------------------------------------------------------------ config helpers
CFG="$(cat "$APP_JSON")"
get() { jq -r "$1 // empty" <<<"$CFG"; }
getb() { jq -r "($1) // false" <<<"$CFG"; }
set_path() { # set_path dotted.path JSON_VALUE
  [ -n "$2" ] || die "internal error: empty value for $1"
  CFG="$(jq --argjson v "$2" --arg p "$1" 'setpath($p | split("."); $v)' <<<"$CFG")"
}
set_str() { set_path "$1" "$(jq -Rn --arg s "$2" '$s')"; }
set_bool() { set_path "$1" "$2"; }

say() { printf '%s\n' "$*" >&2; }
ask() { # ask "Label" "default" -> echoes answer
  local label="$1" def="${2:-}" ans=""
  if [ "$INTERACTIVE" -eq 0 ]; then printf '%s' "$def"; return; fi
  if [ -n "$def" ]; then printf '%s [%s]: ' "$label" "$def" >&2; else printf '%s: ' "$label" >&2; fi
  IFS= read -r ans || { say; die "input ended unexpectedly (use --non-interactive for unattended runs)"; }
  printf '%s' "${ans:-$def}"
}
ask_valid() { # ask_valid "Label" "default" validator_fn "error message"
  local label="$1" def="$2" fn="$3" msg="$4" v
  while true; do
    v="$(ask "$label" "$def")"
    if "$fn" "$v"; then printf '%s' "$v"; return; fi
    [ "$INTERACTIVE" -eq 0 ] && die "$msg (value: '$v')"
    err "$msg"
  done
}
ask_yn() { # ask_yn "Label" true|false -> echoes true|false
  local label="$1" def="$2" hint ans
  [ "$def" = true ] && hint="Y/n" || hint="y/N"
  if [ "$INTERACTIVE" -eq 0 ]; then printf '%s' "$def"; return; fi
  while true; do
    printf '%s [%s]: ' "$label" "$hint" >&2
    IFS= read -r ans || die "input ended unexpectedly"
    case "$(printf '%s' "${ans:-}" | tr '[:upper:]' '[:lower:]')" in
      "") printf '%s' "$def"; return ;;
      y|yes|true|1) echo true; return ;;
      n|no|false|0) echo false; return ;;
    esac
    err "please answer y or n"
  done
}

v_nonempty() { [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }
v_ident() { [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]; }
v_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; }
v_url() { [[ "$1" =~ ^https://[^/@[:space:]]+(/.*)?$ ]] || { [ "$(jq -r '.security.httpsOnly' <<<"$CFG")" = false ] && [[ "$1" =~ ^http://[^/@[:space:]]+(/.*)?$ ]]; }; }
v_hex() { [[ "$1" =~ ^#[0-9a-fA-F]{6}$ ]]; }
v_theme() { [[ "$1" =~ ^(system|light|dark)$ ]]; }
v_links() { [[ "$1" =~ ^(system-browser|block)$ ]]; }
v_release() { [[ "$1" =~ ^(both|branch|tag)$ ]]; }
v_lang() { [[ "$1" =~ ^[a-z]{2,3}(-[A-Za-z0-9]+)?$ ]]; }
v_email() { [ -z "$1" ] || [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }

host_of() { printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/:?\#]+).*#\1#' | tr '[:upper:]' '[:lower:]'; }
suggest_identifier() {
  local h parts out="" i p
  h="$(host_of "$1")"; h="${h#www.}"
  IFS='.' read -r -a parts <<<"$h"
  for ((i=${#parts[@]}-1; i>=0; i--)); do
    p="$(printf '%s' "${parts[$i]}" | tr -c 'A-Za-z0-9' '_' | sed 's/_*$//' | tr '[:upper:]' '[:lower:]')"
    [[ "$p" =~ ^[0-9] ]] && p="a$p"
    [ -n "$p" ] && out="${out:+$out.}$p"
  done
  [[ "$out" == *.* ]] && printf '%s' "$out" || printf 'com.example.webapp'
}

# ------------------------------------------------------------------ images
expand_path() { local p="$1"; case "$p" in "~"*) p="$HOME${p#\~}" ;; esac; printf '%s' "$p"; }

import_image() { # import_image <kind icon|logo> <source>
  local kind="$1" src dst k w h
  src="$(expand_path "$2")"
  [ -f "$src" ] || { err "file not found: $src"; return 1; }
  k="$(image_kind "$src")"
  local dir="assets/icon"; [ "$kind" = logo ] && dir="assets/splash"
  local base="icon"; [ "$kind" = logo ] && base="logo"
  mkdir -p "$dir"
  case "$k" in
    png)
      if ! read -r w h <<<"$(png_size "$src")" || [ -z "${w:-}" ]; then err "corrupt PNG: $src"; return 1; fi
      if [ "$kind" = icon ]; then
        [ "$w" -eq "$h" ] || { err "the icon must be square (yours is ${w}x${h})"; return 1; }
        [ "$w" -ge 512 ] || { err "the icon must be at least 512x512 (yours is ${w}x${h}); 1024x1024 is recommended"; return 1; }
        [ "$w" -ge 1024 ] || warn "icon is ${w}px; 1024x1024 gives the sharpest result"
      fi
      rm -f "$dir/$base".svg "$dir/$base".png; cp "$src" "$dir/$base.png"; dst="$dir/$base.png" ;;
    svg)
      if [ "$kind" = logo ]; then
        if command -v convert >/dev/null 2>&1; then rm -f "$dir/$base".*; convert -background none "$src" -resize 256x256 "$dir/$base.png" 2>/dev/null || { err "could not rasterize the SVG logo"; return 1; }; dst="$dir/$base.png"
        else err "SVG logos need ImageMagick ('convert'); please supply a PNG logo"; return 1; fi
      else rm -f "$dir/$base".svg "$dir/$base".png; cp "$src" "$dir/$base.svg"; dst="$dir/$base.svg"; fi ;;
    jpeg)
      command -v convert >/dev/null 2>&1 || { err "JPEG needs ImageMagick ('convert') to be converted; supply a PNG/SVG or install ImageMagick"; return 1; }
      rm -f "$dir/$base".svg "$dir/$base".png
      convert "$src" -background none -alpha on "$dir/$base.png" 2>/dev/null || { err "could not convert the JPEG"; return 1; }
      read -r w h <<<"$(png_size "$dir/$base.png")"
      if [ "$kind" = icon ] && { [ "$w" -ne "$h" ] || [ "$w" -lt 512 ]; }; then rm -f "$dir/$base.png"; err "the icon must be square and at least 512x512 (yours is ${w}x${h})"; return 1; fi
      dst="$dir/$base.png" ;;
    *) err "unsupported or invalid image (accepted: PNG, SVG, JPEG with ImageMagick): $src"; return 1 ;;
  esac
  if [ "$kind" = icon ]; then set_str appearance.iconSource "$dst"; else set_str appearance.logoSource "$dst"; fi
  ok "$kind imported -> $dst"
}

ask_image() { # ask_image kind label arg
  local kind="$1" label="$2" arg="$3" p
  if [ -n "$arg" ]; then import_image "$kind" "$arg" || die "invalid $kind image"; return; fi
  [ "$INTERACTIVE" -eq 0 ] && return 0
  while true; do
    p="$(ask "$label (path to PNG/SVG file, Enter = keep current)" "")"
    [ -z "$p" ] && return 0
    import_image "$kind" "$p" && return 0
  done
}

# ------------------------------------------------------------------ wizard
say "${C_BLU}Universal Web2App setup${C_OFF}"
say "Answer each question; press Enter to keep the value in brackets."
[ "$INTERACTIVE" -eq 1 ] && say ""

backup
info "backup created: ${BACKUP#"$W2A_ROOT"/}"

if [ "$INTERACTIVE" -eq 1 ]; then
  say ""; say "${C_BLU}-- Website${C_OFF}"
  url="$(ask_valid "Website URL (https)" "$(get .site.url)" v_url "Enter a full https URL, e.g. https://example.com")"
  set_str site.url "$url"; set_str site.domain "$(host_of "$url")"
  set_str site.name "$(ask "Website name" "$(get .site.name)")"
  set_bool site.includeSubdomains "$(ask_yn "Allow all subdomains of $(host_of "$url") inside the app?" "$(getb .site.includeSubdomains)")"
  extra="$(ask "Additional allowed domains (comma separated, e.g. login.example.org,*.cdn.example.net; Enter = none)" "$(jq -r '.site.allowedDomains | join(",")' <<<"$CFG")")"
  if [ -n "$extra" ]; then
    arr="$(jq -Rn --arg s "$extra" '$s | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')"
  else arr='[]'; fi
  set_path site.allowedDomains "$arr"
  set_str site.userAgent "$(ask "Custom User-Agent (Enter = WebView default)" "$(get .site.userAgent)")"

  say ""; say "${C_BLU}-- Application${C_OFF}"
  set_str app.name "$(ask_valid "Application name" "$(get .app.name)" v_nonempty "The name must not be empty")"
  def_id="$(get .app.identifier)"
  if [ "$def_id" = "com.example.webapp" ] && [ "$(host_of "$url")" != "example.com" ]; then def_id="$(suggest_identifier "$url")"; fi
  set_str app.identifier "$(ask_valid "Application ID / package name" "$def_id" v_ident "Use a format like com.company.app (letters, digits, underscore; each part starts with a letter)")"
  set_str app.version "$(ask_valid "Version" "$(get .app.version)" v_semver "Use semantic versioning, e.g. 1.0.0")"
  set_str app.description "$(ask "Description" "$(get .app.description)")"
  set_str app.author.name "$(ask "Author name" "$(get .app.author.name)")"
  set_str app.author.email "$(ask_valid "Author email" "$(get .app.author.email)" v_email "Enter a valid email address")"
  set_str app.copyright "$(ask "Copyright" "$(get .app.copyright)")"
  set_str app.defaultLanguage "$(ask_valid "Default language (en, fa, ...)" "$(get .app.defaultLanguage)" v_lang "Use a language code such as en or fa")"
  set_str app.defaultTheme "$(ask_valid "Default theme (system/light/dark)" "$(get .app.defaultTheme)" v_theme "Choose system, light or dark")"

  say ""; say "${C_BLU}-- Appearance${C_OFF}"
  for k in primaryColor backgroundColor statusBarColor navigationBarColor splashColor; do
    set_str "appearance.$k" "$(ask_valid "Color: $k (#RRGGBB)" "$(get ".appearance.$k")" v_hex "Use a #RRGGBB color such as #3b82f6")"
  done
  ask_image icon "App icon" "$ICON_ARG"
  ask_image logo "Start-page / splash logo" "$LOGO_ARG"

  say ""; say "${C_BLU}-- Platforms${C_OFF}"
  for p in windows linux android ios; do set_bool "platforms.$p" "$(ask_yn "Build for $p?" "$(getb ".platforms.$p")")"; done

  say ""; say "${C_BLU}-- Features${C_OFF} (only implemented features can be enabled)"
  while IFS=$'\t' read -r -u 3 key label status toggle notes; do
    if [ "$toggle" = true ] && [ "$status" != planned ]; then
      [ "$status" = platform-limited ] && say "${C_DIM}   note: $notes${C_OFF}"
      set_bool "features.$key" "$(ask_yn "$label" "$(jq -r ".features.$key // false" <<<"$CFG")")"
    fi
  done 3< <(jq -r '.features | to_entries[] | [.key, .value.label, .value.status, (.value.toggle|tostring), .value.notes] | @tsv' "$FEATURES_JSON")
  planned="$(jq -r '.features | to_entries[] | select(.value.status=="planned") | .value.label' "$FEATURES_JSON" | paste -sd ';' - | sed 's/;/; /g')"
  say "${C_DIM}   Not available yet (planned): $planned${C_OFF}"

  say ""; say "${C_BLU}-- Security & release${C_OFF}"
  set_str security.outOfScopeLinks "$(ask_valid "Links to other websites: open in 'system-browser' or 'block'" "$(get .security.outOfScopeLinks)" v_links "Choose system-browser or block")"
  if [ "$(jq -r '.features.externalApps' <<<"$CFG")" = true ]; then
    sch="$(ask "Allowed external schemes (comma separated)" "$(jq -r '.security.externalSchemes | join(",")' <<<"$CFG")")"
    set_path security.externalSchemes "$(jq -Rn --arg s "$sch" '$s | split(",") | map(gsub("\\s";"") | ascii_downcase) | map(select(length>0))')"
  fi
  if [ "$(jq -r '.features.paymentHandoff' <<<"$CFG")" = true ]; then
    sch="$(ask "Payment app URL schemes to hand off (comma separated, e.g. upi,paytm)" "$(jq -r '.security.paymentSchemes | join(",")' <<<"$CFG")")"
    set_path security.paymentSchemes "$(jq -Rn --arg s "$sch" '$s | split(",") | map(gsub("\\s";"") | ascii_downcase) | map(select(length>0))')"
  fi
  set_str release.mode "$(ask_valid "Release mode: 'both' (push + tag), 'branch' (every push to main) or 'tag' (only v* tags)" "$(get .release.mode)" v_release "Choose both, branch or tag")"
else
  ask_image icon "" "$ICON_ARG"
  ask_image logo "" "$LOGO_ARG"
fi

# --set overrides (also in interactive mode, applied last)
for s in "${SETS[@]+"${SETS[@]}"}"; do
  [[ "$s" == *=* ]] || die "--set expects PATH=VALUE (got '$s')"
  path="${s%%=*}"; val="${s#*=}"
  if jq . >/dev/null 2>&1 <<<"$val"; then set_path "$path" "$val"; else set_str "$path" "$val"; fi
done
# keep derived fields consistent
set_str site.domain "$(host_of "$(jq -r '.site.url' <<<"$CFG")")"

# ------------------------------------------------------------------ apply
say ""; info "validating and generating files"
printf '%s\n' "$CFG" | jq '.' | atomic_write "$APP_JSON"
bash "$W2A_ROOT/scripts/validate.sh" --quiet --config-only
bash "$W2A_ROOT/scripts/sync-config.sh" >/dev/null
ok "derived configuration generated"
if [ "$SKIP_ICONS" -eq 0 ]; then bash "$W2A_ROOT/scripts/generate-icons.sh"; fi
bash "$W2A_ROOT/scripts/validate.sh" --quiet

# ------------------------------------------------------------------ report
REPORT="$W2A_ROOT/config/setup-report.md"
{
  echo "# Setup report"
  echo
  echo "_Generated by \`scripts/setup.sh\` on $(date -u +%Y-%m-%dT%H:%M:%SZ). Contains no secrets._"
  echo
  jq -r '"- **App:** \(.app.name) \(.app.version) (`\(.app.identifier)`)\n- **Website:** \(.site.url)\n- **Allowed hosts:** \(([.site.domain] + (if .site.includeSubdomains then ["*." + .site.domain] else [] end) + .site.allowedDomains) | join(", "))\n- **Platforms:** \([.platforms | to_entries[] | select(.value) | .key] | join(", "))\n- **Release mode:** \(.release.mode)\n- **Out-of-scope links:** \(.security.outOfScopeLinks)"' "$APP_JSON"
  echo
  echo "## Features"
  echo
  echo "| Feature | Enabled | Status | Notes |"
  echo "|---|---|---|---|"
  jq -r --slurpfile reg "$FEATURES_JSON" '. as $a | $reg[0].features | to_entries[] | "| \(.key) | \(if ($a.features[.key] // false) then "yes" else "no" end) | \(.value.status) | \(.value.notes) |"' "$APP_JSON"
  echo
  echo "## Signing"
  echo
  echo "Signing material is **not** part of this repository. Set GitHub secrets as described in README.md (Android: 4 secrets, iOS: 5 secrets). Without them the workflow still builds and clearly labels what it produced."
} | atomic_write "$REPORT"

DONE=1
# keep only the 5 newest backups
find "$W2A_ROOT/.web2app-backup" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | tail -n +6 | while read -r old; do rm -rf "$old"; done

say ""
ok "setup complete. Report: config/setup-report.md"
say ""
say "Next steps:"
say "  git add -A"
say "  git commit -m \"Configure application\""
say "  git push origin main"
say "Then open the Actions tab of your repository (enable workflows once if GitHub asks)."
