#!/usr/bin/env bash
# Tests for the configuration, setup wizard and CI helper scripts (no network, no Rust needed).
# Rust unit tests run separately: cargo test --workspace   (RUN_CARGO=1 adds them here).
#   bash tests/run-all.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; FAILED=()

# Tests must behave identically on a laptop and inside GitHub Actions: never inherit the runner's
# GITHUB_* variables (prepare.sh would write to $GITHUB_OUTPUT instead of the test's own file).
for v in $(env | sed -n 's/^\(GITHUB_[A-Z_]*\)=.*/\1/p') CI RUNNER_TEMP W2A_RELEASE_EXISTS INPUT_PUBLISH INPUT_OVERWRITE; do unset "$v"; done

# Required tools: fail loudly (never skip silently) when one is missing.
MISSING=()
for tool in jq python3 convert tar timeout; do command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "tests/run-all.sh needs: ${MISSING[*]} (Debian/Ubuntu: sudo apt install jq python3 imagemagick)" >&2
  exit 2
fi
# shellcheck source=../scripts/lib/common.sh
. "$ROOT/scripts/lib/common.sh"

t() { # t "name" command...
  local name="$1"; shift
  if ( set -e; "$@" ) >/tmp/w2a-test.out 2>&1; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$name"
  else FAIL=$((FAIL+1)); FAILED+=("$name"); printf 'FAIL  %s\n' "$name"; sed 's/^/      /' /tmp/w2a-test.out | tail -12; fi
}
no() { if "$@"; then echo "unexpectedly succeeded: $*" >&2; return 1; fi; }
expect_fail() { if "$@" >/dev/null 2>&1; then echo "expected failure but command succeeded: $*" >&2; return 1; fi; }

# Fresh copy of the repo (without build output) in a temp dir; echoes the path.
fresh_repo() {
  local d; d="$(mktemp -d)"
  ( cd "$ROOT" && tar --exclude=./target --exclude=./.git --exclude=./.web2app-backup --exclude=./node_modules -cf - . ) | tar -xf - -C "$d"
  echo "$d"
}
setup_in() { local d="$1"; shift; ( cd "$d" && timeout 120 bash scripts/setup.sh --non-interactive --skip-icons "$@" </dev/null ); }

TMPS=()
cleanup() { for d in "${TMPS[@]+"${TMPS[@]}"}"; do rm -rf "$d"; done; }
trap cleanup EXIT
# Every test repo starts from the pristine fixture (tests/fixtures/app.json), never from the user's own
# config/app.json, and its derived files are regenerated so the copy is internally consistent.
new_repo() {
  local d; d="$(fresh_repo)"; TMPS+=("$d")
  cp "$ROOT/tests/fixtures/app.json" "$d/config/app.json"
  ( cd "$d" && bash scripts/sync-config.sh >/dev/null )
  echo "$d"
}
# mkpng WIDTH HEIGHT FILE: writes a valid solid-color PNG with no external tools.
mkpng() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, zlib, struct
w, h, path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
def chunk(t, d): c = struct.pack(">I", len(d)) + t + d; return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
raw = b"".join(b"\x00" + b"\xff\x88\x00" * w for _ in range(h))
open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
}
# valid_plist FILE: parses with Python's plistlib (a real plist parser) and prints the dict as JSON.
valid_plist() { python3 -c 'import plistlib,sys,json; print(json.dumps(plistlib.load(open(sys.argv[1],"rb"))))' "$1"; }

