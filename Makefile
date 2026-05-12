# Operator helpers for the deploy repo.
# Most workflow goes through git push → Argo CD sync; these targets are
# for one-time bootstrap, ad-hoc verification, and emergency operations.

ARGOCD_NS ?= platform-system
SVC       ?= backend
ENV       ?= dev
APP_NS     = comp-proj-$(ENV)
APP_LABEL  = app.kubernetes.io/part-of=comp-proj

.PHONY: help \
        bootstrap deploy-direct destroy \
        status applications appset diff \
        sync sync-all promote-status \
        password ui \
        validate

help:
	@echo "One-time / bootstrap:"
	@echo "  bootstrap        kubectl apply -f argocd/bootstrap.yaml (creates the app-of-apps)"
	@echo "  deploy-direct    apply AppProject + ApplicationSet without the bootstrap wrapper"
	@echo "  destroy          delete bootstrap → cascade-deletes AppProject + Applications"
	@echo
	@echo "Inspect:"
	@echo "  status           one-line sync/health for every comp-proj Application"
	@echo "  applications     list Argo CD Applications"
	@echo "  appset           describe the ApplicationSet"
	@echo "  diff             kustomize build every env (catches yaml/composition errors)"
	@echo "  validate         kustomize build + basic schema checks"
	@echo
	@echo "Operate:"
	@echo "  sync SVC=backend ENV=sit       force-sync one Application (uat/preprod/prod gates)"
	@echo "  sync-all                       force-sync every Application"
	@echo "  promote-status                 show current image tag in each env"
	@echo
	@echo "Access:"
	@echo "  password         print Argo CD initial admin password"
	@echo "  ui               port-forward argocd-server to localhost:8080"
	@echo
	@echo "Variables: ARGOCD_NS=$(ARGOCD_NS)  SVC=$(SVC)  ENV=$(ENV)"

# ─── bootstrap ──────────────────────────────────────────────────────────────

bootstrap:
	@kubectl get ns $(ARGOCD_NS) >/dev/null 2>&1 || { echo "Argo CD namespace $(ARGOCD_NS) not found. See SETUP.md."; exit 1; }
	kubectl apply -f argocd/bootstrap.yaml
	@echo
	@echo "✓ Bootstrap applied. Watch it converge:"
	@echo "  kubectl -n $(ARGOCD_NS) get application bootstrap -w"

deploy-direct:
	kubectl apply -f argocd/projects/comp-proj.yaml
	kubectl apply -f argocd/applicationsets/all-services.yaml

destroy:
	@echo "DANGER: this deletes the bootstrap Application, which cascades to"
	@echo "the AppProject and all 10 service Applications."
	@read -p "Type 'destroy' to confirm: " c && [ "$$c" = "destroy" ] || (echo "aborted"; exit 1)
	kubectl -n $(ARGOCD_NS) delete application bootstrap

# ─── inspect ────────────────────────────────────────────────────────────────

status:
	@kubectl -n $(ARGOCD_NS) get applications -l $(APP_LABEL) \
	  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision \
	  2>/dev/null || echo "no Applications found — did you run 'make bootstrap'?"

applications:
	kubectl -n $(ARGOCD_NS) get applications -l $(APP_LABEL)

appset:
	kubectl -n $(ARGOCD_NS) get applicationset comp-proj-services -o yaml | head -40

diff:
	@command -v kustomize >/dev/null || { echo "install: brew install kustomize"; exit 1; }
	@for svc in backend frontend; do \
	  for env in dev sit uat preprod prod; do \
	    printf "── %s/%s ──\n" "$$svc" "$$env"; \
	    kustomize build apps/$$svc/envs/$$env >/dev/null && echo "  OK" || echo "  FAILED"; \
	  done; \
	done

validate: diff
	@command -v yq >/dev/null || { echo "install: brew install yq"; exit 1; }
	@for f in apps/*/envs/*/version.yml; do \
	  yq '.[0].value' "$$f" >/dev/null || { echo "bad: $$f"; exit 1; }; \
	done
	@echo "✓ all version.yml files parse"

# ─── operate ────────────────────────────────────────────────────────────────

sync:
	@command -v argocd >/dev/null || { echo "install: brew install argocd"; exit 1; }
	argocd app sync $(SVC)-$(ENV)

sync-all:
	@command -v argocd >/dev/null || { echo "install: brew install argocd"; exit 1; }
	@for svc in backend frontend; do \
	  for env in dev sit uat preprod prod; do \
	    echo "── sync $$svc-$$env ──"; \
	    argocd app sync $$svc-$$env --grpc-web || true; \
	  done; \
	done

# Show the image tag currently checked into each env's version.yml.
# Handy for "is preprod the same SHA as sit?" before promoting.
promote-status:
	@command -v yq >/dev/null || { echo "install: brew install yq"; exit 1; }
	@printf "%-10s %-10s %s\n" "SERVICE" "ENV" "IMAGE"
	@for svc in backend frontend; do \
	  for env in dev sit uat preprod prod; do \
	    img=$$(yq '.[0].value' apps/$$svc/envs/$$env/version.yml); \
	    printf "%-10s %-10s %s\n" "$$svc" "$$env" "$$img"; \
	  done; \
	done

# ─── access ─────────────────────────────────────────────────────────────────

password:
	@kubectl -n $(ARGOCD_NS) get secret argocd-initial-admin-secret \
	  -o jsonpath='{.data.password}' | base64 -d
	@echo

ui:
	@echo "Open https://localhost:8080  (user: admin)"
	@echo "Password:" && $(MAKE) -s password
	kubectl -n $(ARGOCD_NS) port-forward svc/argocd-server 8080:443
