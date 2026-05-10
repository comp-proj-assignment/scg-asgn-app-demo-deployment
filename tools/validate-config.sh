#!/usr/bin/env bash
# Validate every env folder:
#   1. kustomize build succeeds
#   2. rendered manifests pass kubectl --dry-run server-side
#   3. settings.yml + static.yml together cover the schema declared in
#      the app repo (apps/<service>/config.schema.yaml)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_REPO_PATH="${APP_REPO_PATH:-${REPO_ROOT}/../comp-proj-app-demo}"

fail=0

for kfile in "${REPO_ROOT}"/apps/*/envs/*/kustomization.yaml; do
  envdir=$(dirname "$kfile")
  rel=${envdir#${REPO_ROOT}/}
  echo "== ${rel} =="

  if ! kustomize build "$envdir" >/tmp/manifests.yaml; then
    echo "  ✗ kustomize build failed" >&2
    fail=1
    continue
  fi

  if command -v kubectl >/dev/null && [[ -n "${VALIDATE_DRY_RUN:-}" ]]; then
    if ! kubectl apply --dry-run=server -f /tmp/manifests.yaml >/dev/null; then
      echo "  ✗ kubectl dry-run failed" >&2
      fail=1
    fi
  fi

  service=$(echo "$rel" | awk -F/ '{print $2}')
  schema="${APP_REPO_PATH}/apps/${service}/config.schema.yaml"
  if [[ -f "$schema" ]] && command -v yq >/dev/null; then
    settings="${envdir}/settings.yml"
    static="${envdir}/static.yml"
    missing=$(yq '.required[]' "$schema" \
      | while read -r key; do
          if ! { yq ".${key}" "$settings" 2>/dev/null | grep -qv null \
              || yq ".${key}" "$static" 2>/dev/null | grep -qv null; }; then
            echo "$key"
          fi
        done)
    if [[ -n "$missing" ]]; then
      echo "  ✗ missing required keys:" >&2
      echo "$missing" | sed 's/^/    - /' >&2
      fail=1
    fi
  fi
done

exit "$fail"
