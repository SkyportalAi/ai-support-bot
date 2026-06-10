# ai-support-bot

A SkyPortal support agent powered by [vLLM](https://github.com/vllm-project/vllm) and Llama 3.1 8B. Runs locally on Apple Silicon with Metal GPU acceleration, and deploys to GKE with a T4 GPU.

The agent answers common support questions from a knowledge base and escalates to a human agent when it can't help.

## How it works

The agent keeps a conversation history and loops until it produces a final answer:

1. User sends a message
2. The LLM decides whether to call a tool or respond directly
3. Tools available:
   - `search_knowledge_base` — looks up common questions (always tried first)
   - `get_ticket_status` — looks up an existing ticket by ID
   - `escalate_to_human` — creates a ticket and hands off to a human
4. Loop continues until a final text response is produced or escalation completes

## Running locally (Apple Silicon)

vLLM uses the Metal GPU natively — Docker can't access it on Mac, so vLLM runs on the host and the agent runs in Docker.

```bash
# First time only — installs gcloud, Python 3.12, poetry deps, vllm-metal
bash scripts/dev.sh setup

# Start everything (vLLM on host + agent in Docker)
bash scripts/dev.sh

# Or individually
bash scripts/dev.sh vllm    # just vLLM (Metal GPU, port 8000)
bash scripts/dev.sh agent   # just the agent container (port 8080)
```

Open http://localhost:8080 to chat.

## GCP quota prerequisites

Before deploying, verify these quotas in your target region (Console → IAM & Admin → Quotas & System Limits):

| Quota | Required | Why |
|-------|----------|-----|
| `NVIDIA_T4_GPUS` | ≥ 1 | vLLM pod GPU request |
| `PREEMPTIBLE_CPUS` | ≥ 8 | Required for spot instances — default is **0** on new projects, must be requested manually |
| `CPUS` | ≥ 8 | Required for standard (non-spot) instances |

To request an increase: Quotas page → filter by metric name → checkbox → **Edit Quota** → set to 24 → submit with justification *"Spot GPU workloads on GKE Autopilot for ML inference"*. Small increases are usually auto-approved within minutes.

> **Note on GPU inventory vs quota**: `GCE quota exceeded` in autoscaler events can mean either quota exhaustion *or* physical inventory shortage — GCP uses the same error for both. If your quota shows `usage=0` but pods stay `Pending`, the zone is out of physical T4 stock. Try a different zone or region.

## Deploying to GKE

```bash
# 1. Authenticate
make auth PROJECT_ID=your-project-id

# 2. Provision infrastructure (GKE, Artifact Registry, GCS buckets, IAM)
make tf-init
make tf-apply PROJECT_ID=your-project-id

# 3. Migrate Terraform state to GCS (run once)
make tf-migrate PROJECT_ID=your-project-id

# 4. Deploy vLLM + agent
make deploy PROJECT_ID=your-project-id
```

This creates a GKE Autopilot cluster, Artifact Registry, GCS log bucket, and CI/CD service account. After `tf-apply`, get the GitHub Actions credentials with:

```bash
cd infra/terraform && terraform output -raw workload_identity_provider
cd infra/terraform && terraform output -raw cicd_service_account
```

Add these in GitHub → Settings → Secrets → Actions:
- `GCP_WORKLOAD_IDENTITY_PROVIDER` — output of `terraform output -raw workload_identity_provider`
- `GCP_SERVICE_ACCOUNT` — output of `terraform output -raw cicd_service_account`
- `GCP_PROJECT_ID`
- `GKE_CLUSTER_NAME` — `skyportal-autopilot`
- `GKE_CLUSTER_ZONE` — region where you deployed (e.g. `europe-west1`)
- `VLLM_BASE_URL` — `http://vllm.vllm.svc.cluster.local:8000/v1`

After the first push to `main`, GitHub Actions builds the image and deploys automatically.

## Deploying vLLM on Hyperstack

[Hyperstack](https://www.hyperstack.cloud) is an alternative GPU cloud with better T4/A100 availability than GCP during the current GPU shortage. The vLLM helm chart works unchanged — `vllm/vllm-openai` is a public Docker Hub image, no registry auth needed.

### 1. Create a Kubernetes cluster

In the Hyperstack console, create a Kubernetes cluster with a GPU node pool (T4 or A100). Download the kubeconfig and save it to `hyperstack/kubeconfig.yaml` (gitignored).

### 2. Point kubectl at the cluster

```bash
export KUBECONFIG=$(pwd)/hyperstack/kubeconfig.yaml
kubectl get nodes  # verify connection
```

### 3. Deploy vLLM

```bash
# Update the nodeSelector in helm/vllm/templates/deployment.yaml
# to match Hyperstack's GPU label (check: kubectl describe node | grep accelerator)

helm upgrade --install vllm helm/vllm \
  --namespace vllm \
  --create-namespace
```

### 4. Deploy the agent

```bash
helm upgrade --install ai-support-bot helm/ai-support-bot \
  --namespace ai-support-bot \
  --create-namespace \
  --set vllm.baseUrl="http://vllm.vllm.svc.cluster.local:8000/v1"
```

> **Note on the nodeSelector**: Hyperstack uses different GPU label values than GKE. Run `kubectl describe node | grep -i accelerator` after the node is up to find the correct label, then update `cloud.google.com/gke-accelerator` in `helm/vllm/templates/deployment.yaml` accordingly.

## Running tests

```bash
python -m unittest discover tests -v
```

## Project structure

```
agent/
  agent.py        — SupportAgent class (ReAct loop over vLLM)
  tools.py        — Tool schemas + stub implementations
  main.py         — Interactive CLI
  server.py       — FastAPI server
tests/
  test_tools.py   — Unit tests (no LLM calls)
helm/
  ai-support-bot/ — Helm chart for the agent
  vllm/           — Helm chart for vLLM (T4, Llama 3.1 8B)
infra/terraform/  — GKE Autopilot cluster + Artifact Registry + IAM
scripts/
  dev.sh          — Local dev setup and launcher
  create-gcp-sa.sh — One-time SA creation (if not using Terraform)
.github/workflows/
  deploy.yml      — Build + push + helm upgrade on push to main
```

## Extending

- **Add knowledge base entries**: edit `_KB` in `agent/tools.py`
- **Connect a real ticketing system**: replace the stub in `escalate_to_human()` with a call to Linear, Zendesk, or Slack
- **Change the model**: set `MODEL=<name>` env var, update `helm/vllm/values.yaml`