# ---------------------------------------------------------------- validation
test_default_config_valid() { bash "$ROOT/scripts/validate.sh" --quiet; }
test_json_files_parse() { for f in "$ROOT"/config/*.json "$ROOT"/src-tauri/tauri.conf.json "$ROOT"/src-tauri/capabilities/*.json; do jq -e . "$f" >/dev/null; done; }
test_validate_rejects() { # each bad value must fail validation
  local d kv; d="$(new_repo)"
  for kv in 'site.url="http://x.com"' 'site.url="https://user:pw@x.com"' 'app.identifier="bad id"' 'app.version="1.0"' 'appearance.primaryColor="red"' \
            'features.biometric=true' 'features.nope=true' 'site.allowedDomains=["https://x.com"]' 'site.allowedDomains=["*.com"]' \
            'security.externalSchemes=["javascript"]' 'security.outOfScopeLinks="allow"' 'behavior.loadTimeoutSecs=1' 'release.mode="sometimes"' \
            'platforms={"windows":false,"linux":false,"android":false,"ios":false}'; do
    ( cd "$d" && jq ".${kv%%=*} = ${kv#*=}" config/app.json >/tmp/w2a-bad.json && cp /tmp/w2a-bad.json config/app.json && expect_fail bash scripts/validate.sh --quiet --config-only ) || { echo "not rejected: $kv"; return 1; }
    ( cd "$d" && cp "$ROOT/config/app.json" config/app.json )
  done
}
test_validate_icon_checks() {
  local d; d="$(new_repo)"
  ( cd "$d" && mkpng 300 200 assets/icon/icon.png && expect_fail bash scripts/validate.sh --quiet --config-only )
  ( cd "$d" && mkpng 600 600 assets/icon/icon.png && bash scripts/validate.sh --quiet --config-only )
  ( cd "$d" && echo "not an image" > assets/icon/icon.png && expect_fail bash scripts/validate.sh --quiet --config-only )
}
test_validate_detects_stale_generated_files() {
  local d; d="$(new_repo)"
  ( cd "$d" && jq '.identifier="com.other.stale"' src-tauri/tauri.conf.json >/tmp/w2a-c.json && cp /tmp/w2a-c.json src-tauri/tauri.conf.json && expect_fail bash scripts/validate.sh --quiet )
}
test_secrets_not_allowed_in_config() {
  local d; d="$(new_repo)"
  ( cd "$d" && echo '{"x":"ANDROID_KEYSTORE_PASSWORD=hunter2"}' > config/leak.json && expect_fail bash scripts/validate.sh --quiet --config-only )
}

# ---------------------------------------------------------------- setup wizard
test_setup_applies_values_and_generates() {
  local d; d="$(new_repo)"
  mkpng 1200 1200 "$d/new-icon.png"
  setup_in "$d" --icon "$d/new-icon.png" --set site.url=https://shop.mydomain.ir --set app.name="My Shop" --set app.identifier=ir.mydomain.shop \
    --set features.camera=true --set features.geolocation=true --set 'site.allowedDomains=["login.mydomain.ir"]'
  cd "$d"
  [ "$(jq -r .site.domain config/app.json)" = shop.mydomain.ir ]
  [ "$(jq -r .identifier src-tauri/tauri.conf.json)" = ir.mydomain.shop ]
  [ "$(jq -r .productName src-tauri/tauri.conf.json)" = "My Shop" ]
  grep -q 'android.permission.CAMERA' plugins/web2app-native/android/src/main/AndroidManifest.xml
  grep -q 'ACCESS_FINE_LOCATION' plugins/web2app-native/android/src/main/AndroidManifest.xml
  no grep -q 'RECORD_AUDIO' plugins/web2app-native/android/src/main/AndroidManifest.xml
  grep -q NSCameraUsageDescription src-tauri/Info.ios.plist
  no grep -q NSMicrophoneUsageDescription src-tauri/Info.ios.plist
  [ -f config/setup-report.md ] && grep -q 'shop.mydomain.ir' config/setup-report.md
  [ "$(png_w assets/icon/icon.png)" = 1200 ]
}
png_w() { png_size "$1" | cut -d' ' -f1; }
test_setup_rolls_back_on_invalid_icon() {
  local d; d="$(new_repo)"; cp "$d/config/app.json" /tmp/w2a-before.json
  mkpng 300 200 "$d/bad.png"
  expect_fail setup_in "$d" --icon "$d/bad.png" --set app.name=Changed
  diff <(jq -S . /tmp/w2a-before.json) <(jq -S . "$d/config/app.json")
}
test_setup_rolls_back_on_invalid_value() {
  local d; d="$(new_repo)"; cp "$d/config/app.json" /tmp/w2a-before.json
  cp "$d/src-tauri/tauri.conf.json" /tmp/w2a-conf-before.json
  expect_fail setup_in "$d" --set features.biometric=true --set app.name=Changed
  diff <(jq -S . /tmp/w2a-before.json) <(jq -S . "$d/config/app.json")
  diff <(jq -S . /tmp/w2a-conf-before.json) <(jq -S . "$d/src-tauri/tauri.conf.json")
}
test_setup_is_idempotent() {
  local d; d="$(new_repo)"
  setup_in "$d" --set app.name="Twice"; cp "$d/config/app.json" /tmp/w2a-1.json; cp "$d/plugins/web2app-native/android/src/main/AndroidManifest.xml" /tmp/w2a-m1.xml
  setup_in "$d"
  diff <(jq -S . /tmp/w2a-1.json) <(jq -S . "$d/config/app.json")
  diff /tmp/w2a-m1.xml "$d/plugins/web2app-native/android/src/main/AndroidManifest.xml"
}
test_setup_interactive_defaults_keep_config() {
  local d; d="$(new_repo)"; yes '' | head -200 >/tmp/w2a-answers.txt
  ( cd "$d" && timeout 120 bash scripts/setup.sh --skip-icons </tmp/w2a-answers.txt )
  diff <(jq -S . "$ROOT/tests/fixtures/app.json") <(jq -S . "$d/config/app.json")
}
test_setup_interactive_answers() {
  local d; d="$(new_repo)"
  printf '%s\n' https://my-shop.example.org "My Shop" y "login.pay.example.net, *.cdn.example.org" "" \
    "My Shop App" "" 2.1.0 "Shop desc" "Ali" "ali@example.org" "(c) Ali" fa dark \
    "#112233" "#ffffff" "#112233" "#ffffff" "#ffffff" "" "" y y n y \
    y n y n y y y y y y n n system-browser "tel,mailto" both >/tmp/w2a-answers2.txt
  ( cd "$d" && timeout 120 bash scripts/setup.sh --skip-icons </tmp/w2a-answers2.txt )
  cd "$d"
  [ "$(jq -r .site.domain config/app.json)" = my-shop.example.org ]
  [ "$(jq -r .app.identifier config/app.json)" = org.example.my_shop ]
  [ "$(jq -r .app.version config/app.json)" = 2.1.0 ]
  [ "$(jq -r '.platforms.android' config/app.json)" = false ]
  [ "$(jq -r '.features.microphone' config/app.json)" = true ]
  [ "$(jq -r '.site.allowedDomains | length' config/app.json)" = 2 ]
}
test_setup_invalid_answer_reprompts() {
  local d; d="$(new_repo)"
  printf '%s\n' "not a url" "ftp://x" https://ok.example.org >/tmp/w2a-answers3.txt
  yes '' | head -200 >>/tmp/w2a-answers3.txt
  ( cd "$d" && timeout 120 bash scripts/setup.sh --skip-icons </tmp/w2a-answers3.txt >/dev/null 2>&1 )
  [ "$(jq -r .site.url "$d/config/app.json")" = https://ok.example.org ]
}
test_setup_converts_jpeg_icon() {
  local d; d="$(new_repo)"; convert -size 1024x1024 xc:blue "$d/i.jpg"
  setup_in "$d" --icon "$d/i.jpg"
  [ "$(jq -r .appearance.iconSource "$d/config/app.json")" = assets/icon/icon.png ]
}
test_setup_accepts_svg_icon() {
  local d; d="$(new_repo)"; printf '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512"><rect width="512" height="512" fill="#08f"/></svg>' >"$d/i.svg"
  setup_in "$d" --icon "$d/i.svg"
  [ "$(jq -r .appearance.iconSource "$d/config/app.json")" = assets/icon/icon.svg ]
}

# ---------------------------------------------------------------- generated files
test_manifest_only_has_enabled_permissions() {
  local d; d="$(new_repo)"; setup_in "$d" --set features.camera=false --set features.microphone=false --set features.geolocation=false --set features.notifications=false --set features.downloads=false
  local m="$d/plugins/web2app-native/android/src/main/AndroidManifest.xml"
  grep -q 'INTERNET' "$m"
  for p in CAMERA RECORD_AUDIO ACCESS_FINE_LOCATION POST_NOTIFICATIONS WRITE_EXTERNAL_STORAGE; do no grep -q "$p" "$m"; done
  python3 -c 'import sys, xml.etree.ElementTree as E; [E.parse(f) for f in sys.argv[1:]]' "$m"
  valid_plist "$d/src-tauri/Info.ios.plist" >/dev/null
  [ "$(jq -r '.plugins["web2app-native"].downloads' "$d/src-tauri/tauri.conf.json")" = false ]
}
test_xml_escaping_in_plist() {
  local d name json; d="$(new_repo)"
  name='Tom & "Jerry'"'"'s" <Café> فروشگاه ]]> &amp;'
  setup_in "$d" --set "app.name=$name" --set features.camera=true --set features.microphone=true --set features.geolocation=true
  json="$(valid_plist "$d/src-tauri/Info.ios.plist")"
  # every usage description must contain the exact, unescaped name after parsing (round trip)
  [ "$(jq -r --arg n "$name" '[.NSCameraUsageDescription, .NSMicrophoneUsageDescription, .NSLocationWhenInUseUsageDescription, .NSPhotoLibraryUsageDescription] | map(startswith($n)) | all' <<<"$json")" = true ]
  grep -q '&amp;amp;' "$d/src-tauri/Info.ios.plist"     # a literal "&amp;" in the name is escaped, not interpreted
  grep -q '&quot;Jerry&apos;s&quot;' "$d/src-tauri/Info.ios.plist"
}
test_plist_strips_xml_illegal_control_characters() {
  local d json; d="$(new_repo)"
  setup_in "$d" --set "$(printf 'app.name=Bad\001Name\037End')" --set features.camera=true
  json="$(valid_plist "$d/src-tauri/Info.ios.plist")"
  jq -e '.NSCameraUsageDescription | startswith("BadNameEnd needs")' <<<"$json" >/dev/null
}
test_plist_is_valid_for_default_and_all_features() {
  local d json; d="$(new_repo)"
  setup_in "$d" --set features.camera=true --set features.microphone=true --set features.geolocation=true
  json="$(valid_plist "$d/src-tauri/Info.ios.plist")"
  jq -e 'has("NSCameraUsageDescription") and has("NSMicrophoneUsageDescription") and has("NSLocationWhenInUseUsageDescription") and (.ITSAppUsesNonExemptEncryption == false)' <<<"$json" >/dev/null
  setup_in "$d" --set features.camera=false --set features.microphone=false --set features.geolocation=false --set features.fileUpload=false
  json="$(valid_plist "$d/src-tauri/Info.ios.plist")"
  jq -e 'keys == ["ITSAppUsesNonExemptEncryption"]' <<<"$json" >/dev/null
}
test_no_generated_dirs_touched() { ! grep -RIn 'gen/android\|gen/apple' "$ROOT"/scripts/sync-config.sh "$ROOT"/scripts/setup.sh | grep -v '^\S*:[0-9]*:#' | grep -qE '(>|cp |mv |sed -i|tee)'; }

# ---------------------------------------------------------------- feature registry consistency
test_registry_matches_implementation() {
  cd "$ROOT"
  local key status toggle
  while IFS=$'\t' read -r key status toggle; do
    if [ "$status" = planned ]; then
      if jq -e --arg k "$key" '.features | has($k)' config/app.json >/dev/null; then echo 'forbidden content found' >&2; return 1; fi
      no grep -q "\"$key\"" src-tauri/src/bridge.rs
    elif [ "$toggle" = true ]; then
      jq -e --arg k "$key" '.features | has($k)' config/app.json >/dev/null || { echo "app.json lacks $key"; return 1; }
      grep -q "\"$key\" =>" src-tauri/src/config.rs || { echo "Rust Features::is_enabled lacks $key"; return 1; }
      grep -q "\"$key\":" src-tauri/src/bridge.rs || { echo "bridge features_json lacks $key"; return 1; }
    fi
  done < <(jq -r '.features | to_entries[] | [.key,.value.status,(.value.toggle|tostring)] | @tsv' config/features.json)
  # every key in app.json is known
  jq -r '.features | keys[]' config/app.json | while read -r k; do jq -e --arg k "$k" '.features | has($k)' config/features.json >/dev/null || { echo "unknown $k"; return 1; }; done
}
test_bridge_actions_have_feature_gates() {
  cd "$ROOT"
  grep -q '"clipboard.writeText" => s(true, false, Some("clipboard"))' src-tauri/src/bridge.rs
  grep -q 'Some("notifications")' src-tauri/src/bridge.rs
  grep -q 'Some("externalApps")' src-tauri/src/bridge.rs
}
test_remote_capability_is_minimal() {
  cd "$ROOT"
  [ "$(jq -r '.local' src-tauri/capabilities/remote.json)" = false ]
  [ "$(jq -c '.permissions' src-tauri/capabilities/remote.json)" = '["allow-bridge"]' ]
  if grep -rqE 'core:default|"fs:|shell:|http:|"opener:|dialog:|clipboard-manager:' src-tauri/capabilities/; then echo 'forbidden content found' >&2; return 1; fi
  grep -q '"csp"' src-tauri/tauri.conf.json
}
test_features_doc_is_current() {
  local d; d="$(new_repo)"; ( cd "$d" && bash scripts/gen-features-doc.sh ) && diff "$ROOT/docs/FEATURES.md" "$d/docs/FEATURES.md"
}
test_remote_capability_tracks_config() {
  local d; d="$(new_repo)"
  setup_in "$d" --set site.url=https://www.shop.example.org:8443/x --set 'site.allowedDomains=["Login.Example.NET","*.cdn.example.net:443","pay.example.com:9000"]' --set features.camera=false
  [ "$(jq -c '.remote.urls' "$d/src-tauri/capabilities/remote.json")" = '["https://www.shop.example.org:8443","https://*.www.shop.example.org:8443","https://login.example.net","https://*.cdn.example.net","https://pay.example.com:9000"]' ]
}
test_no_secrets_in_repo() {
  cd "$ROOT"
  if grep -RIlE 'BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}' --exclude-dir=target --exclude-dir=.git --exclude-dir=node_modules . | grep -q .; then echo 'forbidden content found' >&2; return 1; fi
  if find . -path ./target -prune -o \( -name '*.jks' -o -name '*.keystore' -o -name '*.p12' -o -name '*.mobileprovision' \) -print | grep -q .; then echo 'forbidden content found' >&2; return 1; fi
}

# ---------------------------------------------------------------- CI decision logic
# prep <event> <ref> <release-exists> [mode]: runs prepare.sh exactly like Actions does (outputs go to the
# $GITHUB_OUTPUT file) and prints that file. Exit status = prepare.sh's.
prep() {
  local d; d="$(new_repo)"
  if [ -n "${4:-}" ]; then ( cd "$d" && jq --arg m "$4" '.release.mode=$m' config/app.json >config/app.tmp && mv config/app.tmp config/app.json ); fi
  run_prepare "$d" "$1" "$2" "$3"
}
run_prepare() { # run_prepare <repo> <event> <ref> <exists>
  local d="$1"; : >"$d/gh_output"; : >"$d/gh_summary"
  ( cd "$d" && W2A_RELEASE_EXISTS="$4" GITHUB_EVENT_NAME="$2" GITHUB_REF="$3" GITHUB_REPOSITORY=a/b \
      GITHUB_OUTPUT="$d/gh_output" GITHUB_STEP_SUMMARY="$d/gh_summary" \
      INPUT_PUBLISH="${INPUT_PUBLISH:-true}" INPUT_OVERWRITE="${INPUT_OVERWRITE:-false}" bash scripts/ci/prepare.sh ) >/dev/null || return 1
  cat "$d/gh_output"
}
val() { sed -n "s/^$1=//p"; }
# prep_with <jq-filter-on-app.json>: branch push of a modified configuration
prep_with() {
  local d; d="$(new_repo)"
  ( cd "$d" && jq "$1" config/app.json >config/app.tmp && mv config/app.tmp config/app.json && bash scripts/sync-config.sh >/dev/null )
  run_prepare "$d" push refs/heads/main false
}
test_ci_branch_push_publishes_new_version() { local o; o="$(prep push refs/heads/main false)"; [ "$(val build <<<"$o")" = true ] && [ "$(val publish <<<"$o")" = true ] && [ "$(val tag <<<"$o")" = v1.0.0 ]; }
test_ci_branch_push_skips_existing_release() { local o; o="$(prep push refs/heads/main true)"; [ "$(val build <<<"$o")" = false ] && [ "$(val publish <<<"$o")" = false ] && [ -n "$(val reason <<<"$o")" ]; }
test_ci_tag_must_match_version() { expect_fail prep push refs/tags/v9.9.9 false; }
test_ci_matching_tag_publishes() { local o; o="$(prep push refs/tags/v1.0.0 false)"; [ "$(val publish <<<"$o")" = true ]; }
test_ci_mode_tag_ignores_branch_push() { local o; o="$(prep push refs/heads/main false tag)"; [ "$(val build <<<"$o")" = false ]; }
test_ci_mode_branch_ignores_tag_push() { local o; o="$(prep push refs/tags/v1.0.0 false branch)"; [ "$(val build <<<"$o")" = false ]; }
test_ci_dispatch_existing_needs_overwrite() { expect_fail prep workflow_dispatch refs/heads/main true; INPUT_OVERWRITE=true prep workflow_dispatch refs/heads/main true >/dev/null; }
test_ci_slug_ascii_names() {
  [ "$(prep_with '.app.name="My Shop App"' | val slug)" = My-Shop-App ]
  [ "$(prep_with '.app.name="shop.v2_pro"' | val slug)" = shop.v2_pro ]
}
test_ci_slug_falls_back_for_non_latin_names() {
  # Persian / Arabic / CJK-only names have no usable ASCII: use the last package-id segment
  [ "$(prep_with '.app.name="فروشگاه من" | .app.identifier="ir.shop.mystore"' | val slug)" = mystore ]
  [ "$(prep_with '.app.name="متجر" | .app.identifier="sa.store.matjar"' | val slug)" = matjar ]
  [ "$(prep_with '.app.name="商店" | .app.identifier="cn.shop.shangdian"' | val slug)" = shangdian ]
}
test_ci_slug_keeps_ascii_part_of_mixed_names() {
  [ "$(prep_with '.app.name="فروشگاه Shop"' | val slug)" = Shop ]
  [ "$(prep_with '.app.name="Café Pro"' | val slug)" = Caf-Pro ]     # deterministic: no locale-dependent transliteration
}
test_ci_slug_is_locale_independent() {
  local a b; a="$(LC_ALL=C prep_with '.app.name="Zoë Æther"' | val slug)"; b="$(LC_ALL=C.UTF-8 prep_with '.app.name="Zoë Æther"' | val slug)"
  [ "$a" = "$b" ] && [ -n "$a" ]
}
test_ci_slug_never_empty_or_path_like() {
  local s; s="$(prep_with '.app.name="../../x/ ..  "' | val slug)"
  [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]] && [ "${s#.}" = "$s" ] && [[ "$s" != */* ]]
}
test_ci_prerelease_flag() {
  [ "$(prep_with '.app.version="2.0.0-beta.1"' | val prerelease)" = true ]
  [ "$(prep_with '.app.version="2.0.0-rc.2+build.5"' | val prerelease)" = true ]
  [ "$(prep_with '.app.version="2.0.0"' | val prerelease)" = false ]
  [ "$(prep_with '.app.version="2.0.0-beta.1"' | val tag)" = v2.0.0-beta.1 ]
}
test_ci_tag_prerelease_must_match_exact_version() {
  local d; d="$(new_repo)"; ( cd "$d" && jq '.app.version="2.0.0-beta.1"' config/app.json >config/app.tmp && mv config/app.tmp config/app.json && bash scripts/sync-config.sh >/dev/null )
  [ "$(run_prepare "$d" push refs/tags/v2.0.0-beta.1 false | val publish)" = true ]
  expect_fail run_prepare "$d" push refs/tags/v2.0.0 false
}
test_ci_outputs_go_to_github_output_file() {
  local d; d="$(new_repo)"; run_prepare "$d" push refs/heads/main false >/dev/null
  grep -q '^build=true$' "$d/gh_output" && grep -q 'Release plan' "$d/gh_summary"
}
test_ci_release_exists_detection_uses_tag_of_config_version() {
  # existing release -> nothing is built or published, with an explanation
  local o; o="$(prep push refs/heads/main true)"
  [ "$(val build <<<"$o")" = false ] && [ "$(val publish <<<"$o")" = false ] && [[ "$(val reason <<<"$o")" == *"v1.0.0 already exists"* ]]
}
test_collect_names_and_required() {
  local d; d="$(mktemp -d)"; TMPS+=("$d"); mkdir -p "$d"/b/{msi,nsis,deb,appimage}
  touch "$d"/b/msi/a.msi "$d"/b/nsis/a-setup.exe "$d"/b/deb/a.deb "$d"/b/appimage/a.AppImage
  ( cd "$d" && BUNDLE_DIR=b bash "$ROOT/scripts/ci/collect.sh" windows My-App 1.2.3 msi,nsis && BUNDLE_DIR=b bash "$ROOT/scripts/ci/collect.sh" linux My-App 1.2.3 deb,appimage,rpm )
  for f in My-App-v1.2.3-windows-x64.msi My-App-v1.2.3-windows-x64-setup.exe My-App-v1.2.3-linux-x64.deb My-App-v1.2.3-linux-x64.AppImage; do [ -f "$d/dist/$f" ]; done
  rm "$d"/b/deb/a.deb; ( cd "$d" && BUNDLE_DIR=b expect_fail bash "$ROOT/scripts/ci/collect.sh" linux My-App 1.2.3 deb,appimage )
}
test_android_testsign_requires_no_secrets_path() {
  command -v keytool >/dev/null || return 0
  cd "$ROOT"; bash -n scripts/ci/android-sign.sh; grep -q 'testsign' scripts/ci/android-sign.sh; grep -q 'AAB.*not published' scripts/ci/android-sign.sh
}
test_workflows_use_least_privilege() {
  cd "$ROOT"
  grep -q '^permissions:' .github/workflows/release.yml
  [ "$(grep -c 'contents: write' .github/workflows/release.yml)" = 1 ]   # only the release job
  no grep -q 'pull_request_target' .github/workflows/*.yml
  if grep -E 'run:.*\$\{\{ *(github\.event|needs\.prepare\.outputs\.name)' .github/workflows/*.yml; then echo 'forbidden content found' >&2; return 1; fi
}

for fn in $(declare -F | awk '{print $3}' | grep '^test_'); do t "${fn#test_}" "$fn"; done

if [ "${RUN_CARGO:-0}" = 1 ]; then t "cargo test (rust unit tests)" bash -c "cd '$ROOT' && cargo test --locked --workspace --lib"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
