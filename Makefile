PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
CLUSTER    ?= skyportal-autopilot
REGION     ?= us-east1
MODEL      ?= microsoft/Phi-3-mini-4k-instruct
IMAGE_URL  ?= $(REGION)-docker.pkg.dev/$(PROJECT_ID)/ai-support-bot/ai-support-bot

.PHONY: help auth setup dev dev-vllm dev-bad dev-good dev-agent \
        tf-init tf-plan tf-apply tf-migrate tf-destroy \
        build push build-push \
        deploy-vllm deploy-agent deploy deploy-bad deploy-good \
        deploy-hyperstack-vllm deploy-hyperstack-bad deploy-hyperstack-good \
        logs logs-kv \
        logs-hyperstack logs-hyperstack-kv logs-hyperstack-requests \
        load-local load-direct load-direct-heavy load-hyperstack \
        status status-hyperstack \
        _gke-creds _require-project _logs

help:
	@echo "Usage: make <target> [PROJECT_ID=your-project-id]"
	@echo ""
	@echo "Auth:"
	@echo "  auth         gcloud login + application-default login (run first)"
	@echo ""
	@echo "Local dev:"
	@echo "  setup        Install gcloud, Python 3.12, poetry deps, vllm-metal"
	@echo "  dev          Start vLLM (Metal GPU) + agent container"
	@echo "  dev-vllm     Start vLLM only (baseline: maxNumSeqs=16)"
	@echo "  dev-bad      Start vLLM with regression config (maxNumSeqs=32)"
	@echo "  dev-good     Start vLLM with baseline config (maxNumSeqs=16)"
	@echo "  dev-logs     Start vLLM + stream logs to GCS bucket"
	@echo "  dev-agent    Start agent container only"
	@echo ""
	@echo "Infrastructure:"
	@echo "  tf-init      terraform init"
	@echo "  tf-plan      terraform plan"
	@echo "  tf-apply     terraform apply (pass 1 — creates state bucket)"
	@echo "  tf-migrate   migrate local state to GCS backend (pass 2, run once)"
	@echo "  tf-destroy   terraform destroy"
	@echo ""
	@echo "Build & push:"
	@echo "  build        Docker build the agent image"
	@echo "  push         Push agent image to Artifact Registry"
	@echo "  build-push   build + push"
	@echo ""
	@echo "Deploy:"
	@echo "  deploy-vllm           Helm upgrade vLLM on GKE (baseline config)"
	@echo "  deploy-agent          Helm upgrade ai-support-bot on GKE"
	@echo "  deploy                build-push + deploy both (full local deploy)"
	@echo "  deploy-bad            Trigger KV cache regression (maxModelLen=16384, maxNumSeqs=24)"
	@echo "  deploy-good           Revert to baseline config (maxModelLen=8192, maxNumSeqs=12)"
	@echo "  deploy-hyperstack-vllm  Helm upgrade vLLM on Hyperstack (Phi-3-mini, A4000)"
	@echo "  deploy-hyperstack-bad   Trigger KV cache regression (maxModelLen=4096, maxNumSeqs=32)"
	@echo "  deploy-hyperstack-good  Revert to baseline config (maxModelLen=4096, maxNumSeqs=16)"
	@echo ""
	@echo "Observability:"
	@echo "  logs                    Tail vLLM logs from Cloud Logging (GKE)"
	@echo "  logs-kv                 Tail KV cache stat lines only (GKE)"
	@echo "  logs-hyperstack         Stream all vLLM logs (Hyperstack, live)"
	@echo "  logs-hyperstack-kv      Stream KV cache stat lines only (Hyperstack)"
	@echo "  logs-hyperstack-requests Stream request/response lines only (Hyperstack)"
	@echo "  status                  Show pod status in both namespaces (GKE)"
	@echo "  status-hyperstack       Show pod status in both namespaces (Hyperstack)"
	@echo ""
	@echo "Load testing:"
	@echo "  load-local              Fire 16 parallel /chat requests at localhost:8080"
	@echo "  load-direct             Fire 32 parallel requests direct to vLLM (bypasses agent)"
	@echo "  load-direct-heavy       Fire 64 parallel requests direct to vLLM"
	@echo "  load-hyperstack         Fire 16 parallel /chat requests via port-forward"

# ── Auth ─────────────────────────────────────────────────────────────────────

auth: _require-project
	gcloud auth login
	gcloud auth application-default login

# ── Local dev ────────────────────────────────────────────────────────────────

setup:
	bash scripts/dev.sh setup

dev:
	bash scripts/dev.sh

dev-vllm:
	bash scripts/dev.sh vllm

dev-bad:
	MAX_NUM_SEQS=32 bash scripts/dev.sh vllm

dev-good:
	MAX_NUM_SEQS=16 bash scripts/dev.sh vllm

dev-logs:
	bash scripts/dev.sh dev-logs

dev-agent:
	bash scripts/dev.sh agent

# ── Infrastructure ────────────────────────────────────────────────────────────

tf-init:
	terraform -chdir=infra/terraform init

tf-plan: _require-project
	terraform -chdir=infra/terraform plan -var="project_id=$(PROJECT_ID)"

