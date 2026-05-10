# comp-proj-app-demo-deployment

GitOps deployment repository for `comp-proj-app-demo`. Contains Kustomize
manifests, Argo CD applications, and promotion workflows. Argo CD watches
this repo and syncs changes to Kubernetes clusters.

## What This Repo Contains

```
comp-proj-app-demo-deployment/
├── apps/
│   ├── api/                          # Spring Boot service
│   │   ├── base/                     # Shared K8s manifests (all envs)
│   │   │   ├── rollout.yaml          # Argo Rollouts (canary/blue-green)
│   │   │   ├── service.yaml
│   │   │   ├── pdb.yaml
│   │   │   └── kustomization.yaml    # rollout-transform configurations
│   │   ├── variants/                 # Reusable mixins (composed by envs)
│   │   │   ├── non-prod/             # env-class label (dev/qa/staging)
│   │   │   ├── prod/                 # prod sizing + label + PDB
│   │   │   ├── canary-fast/          # 50%→100%, no analysis (dev/qa)
│   │   │   ├── high-traffic/         # HPA + tighter PDB (prod)
│   │   │   └── strategy-bluegreen/   # opt-in: swap canary → blue-green
│   │   └── envs/                     # One folder per environment
│   │       ├── dev/
│   │       │   ├── kustomization.yaml   # base + variants/non-prod + patches
│   │       │   ├── version.yml          # image tag (promotable)
│   │       │   ├── settings.yml         # business settings (promotable)
│   │       │   ├── replicas.yml         # k8s scaling (env-specific)
│   │       │   └── static.yml           # env-only (DB URL, endpoints)
│   │       ├── qa/
│   │       ├── staging/
│   │       └── prod/
│   └── web/                          # Next.js service
│       └── (same structure)
├── argocd/
│   ├── applications/                 # Per-env Argo CD apps
│   │   ├── api-dev.yaml
│   │   ├── api-qa.yaml
│   │   ├── api-staging.yaml
│   │   ├── api-prod.yaml
│   │   ├── web-dev.yaml
│   │   ├── web-qa.yaml
│   │   ├── web-staging.yaml
│   │   └── web-prod.yaml
│   └── applicationsets/
│       └── all-services.yaml         # Auto-generates apps
├── tools/
│   ├── promote-to-staging.sh
│   ├── promote-to-prod.sh
│   ├── rollback.sh
│   └── validate-config.sh
├── .github/
│   ├── workflows/
│   │   ├── promote-staging.yml
│   │   ├── promote-prod.yml
│   │   ├── rollback.yml
│   │   └── validate-sync.yml
│   └── CODEOWNERS
└── README.md
```

## Why a Separate Repo

Following GitOps best practices (Codefresh, CNCF):

| Concern | App Repo | Deploy Repo |
|---------|----------|-------------|
| Source code | ✅ | ❌ |
| Tests | ✅ | ❌ |
| Dockerfile | ✅ | ❌ |
| K8s manifests | ❌ | ✅ |
| Per-env config | ❌ | ✅ |
| Argo CD apps | ❌ | ✅ |
| Promotion gates | ❌ | ✅ |

Benefits:
- Independent permissions (devs vs SRE)
- Argo CD watches only deploy repo
- Cleaner audit trail for production changes
- App repo focuses on code

## Branch Strategy

**Single `main` branch only.** Branch-per-environment is an explicit
anti-pattern — never name a branch `staging`, `qa`, `production`, or
similar. Reasons (Octopus, "Stop using branches…"):

1. **Promotion is not a clean merge.** Cherry-picks and unintended
   config changes (e.g. a QA-only replica count) leak across envs.
2. **Drift is invisible.** Hotfixes applied to `prod` rarely backport;
   later promotions silently overwrite them.
3. **Branches multiply.** Multi-region × multi-env × per-service
   easily produces 13+ long-lived branches per app.
4. **It contradicts the tooling.** Both Kustomize (overlays) and Helm
   (values files) model environments with **files and folders**, not
   branches. Branching fights the grain of these tools.

