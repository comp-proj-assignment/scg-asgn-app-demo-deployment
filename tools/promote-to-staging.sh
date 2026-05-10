#!/usr/bin/env bash
# Promote a service's image from QA → STAGING by copying version.yml.
# Usage: tools/promote-to-staging.sh <service>
set -euo pipefail

SERVICE="${1:?service name required (e.g. api, web)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/apps/${SERVICE}/envs/qa/version.yml"
DST="${REPO_ROOT}/apps/${SERVICE}/envs/staging/version.yml"

[[ -f "$SRC" ]] || { echo "missing: $SRC" >&2; exit 1; }
[[ -f "$DST" ]] || { echo "missing: $DST" >&2; exit 1; }

if cmp -s "$SRC" "$DST"; then
  echo "${SERVICE}: STAGING already at QA version, nothing to do."
  exit 0
fi

QA_IMAGE=$(grep -E '^\s*value:' "$SRC" | head -n1 | awk '{print $2}')
echo "Promoting ${SERVICE} QA → STAGING: ${QA_IMAGE}"
cp "$SRC" "$DST"

git -C "$REPO_ROOT" add "apps/${SERVICE}/envs/staging/version.yml"
git -C "$REPO_ROOT" commit -m "promote(${SERVICE}): QA → STAGING ${QA_IMAGE}"
git -C "$REPO_ROOT" push
