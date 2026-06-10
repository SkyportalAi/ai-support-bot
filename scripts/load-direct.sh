#!/usr/bin/env bash
# Direct vLLM load generator — hits /v1/chat/completions bypassing the agent.
# Generates long prompts to maximise KV block consumption per request.
#
# Usage:
#   bash scripts/load-direct.sh                     # defaults: 32 parallel, localhost:8001
#   CONCURRENCY=64 bash scripts/load-direct.sh
#   VLLM_URL=http://localhost:8001 bash scripts/load-direct.sh

set -euo pipefail

VLLM_URL="${VLLM_URL:-http://localhost:8001}"
CONCURRENCY="${CONCURRENCY:-128}"
KUBECONFIG="${KUBECONFIG:-hyperstack/kubeconfig.yaml}"
METRICS_FILE="${METRICS_FILE:-logs/kv-metrics.jsonl}"
MODEL="microsoft/Phi-3-mini-4k-instruct"
MAX_TOKENS="${MAX_TOKENS:-2048}"
ROUND=0

mkdir -p "$(dirname "$METRICS_FILE")"

# Prompt engineered to produce very long outputs — fills KV blocks for longer
SYSTEM="You are a senior SkyPortal infrastructure engineer writing exhaustive post-incident reports. For every incident you must: (1) list every possible root cause with full technical explanation, (2) describe the blast radius across all systems, (3) write a complete step-by-step remediation runbook with exact commands, (4) propose 10 specific preventive measures with implementation details, (5) draft a full timeline of events, (6) write a customer-facing incident summary. Be extremely detailed and verbose in every section. Do not summarise — expand every point fully."

# Repeat each message body to push prompt tokens near the 4096 context limit
MSG1="Since yesterday afternoon our entire GPU fleet has been unreachable. We have 48 A100 nodes across three availability zones. The monitoring dashboard shows all nodes as offline but our billing is still running. SSH connections time out after 30 seconds with no error. The last thing we did before the outage was apply a routine OS patch via our config management system. We have a production ML training job that was at 94% completion and we cannot afford to restart it from scratch. Please help us understand what happened, how to recover the nodes without losing the checkpoint, and what we need to do to prevent this in future. Additional context: the patch was kernel 5.15.0-91-generic applied via apt-get upgrade. The config management system is Ansible. The training job is a distributed PyTorch run using NCCL. The checkpoint files are on a shared NFS mount. The NFS mount is still accessible from our bastion host. The GPU nodes are NVIDIA A100 SXM4 80GB. The cluster is managed by Kubernetes 1.27."
MSG2="We are processing financial transactions through our inference API and response times have increased from 800ms to over 6 seconds since Tuesday. Our SLA requires sub-second responses. The only change was increasing max_num_seqs from 12 to 32 in vLLM config to handle more concurrent users. Transaction volume also increased 3x since our new product launch last week. We need to understand if these are related and what the fastest path to recovery is without downtime. Additional context: we are running vLLM 0.5.0 on NVIDIA A4000 GPUs with 16GB VRAM. The model is Phi-3-mini-4k-instruct at float16. Our p99 latency SLA is 1000ms. We currently have 400 concurrent users. Each request averages 800 input tokens and 200 output tokens. The KV cache is showing 95% utilisation in our monitoring."
MSG3="Our data science team accidentally deleted the production model weights from shared storage last night. We have backups from 3 days ago but 2 days of fine-tuning since then is not backed up. The fine-tuning runs were logged to our MLflow experiment tracker but actual checkpoint files are gone. We have a board demo in 18 hours. Additional context: the model was fine-tuned from Phi-3-mini-4k-instruct base. We ran 3 fine-tuning runs over 2 days. Each run was approximately 8 hours on 4x A100 GPUs. The experiment tracker has all hyperparameters, loss curves, and evaluation metrics. The storage system is a Ceph cluster. The deletion was accidental rm -rf on the wrong directory. We do not have versioning enabled on the storage bucket."

MESSAGES=("$MSG1" "$MSG2" "$MSG3")

fire_one() {
  local msg_idx body
  msg_idx=$(( RANDOM % ${#MESSAGES[@]} ))
  body=$(python3 -c "
import json, sys
print(json.dumps({
  'model': '$MODEL',
  'messages': [
    {'role': 'system', 'content': '''$SYSTEM'''},
    {'role': 'user',   'content': '''${MESSAGES[$msg_idx]}'''}
  ],
  'max_tokens': $MAX_TOKENS,
  'temperature': 0.7,
}))
")

  local start end elapsed status
  start=$(python3 -c "import time; print(int(time.time()*1000))")
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 120 \
    -X POST "$VLLM_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$body" || echo "000")
  end=$(python3 -c "import time; print(int(time.time()*1000))")
  elapsed=$(( end - start ))

  printf "[load] status=%s latency=%dms\n" "$status" "$elapsed"
}

export -f fire_one
export VLLM_URL MESSAGES MODEL

# Stream KV metrics from Hyperstack alongside load output
KUBECONFIG="$KUBECONFIG" kubectl logs -n vllm -l app=vllm -f --tail=0 2>/dev/null \
  | grep --line-buffered "GPU KV cache" \
  | python3 -u -c "
import sys, re, json, time

metrics_file = '$METRICS_FILE'

for line in sys.stdin:
    ts   = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    run  = re.search(r'Running: (\d+)', line)
    pend = re.search(r'Pending: (\d+)', line)
    swap = re.search(r'Swapped: (\d+)', line)
    gpu  = re.search(r'GPU KV cache usage: ([0-9.]+)%', line)
    gen  = re.search(r'Avg generation throughput: ([0-9.]+)', line)
    if not gpu:
        continue

    record = {
        'ts': ts,
        'gpu_kv_pct': float(gpu.group(1)),
        'running': int(run.group(1)) if run else 0,
        'pending': int(pend.group(1)) if pend else 0,
        'swapped': int(swap.group(1)) if swap else 0,
        'gen_tokens_per_s': float(gen.group(1)) if gen else 0.0,
    }

    with open(metrics_file, 'a') as f:
        f.write(json.dumps(record) + '\n')

    pct = record['gpu_kv_pct']
    pending = record['pending']
    flag = '  *** SATURATING ***' if pct > 50 or pending > 0 else ''
    print(f'[kv]  gpu={pct:.1f}%  running={record[\"running\"]}  pending={pending}{flag}', flush=True)
" &
KV_PID=$!

trap "kill $KV_PID 2>/dev/null; exit" INT TERM

echo "Direct vLLM load — target: $VLLM_URL, concurrency: $CONCURRENCY"
echo "KV metrics streaming from Hyperstack"
echo "Press Ctrl+C to stop."
echo ""

while true; do
  ROUND=$(( ROUND + 1 ))
  echo "--- Round $ROUND ---"

  PIDS=()
  for (( i=0; i<CONCURRENCY; i++ )); do
    fire_one &
    PIDS+=($!)
  done

  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
done
