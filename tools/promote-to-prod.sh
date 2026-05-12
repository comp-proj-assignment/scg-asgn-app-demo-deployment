#!/usr/bin/env bash
# Promote a service's image from STAGING → PROD by copying version.yml.
# Opens a PR; merge requires 2 approvers (CODEOWNERS).
# Usage: tools/promote-to-prod.sh <service> <version>
set -euo pipefail

SERVICE="${1:?service name required (e.g. backend, frontend)}"
VERSION="${2:?semver tag required (e.g. v3.3.0)}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${REPO_ROOT}/apps/${SERVICE}/envs/staging/version.yml"
DST="${REPO_ROOT}/apps/${SERVICE}/envs/prod/version.yml"

[[ -f "$SRC" ]] || { echo "missing: $SRC" >&2; exit 1; }
[[ -f "$DST" ]] || { echo "missing: $DST" >&2; exit 1; }

# Sanity: the staging tag should match the requested version.
STG_IMAGE=$(grep -E '^\s*value:' "$SRC" | head -n1 | awk '{print $2}')
case "$STG_IMAGE" in
  *":${VERSION}"*) ;;
  *)
    echo "STAGING is on ${STG_IMAGE} but you asked to promote ${VERSION}." >&2
    echo "Either update STAGING first or pass the matching version." >&2
    exit 2
    ;;
esac

BRANCH="release/${SERVICE}/${VERSION}-prod"
git -C "$REPO_ROOT" checkout -b "$BRANCH"

cp "$SRC" "$DST"
git -C "$REPO_ROOT" add "apps/${SERVICE}/envs/prod/version.yml"
git -C "$REPO_ROOT" commit -m "promote(${SERVICE}): STAGING → PROD ${VERSION}"
git -C "$REPO_ROOT" push --set-upstream origin "$BRANCH"

gh pr create \
  --title "promote(${SERVICE}): PROD ${VERSION}" \
  --body "Promote ${SERVICE} ${VERSION} from STAGING to PROD. Soak verified ≥24h. Argo CD will detect the change but PROD is manual-sync — release manager will sync via UI after merge." \
  --label promotion,prod \
  --base main \
  --head "$BRANCH"
