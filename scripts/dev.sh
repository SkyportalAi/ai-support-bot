#!/usr/bin/env bash
# Local dev setup and launcher for ai-support-bot.
#
# Usage:
#   bash scripts/dev.sh setup   — install dependencies (run once)
#   bash scripts/dev.sh vllm    — start vLLM natively with Metal GPU
#   bash scripts/dev.sh agent   — start the agent container (docker compose)
#   bash scripts/dev.sh         — start everything (vLLM + agent)

set -euo pipefail

CMD="${1:-all}"
MODEL="${MODEL:-microsoft/Phi-3-mini-4k-instruct}"

header() { echo ""; echo "=== $* ==="; }

setup() {
  header "Installing gcloud SDK"
  if ! command -v gcloud &>/dev/null; then
    brew install --cask google-cloud-sdk
    GCLOUD_PATH="/opt/homebrew/share/google-cloud-sdk/bin"
    SHELL_RC="$HOME/.zshrc"
    if ! grep -q "$GCLOUD_PATH" "$SHELL_RC" 2>/dev/null; then
      echo "export PATH=\"$GCLOUD_PATH:\$PATH\"" >> "$SHELL_RC"
      echo "Added gcloud to PATH in $SHELL_RC — run: source $SHELL_RC"
    fi
    export PATH="$GCLOUD_PATH:$PATH"
  else
    echo "gcloud already installed — skipping"
  fi

  header "Installing Python 3.12"
  if ! command -v python3.12 &>/dev/null; then
    brew install python@3.12
  else
    echo "Python 3.12 already installed — skipping"
  fi

  header "Installing kubectl, gke-gcloud-auth-plugin and helm"
  gcloud components install kubectl gke-gcloud-auth-plugin --quiet
  if ! command -v helm &>/dev/null; then
    brew install helm
  else
    echo "helm already installed — skipping"
  fi

  header "Installing project dependencies"
  poetry env use python3.12
  poetry install

  header "Installing vllm-metal"
  if ! poetry run python -c "import vllm" 2>/dev/null; then
    # Pinned to commit b13dbe1e — update SHA pair together when upgrading vllm-metal
    VLLM_METAL_COMMIT="b13dbe1e34b884d147fc45f3faedf2b65230f2da"
    VLLM_METAL_SHA256="27670d1bbff9c107205cbba400e4b5f5159aafae406c4d8de99226198427c997"
    curl -fsSL -o /tmp/vllm-metal-install.sh \
      "https://raw.githubusercontent.com/vllm-project/vllm-metal/${VLLM_METAL_COMMIT}/install.sh"
    echo "${VLLM_METAL_SHA256}  /tmp/vllm-metal-install.sh" | shasum -a 256 -c -
    bash /tmp/vllm-metal-install.sh
  else
    echo "vllm already installed — skipping"
  fi

  header "Authenticating gcloud"
  gcloud auth login
  gcloud auth application-default login

  echo ""
  echo "Setup complete. Run: bash scripts/dev.sh"
}

start_vllm() {
  header "Starting vLLM (Metal GPU) — model: $MODEL"
  VLLM_PYTHON="${HOME}/.venv-vllm-metal/bin/python"
  if [[ ! -x "$VLLM_PYTHON" ]]; then
    echo "ERROR: vllm-metal venv not found. Run: make setup"; exit 1
  fi
  "$VLLM_PYTHON" -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" \
    --dtype float16 \
    --max-model-len 4096 \
    --max-num-seqs "${MAX_NUM_SEQS:-16}" \
    --gpu-memory-utilization "${GPU_MEM_UTIL:-0.90}" \
    --host 0.0.0.0 \
    --port 8000
}

start_agent() {
  header "Starting agent container"
  docker compose up --build
}

ship_logs_to_gcs() {
  BUCKET="${VLLM_LOGS_BUCKET:-$(gcloud config get-value project 2>/dev/null)-vllm-logs}"
  LOG_FILE="/tmp/vllm-local-$(date +%Y%m%d-%H%M%S).log"
  header "Starting vLLM — logs → $LOG_FILE → gs://$BUCKET"
  VLLM_PYTHON="${HOME}/.venv-vllm-metal/bin/python"
  if [[ ! -x "$VLLM_PYTHON" ]]; then
    echo "ERROR: vllm-metal venv not found. Run: make setup"; exit 1
  fi
  "$VLLM_PYTHON" -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" \
    --dtype float16 \
    --max-model-len 4096 \
    --max-num-seqs "${MAX_NUM_SEQS:-16}" \
    --gpu-memory-utilization "${GPU_MEM_UTIL:-0.90}" \
    --host 0.0.0.0 \
    --port 8000 2>&1 | tee "$LOG_FILE" &
  VLLM_PID=$!

  # Upload log file to GCS on exit
  trap "echo 'Uploading logs to GCS...'; gsutil cp '$LOG_FILE' gs://$BUCKET/local/$(basename $LOG_FILE); echo 'Done: gs://$BUCKET/local/$(basename $LOG_FILE)'; kill $VLLM_PID 2>/dev/null" EXIT INT TERM

  wait $VLLM_PID
}

case "$CMD" in
  setup)    setup ;;
  vllm)     start_vllm ;;
  dev-logs) ship_logs_to_gcs ;;
  agent) start_agent ;;
  all)
    start_vllm &
    VLLM_PID=$!
    echo "Waiting for vLLM to be ready..."
    until curl -sf http://localhost:8000/health &>/dev/null; do sleep 5; done
    echo "vLLM ready."
    start_agent
    wait $VLLM_PID
    ;;
  *) echo "Usage: bash scripts/dev.sh [setup|vllm|agent|all]"; exit 1 ;;
esac
