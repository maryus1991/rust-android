#!/usr/bin/env bash
# Regenerates docs/FEATURES.md from config/features.json (the single source of truth).
set -euo pipefail
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_jq
{
  echo "# Features and platform support"
  echo
  echo "_Generated from \`config/features.json\` by \`scripts/gen-features-doc.sh\`. Do not edit by hand._"
  echo
  echo "Status meanings:"
  echo
  jq -r '.statuses | to_entries[] | "- **\(.key)** - \(.value)"' "$FEATURES_JSON"
  echo
  echo "Only features with status \`implemented\` or \`platform-limited\` can be enabled; \`planned\` features are rejected by the setup wizard, \`scripts/validate.sh\` and the app itself."
  echo
  echo "| Feature (config key) | Status | Toggle | Platforms | Notes |"
  echo "|---|---|---|---|---|"
  jq -r '.features | to_entries[] | "| \(.value.label) (`\(.key)`) | \(.value.status) | \(if .value.toggle then "yes" else "no" end) | \(if (.value.platforms|length)==0 then "-" else (.value.platforms|join(", ")) end) | \(.value.notes) |"' "$FEATURES_JSON"
} >"$W2A_ROOT/docs/FEATURES.md"
