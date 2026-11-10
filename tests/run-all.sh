#!/usr/bin/env bash
# Tests for the configuration, setup wizard and CI helper scripts (no network, no Rust needed).
# Rust unit tests run separately: cargo test --workspace   (RUN_CARGO=1 adds them here).
#   bash tests/run-all.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; FAILED=()

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
new_repo() { local d; d="$(fresh_repo)"; TMPS+=("$d"); echo "$d"; }

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
  ( cd "$d" && convert -size 300x200 xc:red assets/icon/icon.png && expect_fail bash scripts/validate.sh --quiet --config-only )
  ( cd "$d" && convert -size 600x600 xc:red assets/icon/icon.png && bash scripts/validate.sh --quiet --config-only )
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
  convert -size 1200x1200 xc:'#ff8800' "$d/new-icon.png"
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
png_w() { od -An -tu1 -j19 -N1 "$1" | tr -d ' ' >/dev/null; identify -format '%w' "$1"; }
test_setup_rolls_back_on_invalid_icon() {
  local d; d="$(new_repo)"; cp "$d/config/app.json" /tmp/w2a-before.json
  convert -size 300x200 xc:red "$d/bad.png"
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
  diff <(jq -S . "$ROOT/config/app.json") <(jq -S . "$d/config/app.json")
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
  command -v convert >/dev/null || return 0
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
  xmllint --noout "$m" "$d/src-tauri/Info.ios.plist"
  [ "$(jq -r '.plugins["web2app-native"].downloads' "$d/src-tauri/tauri.conf.json")" = false ]
}
test_xml_escaping_in_plist() {
  local d; d="$(new_repo)"; setup_in "$d" --set 'app.name=A & B <x>' --set features.camera=true
  xmllint --noout "$d/src-tauri/Info.ios.plist"
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
prep() { # prep <event> <ref> <exists> [mode]
  local d; d="$(new_repo)"
  [ -n "${4:-}" ] && ( cd "$d" && jq --arg m "$4" '.release.mode=$m' config/app.json >/tmp/w2a-m.json && cp /tmp/w2a-m.json config/app.json )
  ( cd "$d" && W2A_RELEASE_EXISTS="$3" GITHUB_EVENT_NAME="$1" GITHUB_REF="$2" GITHUB_REPOSITORY=a/b INPUT_PUBLISH="${INPUT_PUBLISH:-true}" INPUT_OVERWRITE="${INPUT_OVERWRITE:-false}" bash scripts/ci/prepare.sh )
}
val() { sed -n "s/^$1=//p"; }
test_ci_branch_push_publishes_new_version() { local o; o="$(prep push refs/heads/main false)"; [ "$(val build <<<"$o")" = true ] && [ "$(val publish <<<"$o")" = true ] && [ "$(val tag <<<"$o")" = v1.0.0 ]; }
test_ci_branch_push_skips_existing_release() { local o; o="$(prep push refs/heads/main true)"; [ "$(val build <<<"$o")" = false ] && [ "$(val publish <<<"$o")" = false ] && [ -n "$(val reason <<<"$o")" ]; }
test_ci_tag_must_match_version() { expect_fail prep push refs/tags/v9.9.9 false; }
test_ci_matching_tag_publishes() { local o; o="$(prep push refs/tags/v1.0.0 false)"; [ "$(val publish <<<"$o")" = true ]; }
test_ci_mode_tag_ignores_branch_push() { local o; o="$(prep push refs/heads/main false tag)"; [ "$(val build <<<"$o")" = false ]; }
test_ci_mode_branch_ignores_tag_push() { local o; o="$(prep push refs/tags/v1.0.0 false branch)"; [ "$(val build <<<"$o")" = false ]; }
test_ci_dispatch_existing_needs_overwrite() { expect_fail prep workflow_dispatch refs/heads/main true; INPUT_OVERWRITE=true prep workflow_dispatch refs/heads/main true >/dev/null; }
test_ci_slug_falls_back_for_non_latin_names() {
  local d; d="$(new_repo)"; ( cd "$d" && jq '.app.name="فروشگاه" | .app.identifier="ir.shop.mystore"' config/app.json >/tmp/w2a-s.json && cp /tmp/w2a-s.json config/app.json && bash scripts/sync-config.sh >/dev/null \
    && W2A_RELEASE_EXISTS=false GITHUB_REPOSITORY=a/b bash scripts/ci/prepare.sh | val slug | grep -qx mystore )
}
test_ci_prerelease_flag() {
  local d o; d="$(new_repo)"; ( cd "$d" && jq '.app.version="2.0.0-beta.1"' config/app.json >/tmp/w2a-p.json && cp /tmp/w2a-p.json config/app.json && bash scripts/sync-config.sh >/dev/null && W2A_RELEASE_EXISTS=false GITHUB_REPOSITORY=a/b bash scripts/ci/prepare.sh | val prerelease | grep -qx true )
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