Environments are folders on `main`:
```
apps/api/envs/dev/        ← DEV environment config
apps/api/envs/qa/         ← QA environment config
apps/api/envs/staging/    ← STAGING environment config
apps/api/envs/prod/       ← PROD environment config
```

Promotion = file copy (`cp envs/qa/version.yml envs/staging/`),
never `git merge`.

## Configuration Categorization

Before splitting files, classify every setting into one of four
categories (Octopus, "How to model your GitOps environments"). Each
category lives in its own file inside `envs/<env>/` so promotions can
move only the slice that needs to move.

| Category | File | Promotable? | Example |
|----------|------|-------------|---------|
| Container image version | `version.yml` | **Yes** (QA→STG→PROD) | `api:v3.3.0-rc1` |
| Kubernetes settings | `replicas.yml` | No (env-shaped) | replicas, HPA, resources |
| Static business settings | `static.yml` | No (env-bound) | DB URL, payment gateway, region |
| Promotable business settings | `settings.yml` | **Yes** | feature flags, log level, timeouts |

Why split: a single fat `values.yaml` forces "all-or-nothing"
promotions. With per-concern files, a feature-flag promotion is
literally `cp envs/qa/settings.yml envs/staging/settings.yml` and
cannot accidentally drag the QA replica count along with it.

## Image Tag Flow

Same image flows through environments (no rebuild). The image tag
lives in `version.yml`, isolated from every other concern:

```
api:v3.3.0-rc1 (built once)
       │
       ├──→ envs/qa/version.yml         ← deployed to QA
       │
       ├──→ envs/staging/version.yml    ← promoted to STAGING (same image)
       │
       └──→ envs/prod/version.yml       ← promoted to PROD (same image)
```

Only DEV uses a different image (latest from `main`):

```
envs/dev/version.yml      → api:abc1234 (per-commit, continuous)
envs/qa/version.yml       → api:v3.3.0-rc1 (release candidate)
envs/staging/version.yml  → api:v3.3.0-rc1 (same as QA)
envs/prod/version.yml     → api:v3.3.0-rc1 (same as STG, after release)
```

## Argo CD Sync Policy

| Environment | Sync Mode | Approval |
|-------------|-----------|----------|
| DEV | Auto | None |
| QA | Auto | None |
| STAGING | Auto | None |
| PROD | **Manual** | 2 reviewers + manual sync |

```yaml
# argocd/applications/api-prod.yaml
syncPolicy:
  # NO automated for prod!
  syncOptions:
    - CreateNamespace=true
```

Manual sync via Argo CD UI provides production safety net.

## Promotion Workflows

Every promotion resolves to a **file copy** between env folders — never
a `git merge` and never an in-place edit of `base/` or `variants/`. The
file you copy depends on what you're promoting:

| Promoting | File copied |
|-----------|-------------|
| Application version | `version.yml` |
| Feature flag / business setting | `settings.yml` |
| Replica/HPA change | `replicas.yml` (usually env-specific, not promoted) |

### DEV → QA (Auto)

Happens via app repo CI when a release branch is cut. CI bot updates
`apps/<service>/envs/qa/version.yml` and pushes to `main`.

### QA → STAGING (Manual Trigger)

```bash
# Option 1: GitHub UI
# Actions → Promote QA → STAGING → Run workflow → service: api

# Option 2: CLI
gh workflow run promote-staging.yml -f service=api

# Option 3: Local (mirrors what CI does)
cp apps/api/envs/qa/version.yml apps/api/envs/staging/version.yml
git commit -am "promote api QA→STAGING" && git push
```

The workflow:
1. Copies `envs/qa/version.yml` → `envs/staging/version.yml`
2. Commits and pushes to `main`
3. Argo CD auto-syncs STAGING

### STAGING → PROD (PR + 2 Approvers)

```bash
gh workflow run promote-prod.yml -f service=api -f version=v3.3.0
```

The workflow:
1. Verifies 24h+ soak in STAGING
2. Creates branch `release/api/v3.3.0-prod`
3. Copies `envs/staging/version.yml` → `envs/prod/version.yml`
4. Opens PR with 2 required reviewers
5. After merge, Argo CD detects the change but waits (manual sync)
6. Release Manager opens Argo CD UI → Sync
7. Argo Rollouts canary: 5% → 25% → 50% → 100%

