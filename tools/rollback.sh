#!/usr/bin/env bash
# Roll a service's env back to the previous version.yml on main.
# Usage: tools/rollback.sh <service> <env>
set -euo pipefail

SERVICE="${1:?service required}"
ENV="${2:?env required (dev|qa|staging|prod)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="apps/${SERVICE}/envs/${ENV}/version.yml"

[[ -f "${REPO_ROOT}/${FILE}" ]] || { echo "missing: ${FILE}" >&2; exit 1; }

PREV_SHA=$(git -C "$REPO_ROOT" log -n 2 --pretty=format:%H -- "$FILE" | tail -n 1)
[[ -n "$PREV_SHA" ]] || { echo "no prior revision of ${FILE}" >&2; exit 1; }

PREV_IMAGE=$(git -C "$REPO_ROOT" show "${PREV_SHA}:${FILE}" \
  | grep -E '^\s*value:' | head -n1 | awk '{print $2}')

echo "Rolling ${SERVICE}/${ENV} back to ${PREV_IMAGE} (from ${PREV_SHA})"

if [[ "$ENV" == "prod" ]]; then
  BRANCH="rollback/${SERVICE}/${ENV}-$(date +%s)"
  git -C "$REPO_ROOT" checkout -b "$BRANCH"
  git -C "$REPO_ROOT" checkout "$PREV_SHA" -- "$FILE"
  git -C "$REPO_ROOT" commit -m "rollback(${SERVICE}/${ENV}): ${PREV_IMAGE}"
  git -C "$REPO_ROOT" push --set-upstream origin "$BRANCH"
  gh pr create --title "rollback(${SERVICE}/${ENV}): ${PREV_IMAGE}" \
    --body "Emergency rollback. Manual Argo CD sync required after merge." \
    --label rollback,prod --base main --head "$BRANCH"
else
  git -C "$REPO_ROOT" checkout "$PREV_SHA" -- "$FILE"
  git -C "$REPO_ROOT" commit -m "rollback(${SERVICE}/${ENV}): ${PREV_IMAGE}"
  git -C "$REPO_ROOT" push
fi
