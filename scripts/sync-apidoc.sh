#!/usr/bin/env bash
# Copy the delivery copies in docs/ into the server package, which embeds them
# for the /docs site. internal/server/apidoc_test.go fails when the two drift.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docs=(
  open-api.md
  quickstart.md
  sdk.md
  webhook.md
  integrations.md
  groups-api.md
  api.md
  saas-onboarding.md
  platform-api.md
  changelog.md
  openapi.json
)
for name in "${docs[@]}"; do
  cp "$root/docs/$name" "$root/internal/server/apidoc/$name"
  echo "synced $name"
done