### Multi-Environment Changes (Don't Edit `base/` First)

When a change must reach **all** environments — e.g. a new resource
limit or a CRD bump — do **not** start by editing `base/` or
`variants/`. That would push the change to every env on the next sync,
defeating gradual rollout.

Instead (Octopus, "How to model your GitOps environments"):

1. Apply the change to **one** env folder (usually `dev`).
2. Bake / observe. If broken, revert one folder — no other env affected.
3. Copy into the next env (`qa`, then `staging`, then `prod`).
4. Once it's in **every** env folder identically, *then* migrate it
   into `variants/` or `base/` and delete the per-env copies in the
   same PR.

This preserves the property that `base/` and `variants/` only ever
contain settings that are already proven across all envs.

## Quick Start

### Prerequisites

- `kubectl` configured for target cluster
- `argocd` CLI installed and logged in
- `kustomize` CLI installed
- Read access to this repo
- Write access for promotion (CODEOWNERS)

### View Current State

```bash
# What's deployed where?
for env in dev qa staging prod; do
  echo "=== $env ==="
  for service in api web; do
    TAG=$(yq '.images[0].newTag' apps/$service/envs/$env/version.yml)
    echo "$service: $TAG"
  done
done
```

### Test Manifests Locally

```bash
# Render manifests for an env
kustomize build apps/api/envs/dev

# Validate
kustomize build apps/api/envs/prod | kubectl apply --dry-run=client -f -

# Diff against cluster
argocd app diff api-dev
```

## Configuration Management

### Per-Environment Files

