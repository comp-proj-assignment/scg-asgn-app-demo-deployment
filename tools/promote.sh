#!/usr/bin/env bash
# Usage: tools/promote.sh <service> <from_env> <to_env>
# Copies <service>/envs/<from_env>/version.yml → <to_env>/version.yml.
# Stages the change; you commit + push (or open a PR for uat/preprod/prod).
set -euo pipefail
SERVICE="${1:?service required (backend|frontend)}"
FROM="${2:?from env required (dev|sit|uat|preprod)}"
TO="${3:?to env required (sit|uat|preprod|prod)}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="${REPO_ROOT}/apps/${SERVICE}/envs/${FROM}/version.yml"
DST="${REPO_ROOT}/apps/${SERVICE}/envs/${TO}/version.yml"
[ -f "$SRC" ] || { echo "missing: $SRC" >&2; exit 1; }
[ -f "$DST" ] || { echo "missing: $DST" >&2; exit 1; }
TAG="$(yq '.[0].value' "$SRC")"
yq -i ".[0].value = \"$TAG\"" "$DST"
git -C "$REPO_ROOT" add "apps/${SERVICE}/envs/${TO}/version.yml"
echo "✓ ${SERVICE}: ${FROM} → ${TO} = ${TAG}"
echo "  next: git commit + push (or open a PR for uat/preprod/prod)"