tf-apply: _require-project
	terraform -chdir=infra/terraform apply -auto-approve -var="project_id=$(PROJECT_ID)"

tf-destroy: _require-project
	terraform -chdir=infra/terraform destroy -var="project_id=$(PROJECT_ID)"

tf-migrate: _require-project
	@echo "Writing backend.tf and migrating local state to GCS..."
	@printf 'terraform {\n  backend "gcs" {\n    bucket = "$(PROJECT_ID)-tfstate"\n    prefix = "ai-support-bot"\n  }\n}\n' \
		> infra/terraform/backend.tf
	terraform -chdir=infra/terraform init -migrate-state -force-copy

# ── Build & push ─────────────────────────────────────────────────────────────

build: _require-project
	docker build -t "$(IMAGE_URL):latest" .

push: _require-project
	gcloud auth configure-docker $(REGION)-docker.pkg.dev --quiet
	docker push "$(IMAGE_URL):latest"

build-push: build push

# ── Deploy ────────────────────────────────────────────────────────────────────

_gke-creds: _require-project
	gcloud container clusters get-credentials $(CLUSTER) \
		--region $(REGION) \
		--project $(PROJECT_ID)

deploy-vllm:
	helm upgrade --install vllm helm/vllm \
		--namespace vllm \
		--create-namespace

deploy-bad:
	helm upgrade vllm helm/vllm \
		--namespace vllm \
		--set vllm.maxModelLen=16384 \
		--set vllm.maxNumSeqs=24 \
		--wait

deploy-good:
	helm upgrade vllm helm/vllm \
		--namespace vllm \
		--set vllm.maxModelLen=8192 \
		--set vllm.maxNumSeqs=12 \
		--wait

deploy-hyperstack-vllm:
	KUBECONFIG=hyperstack/kubeconfig.yaml helm upgrade --install vllm helm/vllm \
		--namespace vllm \
		--create-namespace \
		--set nodeSelector=null \
		-f hyperstack/vllm-values.yaml

deploy-hyperstack-bad:
	KUBECONFIG=hyperstack/kubeconfig.yaml helm upgrade vllm helm/vllm \
		--namespace vllm \
		--set nodeSelector=null \
		-f hyperstack/vllm-values.yaml \
		--set vllm.maxModelLen=4096 \
		--set vllm.maxNumSeqs=32

deploy-hyperstack-good:
	KUBECONFIG=hyperstack/kubeconfig.yaml helm upgrade vllm helm/vllm \
		--namespace vllm \
		--set nodeSelector=null \
		-f hyperstack/vllm-values.yaml \
		--set vllm.maxModelLen=4096 \
		--set vllm.maxNumSeqs=16

deploy-agent: _require-project
	helm upgrade --install ai-support-bot helm/ai-support-bot \
		--namespace ai-support-bot \
		--create-namespace \
		--set image.repository="$(IMAGE_URL)" \
		--set vllm.baseUrl="http://vllm.vllm.svc.cluster.local:8000/v1" \
		--wait

deploy: _require-project _gke-creds build-push deploy-vllm deploy-agent

# ── Observability ─────────────────────────────────────────────────────────────

_logs: _require-project
	gcloud logging read \
		'resource.type="k8s_container" AND resource.labels.namespace_name="vllm" $(LOG_FILTER)' \
		--project=$(PROJECT_ID) \
		--limit=50 \
		--format="value(textPayload)" \
		--freshness=1h

logs:
	$(MAKE) _logs LOG_FILTER=""

logs-kv:
	$(MAKE) _logs LOG_FILTER='AND textPayload=~"GPU KV cache usage"'

logs-hyperstack:
	KUBECONFIG=hyperstack/kubeconfig.yaml kubectl logs -n vllm -l app=vllm -f --tail=50

logs-hyperstack-kv:
	KUBECONFIG=hyperstack/kubeconfig.yaml kubectl logs -n vllm -l app=vllm -f --tail=0 | grep --line-buffered "GPU KV cache"

logs-hyperstack-requests:
	KUBECONFIG=hyperstack/kubeconfig.yaml kubectl logs -n vllm -l app=vllm -f --tail=0 | grep --line-buffered "Received request\|Finished request\|POST /v1"

load-local:
	AGENT_URL=http://localhost:8080 CONCURRENCY=16 bash scripts/load.sh

load-direct:
	VLLM_URL=http://localhost:8001 CONCURRENCY=32 bash scripts/load-direct.sh

load-direct-heavy:
	VLLM_URL=http://localhost:8001 CONCURRENCY=64 bash scripts/load-direct.sh

load-hyperstack:
	AGENT_URL=http://localhost:8080 CONCURRENCY=16 bash scripts/load.sh

status:
	kubectl get pods -n vllm
	kubectl get pods -n ai-support-bot

status-hyperstack:
	KUBECONFIG=hyperstack/kubeconfig.yaml kubectl get pods -n vllm
	KUBECONFIG=hyperstack/kubeconfig.yaml kubectl get pods -n ai-support-bot 2>/dev/null || true

# ── Internal ──────────────────────────────────────────────────────────────────

_require-project:
	@test -n "$(PROJECT_ID)" || (echo "ERROR: PROJECT_ID is not set. Run: make <target> PROJECT_ID=your-project-id"; exit 1)
