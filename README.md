# comp-proj-app-demo-deployment

GitOps deploy repo for `comp-proj-app-demo`. Argo CD watches `main` and
syncs every `apps/<service>/envs/<env>/` folder to its cluster.

See [`DEFINITION.md`](./DEFINITION.md) for the full design rationale
(folder model, anti-patterns, ConfigMap progressive delivery).

## Layout

```
apps/<service>/
├── base/         # Shared K8s manifests (Rollout, Service, PDB, AnalysisTemplates)
├── variants/     # Reusable mixins (non-prod, prod, high-traffic)
└── envs/<env>/   # Per-env folder; the unit Argo CD syncs
    ├── kustomization.yaml
    ├── version.yml      # promotable
    ├── settings.yml     # promotable (configMapGenerator → hash-suffix)
    ├── replicas.yml     # env-shaped, not promoted
    └── static.yml       # env-bound, never promoted
```

## Common ops

```bash
# Render any env
kustomize build apps/api/envs/prod

# Diff promotable slices between envs
vimdiff apps/api/envs/staging/settings.yml apps/api/envs/prod/settings.yml

# Promote QA → STAGING
gh workflow run promote-staging.yml -f service=api
# or:  ./tools/promote-to-staging.sh api

# Promote STAGING → PROD (opens PR)
gh workflow run promote-prod.yml -f service=api -f version=v3.3.0

# Roll back
./tools/rollback.sh api prod
```

Promotion is **always** a file copy between env folders, never a
`git merge`. See `DEFINITION.md` for why.
