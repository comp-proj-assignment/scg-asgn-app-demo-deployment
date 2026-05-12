# Deployment Flow

Banking-grade GitOps for `scg-asgn-app-demo`. This document is the
operational source of truth: any change to env layout, promotion path,
or approval policy lands here first.

## Two repos, two responsibilities

| Repo | Role |
|---|---|
| `scg-sre/scg-asgn-app-demo`            | App source code + CI (build + image push + GitOps commit) |
| `scg-sre/scg-asgn-app-demo-deployment` | This repo. Kustomize overlays + Argo CD watches `main`. |

App-repo events trigger CI which **commits** to this repo. Argo CD watches
this repo only — it never touches the app repo.

## Environments

```
apps/<svc>/envs/
├── dev/       develop builds                    auto-sync
├── sit/       release candidates                auto-sync
├── uat/       business validation               manual sync
├── preprod/   perf / pentest / DR / smoke       manual sync
└── prod/      production                        manual sync (CAB-approved PR)
```

Service identifiers: `backend`, `frontend`.

## Branch → Environment Mapping

| # | Stage    | Source branch       | Image tag        | Sync mode    | Argo path                       | Approver                 | Test activity                          |
|---|----------|---------------------|------------------|--------------|---------------------------------|--------------------------|----------------------------------------|
| 1 | Local    | `feature/*`         | —                | —            | —                               | Self                     | Unit, lint                             |
| 2 | DEV      | `develop`           | `develop-<sha>`  | Auto         | `apps/<svc>/envs/dev/`          | None                     | Integration                            |
| 3 | SIT      | `release/x.y.z`     | `vX.Y.Z-rc.<n>`  | Auto         | `apps/<svc>/envs/sit/`          | None                     | E2E, regression, automated QA          |
| 4 | UAT      | (same release rc)   | (same rc image)  | Manual       | `apps/<svc>/envs/uat/`          | Business + QA Lead       | Business scenarios, sign-off           |
| 5 | Pre-Prod | (same release rc)   | (same rc image)  | Manual       | `apps/<svc>/envs/preprod/`      | DevOps + Security        | Perf, pentest, DR, smoke               |
| 6 | Draft PR | `release` → `main`  | —                | Auto-created | (PR in this repo)               | Release Manager          | Fill CAB ticket                        |
| 7 | PROD     | `main` + `vX.Y.Z`   | `vX.Y.Z`         | Manual       | `apps/<svc>/envs/prod/`         | CAB (3+ approvers)       | Canary, monitoring                     |
| 8 | Sync     | `release` → `develop` | —              | Manual git   | —                               | Release Manager          | Auto-backport PR                       |

## Five principles

1. **Build once, promote everywhere.** The image bytes that pass SIT are
   the same bytes that ship to prod. Prod re-tags the rc manifest as
   `vX.Y.Z` in ECR Public — no layer re-upload, no rebuild.
2. **Argo CD watches this repo only.** App-repo events never reach Argo
   directly. The only way to move bits in a cluster is to commit a change
   to a folder under `apps/<svc>/envs/<env>/`.
3. **Auto-sync below UAT, manual above.** Velocity at dev/sit; stability
   and audit at uat/preprod/prod. Set in ApplicationSet `templatePatch`.
4. **Release-branch fixes go to SIT first** — then operator promotes to
   UAT/Pre-Prod. Don't merge back into `develop` until the release ships
   to prod (backport workflow handles this automatically).
5. **Hotfix bypasses sit/uat** — off `main`, smoke in pre-prod, emergency
   CAB, ship to prod, back-merge to `develop` AND every active `release/*`.

## Image flow

```
develop merge ──► build sha_A ─► dev/version.yml = develop-sha_A

release cut    ──► open PR copying dev/version.yml → sit/version.yml
release merge  ──► build rc.N  ─► sit/version.yml = vX.Y.Z-rc.N

dispatch SIT→UAT       ──► PR: sit/version.yml → uat/version.yml
dispatch UAT→preprod   ──► PR: uat/version.yml → preprod/version.yml

main merge (CAB)       ──► retag rc.N → vX.Y.Z in ECR Public
                           PR: preprod/version.yml (retagged) → prod/version.yml
```

## Decision tree

```
Code change needs to deploy?
│
├─ Feature?              → branch off develop → PR → DEV (auto)
├─ Ready to release?     → cut release/x.y.z → SIT (auto via PR-from-dev)
├─ Bug in SIT/UAT?       → fix branch off release → PR → SIT (auto)
│                          → operator promotes SIT → UAT manually
├─ Bug in prod (urgent)? → hotfix branch off main → emergency flow
└─ Release done?         → merge release → main + vX.Y.Z tag → PROD (CAB)
                           → auto-backport release → develop
```

