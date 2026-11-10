#!/usr/bin/env bash
# CI "prepare" step: reads config/app.json and decides WHAT to build/publish.
# Pure decision logic (no builds). Writes key=value lines to $GITHUB_OUTPUT (or stdout when run locally).
#
# Inputs (env): GITHUB_EVENT_NAME GITHUB_REF GITHUB_REF_NAME GITHUB_REPOSITORY GH_TOKEN
#               INPUT_PUBLISH INPUT_OVERWRITE (workflow_dispatch)  W2A_RELEASE_EXISTS (test hook: true|false)
set -euo pipefail
# shellcheck source=../lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_jq
bash "$W2A_ROOT/scripts/validate.sh" --quiet

OUT="${GITHUB_OUTPUT:-/dev/stdout}"
out() { printf '%s=%s\n' "$1" "$2" >>"$OUT"; }

NAME="$(jq -r '.app.name' "$APP_JSON")"
VERSION="$(jq -r '.app.version' "$APP_JSON")"
IDENT="$(jq -r '.app.identifier' "$APP_JSON")"
MODE="$(jq -r '.release.mode // "both"' "$APP_JSON")"
TAG="v$VERSION"

# File-name slug: ASCII letters/digits/._- only; falls back to the last identifier segment (e.g. non-Latin names).
SLUG="$(printf '%s' "$NAME" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr -c 'A-Za-z0-9._\n' '-' | sed -E 's/-+/-/g; s/^-+//; s/-+$//' || true)"
[ -n "$SLUG" ] || SLUG="${IDENT##*.}"

EVENT="${GITHUB_EVENT_NAME:-push}"
REF="${GITHUB_REF:-refs/heads/main}"
BUILD=true; PUBLISH=false; OVERWRITE=false; REASON=""

release_exists() {
  if [ -n "${W2A_RELEASE_EXISTS:-}" ]; then [ "$W2A_RELEASE_EXISTS" = true ]; return; fi
  gh release view "$TAG" --repo "${GITHUB_REPOSITORY:?}" >/dev/null 2>&1
}

case "$EVENT" in
  push)
    if [[ "$REF" == refs/tags/* ]]; then
      PUSHED="${REF#refs/tags/}"
      if [ "$PUSHED" != "$TAG" ]; then
        err "Tag $PUSHED does not match config/app.json version ($VERSION). Expected tag: $TAG."
        err "Either re-tag as $TAG or change app.version and run scripts/setup.sh --non-interactive."
        exit 1
      fi
      if [ "$MODE" = branch ]; then BUILD=false; REASON="release.mode is 'branch': tag pushes do not publish."
      elif release_exists; then BUILD=false; REASON="Release $TAG already exists. Delete it or run the workflow manually with overwrite=true."
      else PUBLISH=true; fi
    else
      if [ "$MODE" = tag ]; then BUILD=false; REASON="release.mode is 'tag': push a $TAG tag to build and publish."
      elif release_exists; then BUILD=false; REASON="Release $TAG already exists. Bump app.version in config/app.json (bash scripts/setup.sh --non-interactive --set app.version=X.Y.Z) or run the workflow manually with overwrite=true."
      else PUBLISH=true; fi
    fi ;;
  workflow_dispatch)
    PUBLISH="${INPUT_PUBLISH:-true}"; OVERWRITE="${INPUT_OVERWRITE:-false}"
    if [ "$PUBLISH" = true ] && [ "$OVERWRITE" != true ] && release_exists; then
      err "Release $TAG already exists. Re-run with overwrite=true, or bump the version."
      exit 1
    fi ;;
  *) PUBLISH=false ;;
esac

out name "$NAME"; out slug "$SLUG"; out version "$VERSION"; out tag "$TAG"
out prerelease "$([[ "$VERSION" == *-* ]] && echo true || echo false)"
out build "$BUILD"; out publish "$PUBLISH"; out overwrite "$OVERWRITE"; out reason "$REASON"
for p in windows linux android ios; do out "$p" "$(jq -r ".platforms.$p" "$APP_JSON")"; done
out windows_bundles "$(jq -r '.windows.bundles | join(",")' "$PLATFORMS_JSON")"
out linux_bundles "$(jq -r '.linux.bundles | join(",")' "$PLATFORMS_JSON")"
out android_abis "$(jq -r '.android.abis | join(" ")' "$PLATFORMS_JSON")"
out ios_method "$(jq -r '.ios.exportMethod' "$PLATFORMS_JSON")"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Release plan"
    echo "- App: **$NAME** $VERSION (tag \`$TAG\`)"
    echo "- Event: \`$EVENT\`, release.mode: \`$MODE\`"
    echo "- Build: **$BUILD**, Publish: **$PUBLISH**"
    [ -z "$REASON" ] || echo "- Note: $REASON"
  } >>"$GITHUB_STEP_SUMMARY"
fi
