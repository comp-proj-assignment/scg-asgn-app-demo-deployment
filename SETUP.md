# comp-proj-app-demo-deployment — Setup

GitOps deploy repo. Argo CD watches `main` and syncs every
`apps/<service>/envs/<env>/` folder. See `DEFINITION.md` for the model
and `REFERENCE.md` for the upstream articles it's based on.

## Prerequisites

- [ ] EKS cluster reachable via `kubectl` (provisioned by `comp-proj-infra`)
- [ ] `kubectl`, `kustomize`, `argocd` CLIs installed
- [ ] Images already exist at `ghcr.io/comp/api:<tag>` and `ghcr.io/comp/web:<tag>`
      and the GHCR packages are set to **Public** visibility
      (Phase 1: no `imagePullSecrets` needed; nodes pull anonymously)

## 1. Install Argo CD + Argo Rollouts in the cluster

These live cluster-side, not in this repo. One-time per cluster:

```bash
# Argo CD
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Argo Rollouts (CRDs + controller)
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f \
  https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# kubectl plugin (handy for promote/abort)
brew install argoproj/tap/kubectl-argo-rollouts
```

## 2. Log in to Argo CD

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 \
  --username admin \
  --password "$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d)"
```

## 3. Give Argo CD read access to this repo

If the repo is private:

```bash
argocd repo add https://github.com/comp/comp-proj-app-demo-deployment \
  --username <gh-user> --password <gh-pat-with-repo-scope>
```

For a public repo, skip this step.

## 4. Apply the AppProject and ApplicationSet

This is the single bootstrap action that wires up everything:

```bash
kubectl apply -f argocd/projects/comp-proj.yaml
kubectl apply -f argocd/applicationsets/all-services.yaml
```

The ApplicationSet generator scans `apps/*/envs/*` and creates
8 Argo CD Applications: `api-{dev,qa,staging,prod}`, `web-{dev,qa,staging,prod}`.
DEV/QA/STAGING auto-sync; PROD is manual-sync.

Verify:
```bash
argocd app list
# expect 8 apps; api-dev, web-dev should already be Synced/Healthy.
```

## 5. Configure CODEOWNERS teams

`.github/CODEOWNERS` references `@comp/sre-team`, `@comp/dev-team`,
`@comp/qa-team`, `@comp/release-managers`. Create them in the GitHub
org and add members. Without these, prod-overlay PRs cannot merge.

## 6. Configure GitHub branch protection

- [ ] Settings → Branches → rule for `main`:
  - Require PR + 2 reviewers for `apps/*/envs/prod/`,
    `apps/*/base/`, `apps/*/variants/` (CODEOWNERS does this if enforced)
  - Require status check `validate-sync` to pass
  - No force push, no direct push

## 7. Add CI secrets

- [ ] `APP_REPO_READ_TOKEN` — PAT with read access to `comp/comp-proj-app-demo`
      (used by `validate-sync.yml` to cross-check the config schema)
- [ ] `GITHUB_TOKEN` — provided automatically; just ensure
      Settings → Actions → Workflow permissions allows
      "Read and write" + PR creation

## 8. Smoke test the promotion path

Once images exist and DEV is Healthy, walk one promotion through:

```bash
# Bump the QA tag (normally CI does this on release-cut)
sed -i '' 's|api:abc1234|api:v3.3.0-rc1|' apps/api/envs/qa/version.yml
git commit -am "qa: api v3.3.0-rc1" && git push

# Wait for QA to be Synced/Healthy
argocd app wait api-qa --health

# Promote QA → STAGING
./tools/promote-to-staging.sh api

# Wait for STAGING soak (24h in real life — for the smoke test, skip)
gh workflow run promote-prod.yml -f service=api -f version=v3.3.0-rc1
# Approve the PR, then in Argo CD UI: api-prod → Sync
```

## You're done when

- [ ] `argocd app list` shows 8 apps, all Synced/Healthy
- [ ] A change to `apps/api/envs/dev/settings.yml` produces a new
      hash-suffixed ConfigMap and triggers a fast canary in DEV
      (visible in Argo Rollouts UI)
- [ ] A change to `apps/api/envs/staging/settings.yml` produces a
      full canary with analysis steps (5%→25%→50%→100%)
- [ ] PROD only syncs after a human clicks Sync in the UI

## When something is wrong

See the **Troubleshooting** section in `DEFINITION.md` — covers the
three most common failure modes (stuck Progressing, ConfigMap change
not triggering rollout, promotion race conditions).