Each `envs/<env>/` folder splits config into the four files defined
in [Configuration Categorization](#configuration-categorization). For
example, `apps/api/envs/prod/`:

```yaml
# version.yml — promotable, copied from staging
images:
  - name: api
    newTag: v3.3.0

# settings.yml — promotable business config
logLevel: WARN
logFormat: json
features:
  newSearch: false      # not yet enabled in prod
  darkMode: false
timeouts:
  upstream: 5s

# replicas.yml — k8s shape, env-specific (NOT promoted)
replicas: 5
resources:
  cpu:    { limit: 2000m, request: 500m }
  memory: { limit: 2Gi,   request: 512Mi }

# static.yml — env-bound, never promoted
database:
  url: postgresql://api-prod-db:5432/api_prod
redis:
  url: redis://api-prod-redis:6379
```

### Config Sync with App Repo

`comp-proj-app-demo` defines the config schema in
`apps/<service>/config.schema.yaml`. CI cross-checks app-repo schema vs
the union of `settings.yml + static.yml` in every env folder and blocks
the PR if any required key is missing in any environment.

```bash
./tools/validate-config.sh
```

### Progressive ConfigMap Rollout (Argo Rollouts + Kustomize Generators)

> **Decision: do NOT use Reloader (Stakater) for this service.**
>
> Reloader watches a static ConfigMap and triggers a rolling restart
> when it changes. That bypasses the canary, analysis, and automatic
> rollback guarantees that Argo Rollouts gives us — a bad config value
> hits 100% of pods before any health signal can stop it.
> (Octopus, "Progressive delivery for Kubernetes config maps using
> Argo Rollouts".)

Instead, generate a **versioned, hash-suffixed ConfigMap** with
Kustomize so every config change ships as a new ConfigMap *paired with
a new ReplicaSet*, and rolls out under the same canary weights as a
code change.

**1. Register the Rollout transform** (so Kustomize knows to rewrite
ConfigMap refs inside an Argo `Rollout`, not just `Deployment`):

```yaml
# apps/api/base/kustomization.yaml
configurations:
  - https://argoproj.github.io/argo-rollouts/features/kustomize/rollout-transform.yaml

resources:
  - rollout.yaml
  - service.yaml
  - pdb.yaml
```

**2. Generate the ConfigMap from `settings.yml`** (no static
`configmap.yaml` anywhere):

```yaml
# apps/api/envs/prod/kustomization.yaml
resources:
  - ../../base
  - ../../variants/prod

configMapGenerator:
  - name: api-settings
    files:
      - settings.yml
    # generatorOptions.disableNameSuffixHash defaults to false →
    # produces e.g. api-settings-7f3c9d2b
```

**3. Reference by logical name in the Rollout**:

```yaml
# apps/api/base/rollout.yaml
spec:
  template:
    spec:
      volumes:
        - name: settings
          configMap:
            name: api-settings   # rewritten by kustomize → api-settings-<hash>
```

**What happens on a config change:**

1. PR edits `envs/prod/settings.yml`.
2. Kustomize emits a *new* ConfigMap name (new hash) and a *new*
   Rollout pod template referencing it.
3. Argo CD applies both. Argo Rollouts treats it as a new revision
   and steps the canary 5% → 25% → 50% → 100%, running analysis
   between steps.
4. Old and new ConfigMaps coexist for the rollout window — old pods
   keep reading the old ConfigMap, new pods read the new one. No
   cross-contamination.
5. Failed analysis → automatic rollback to the prior ConfigMap and
   ReplicaSet. No manual cleanup; Kustomize garbage-collects the
   unused ConfigMap on the next sync.

**Pitfalls to avoid:**

- Forgetting the `configurations:` line — Kustomize will hash-suffix
  the ConfigMap but won't rewrite the reference inside the `Rollout`,
  and pods will fail to mount.
- Setting `generatorOptions.disableNameSuffixHash: true` — defeats
  the whole pattern; you're back to in-place ConfigMap edits.
- Storing multiple config "versions" inside one ConfigMap with
  suffixed keys (`settings`, `settings-v2`) and selecting in app
  code — this is the naive anti-pattern the article warns against.

## Argo CD Setup

Argo CD is installed via `comp-proj-infra`. Apps managed via App-of-Apps:

```yaml
# argocd/applicationsets/all-services.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: comp-proj-services
spec:
  generators:
    - matrix:
        generators:
          - git:
              repoURL: https://github.com/comp/comp-proj-app-demo-deployment
              revision: main
              files:
                - path: apps/*/envs/*
          - list:
              elements:
                - cluster: dev
                  syncPolicy: auto
                - cluster: prod
                  syncPolicy: manual
  template:
    metadata:
      name: '{{path[0]}}-{{cluster}}'
    spec:
      source:
        path: '{{path}}'
        repoURL: https://github.com/comp/comp-proj-app-demo-deployment
      destination:
        server: '{{url}}'
        namespace: '{{path[0]}}-{{cluster}}'
```

This auto-generates: `api-dev`, `api-qa`, `api-staging`, `api-prod`,
`web-dev`, etc.

## Rollback Procedures

### Option 1: Revert PR (Recommended)

```bash
# Find the bad commit
git log --oneline apps/api/envs/prod/

# Revert
git revert <commit-sha>
git push

# Argo CD applies old version automatically (after 2-approver merge)
```

### Option 2: Argo CD UI Rollback (Faster)

```bash
# CLI
argocd app rollback api-prod <revision-id>

# Or UI: Argo CD → app → History → Rollback
```

### Option 3: Forward Fix (Hotfix)

For critical bugs requiring code changes:

1. Branch from PROD tag in app repo
2. Fix bug
3. Build new image (`api:v3.3.1`)
4. Update `apps/api/envs/prod/version.yml`
5. Fast-track merge (1 reviewer + SRE approval)
6. Manual Argo CD sync

## Required Approvers (CODEOWNERS)

```
# .github/CODEOWNERS

apps/*/envs/dev/            @comp/dev-team
apps/*/envs/qa/             @comp/dev-team @comp/qa-team
apps/*/envs/staging/        @comp/sre-team
apps/*/envs/prod/           @comp/sre-team @comp/release-managers
apps/*/base/                @comp/sre-team
apps/*/variants/            @comp/sre-team

# Argo CD config (sensitive)
argocd/                     @comp/sre-team
```

## Branch Protection

```
main:
  - Required PR review: 2 for prod envs (and any change to base/ or variants/)
  - Required status checks: validate-sync
  - No force push
  - No direct push
```

## Validation Checks (CI)

Every PR runs:

| Check | Purpose |
|-------|---------|
| `kustomize build` | Manifests render correctly |
| `kubectl apply --dry-run` | Valid K8s spec |
| `validate-sync` | Config matches app schema |
| `kubeconform` | Schema validation |
| `kube-score` | Best practices check |
| `polaris` | Security policies |

## Monitoring Argo CD

```bash
# Status of all apps
argocd app list

# Detailed status
argocd app get api-prod

# Watch sync
argocd app sync api-prod --watch

# Manual sync (prod)
argocd app sync api-prod
```

Or use Argo CD UI: `https://argocd.comp.com`

## Adding a New Service

1. Create `apps/<service>/base/` with manifests (rollout, service, pdb)
2. Create `apps/<service>/variants/{non-prod,prod}/` for shared mixins
3. Create `apps/<service>/envs/{dev,qa,staging,prod}/`, each with
   `kustomization.yaml`, `version.yml`, `settings.yml`, `replicas.yml`,
   `static.yml`
4. Add to `argocd/applicationsets/all-services.yaml`
5. Update CODEOWNERS
6. Document in `docs/services/<service>.md`

## Adding a New Environment

1. Create `apps/<service>/envs/<new-env>/`
2. Add `kustomization.yaml` plus the four config files
   (`version.yml`, `settings.yml`, `replicas.yml`, `static.yml`)
3. Compose in the right variant (e.g. `../../variants/non-prod`)
4. Add Argo CD application
5. Configure Argo CD project access
6. Update promotion workflows

## Common Commands

```bash
# Render all manifests for an env
for service in api web; do
  kustomize build apps/$service/envs/prod
done

# Diff between two envs (full rendered output)
diff <(kustomize build apps/api/envs/staging) \
     <(kustomize build apps/api/envs/prod)

# Cheaper: diff just the promotable slice
vimdiff apps/api/envs/staging/settings.yml apps/api/envs/prod/settings.yml
vimdiff apps/api/envs/staging/version.yml  apps/api/envs/prod/version.yml

# What's the current image in prod?
yq '.images[0].newTag' apps/api/envs/prod/version.yml

# Apply manually (emergency only)
kubectl apply -k apps/api/envs/dev
```

## Troubleshooting

### "Argo CD app stuck in Progressing"

```bash
# Check pod status
kubectl get pods -n api-dev

# Check Argo CD events
argocd app get api-dev

# Force refresh
argocd app sync api-dev --force
```

### "ConfigMap changed but no new Rollout revision"

We do **not** use Reloader (see [Progressive ConfigMap
Rollout](#progressive-configmap-rollout-argo-rollouts--kustomize-generators)).
A config change must produce a new hash-suffixed ConfigMap *and* a new
Rollout revision. If it doesn't:

```bash
# 1. Confirm the generated ConfigMap name changed
kustomize build apps/api/envs/prod | grep -A1 'kind: ConfigMap' | grep name

# 2. Confirm the Rollout pod template references the new name
kustomize build apps/api/envs/prod | yq '.spec.template.spec.volumes'
```

Most common cause: missing `configurations:` line pointing at
`rollout-transform.yaml` in `base/kustomization.yaml`, so the
ConfigMap got hashed but the Rollout reference wasn't rewritten.

Second cause: someone set `generatorOptions.disableNameSuffixHash:
true`. Remove it.

### "Promotion failed: race condition"

The promotion workflow auto-retries 5x with `git pull --rebase`. If still
failing, check deploy repo permissions and PAT scope.

## Standards

- All manifests follow Kubernetes best practices
- Resource limits required on all containers
- Liveness/readiness probes required
- Pod Security Standards: restricted
- NetworkPolicies enforced

## Required Secrets (GitHub)

| Secret | Description |
|--------|-------------|
| `ARGOCD_AUTH_TOKEN` | For CI to interact with Argo CD |

(App image pulls handled by IRSA, not secrets.)

## Support

- **Issues**: open in this repo
- **Slack**: `#comp-deployments`
- **Owner**: `@comp/sre-team`
- **Argo CD**: https://argocd.comp.com

## License

Internal use only — COMP.