## Promotion mechanics

| From → To              | Mechanism                                            | Audit |
|------------------------|------------------------------------------------------|-------|
| build → dev            | Direct commit by CI on PR merge to `develop`         | Git log on `apps/<svc>/envs/dev/version.yml` |
| build → sit (rc)       | Direct commit by CI on PR merge to `release/*`       | Git log on `apps/<svc>/envs/sit/version.yml` |
| dev → sit (initial)    | Auto-PR opened by CI on `create release/*` branch    | PR review |
| sit → uat              | `workflow_dispatch environment=uat` → auto-PR        | PR review by Business + QA Lead |
| uat → preprod          | `workflow_dispatch environment=preprod` → auto-PR    | PR review by DevOps + Security |
| preprod → prod         | PR auto-opened by CI on PR merge to `main` + retag   | PR review by CAB (3+ approvers) |
| any → previous SHA     | `workflow_dispatch environment=<env> image_tag=<sha>`| Rollback audit in PR / commit log |

`tools/promote.sh <svc> <from> <to>` exists as a manual escape hatch
(stages the version.yml swap; you commit + push or open a PR).

## Variants per env

| Env      | Variant composition         | Rationale                                  |
|----------|-----------------------------|--------------------------------------------|
| dev      | `non-prod` + `canary-fast`  | fast feedback; full canary not needed      |
| sit      | `non-prod`                  | exercises real canary with analysis        |
| uat      | `non-prod`                  | business-facing, lighter footprint         |
| preprod  | `prod`                      | production-shaped for perf/pentest/DR      |
| prod     | `prod` + `high-traffic`     | HPA + strict PDB + canary-with-analysis    |

## Approvers and CAB

| Env      | Required reviewers (deploy-repo PR)            |
|----------|------------------------------------------------|
| sit      | None (auto-merge after CI green)                |
| uat      | 1 from Business team + 1 from QA Lead          |
| preprod  | 1 from DevOps team + 1 from Security           |
| prod     | 3+ CAB members (Release Manager, Security, SRE)|

Enforced via branch protection rules on the deploy repo's `main` branch
combined with per-env GitHub Environments. Bypass requires a documented
incident ticket.

## Hotfix flow (exception path)

```
1. Cut hotfix/<ticket>     from main
2. Fix → PR → main         (CI builds image with sha tag)
3. CI:
   - retag the new sha as vX.Y.(Z+1)
   - opens prod-promotion PR (NORMAL CAB gate still applies)
4. Smoke test in preprod   (deploy via dispatch to preprod first)
5. Emergency CAB approves prod PR
6. Auto-backport fires     to develop + every active release/* branch
```

The backport workflow (`backport.yml` in the app repo) opens the
auto-backport PRs in step 6.

## What lives where in this repo

```
apps/<svc>/
├── base/                    # k8s manifests shared across all envs
├── variants/                # reusable mixins (composed by envs)
└── envs/<env>/
    ├── kustomization.yaml   # base + variant(s) + patches
    ├── version.yml          # image tag (rewritten by CI)
    ├── settings.yml         # business config (promotable)
    ├── replicas.yml         # k8s scaling (env-specific, not promoted)
    └── static.yml           # env-bound endpoints (never promoted)

argocd/
├── projects/comp-proj.yaml          # AppProject + namespace allowlist
└── applicationsets/all-services.yaml # auto-generates Argo CD Applications

tools/
├── promote.sh               # manual <svc> <from> <to> version-copy helper
├── rollback.sh              # roll an env back to a previous SHA
└── validate-config.sh       # kustomize-build every overlay (CI gate)
```

## What changes per file type during promotion

| File          | Promoted between envs? | Updated by  |
|---------------|------------------------|-------------|
| `version.yml` | YES                    | CI (or `tools/promote.sh`) |
| `settings.yml`| YES (manual copy)      | Engineer in a PR           |
| `replicas.yml`| NO                     | Engineer in a PR           |
| `static.yml`  | NO                     | Engineer in a PR           |

## Rollback

```bash
# From the app repo, dispatch the relevant workflow:
gh workflow run backend.yml \
  -f environment=preprod \
  -f image_tag=<previous-rc-or-sha>
```

For prod rollback, dispatch opens a PR — CAB approves the revert as it
would any other prod change.

## Cluster destinations and allowed namespaces

AppProject `comp-proj` allows the following namespace patterns (set in
`argocd/projects/comp-proj.yaml`):

- `backend-*`  (covers backend-dev, backend-sit, backend-uat, backend-preprod, backend-prod)
- `frontend-*` (same)

ApplicationSet generates per-env Argo CD `Application` resources from
`apps/<svc>/envs/<env>/` paths. Adding a new env = adding a folder.
