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
CONCURRENCY="${CONCURRENCY:-32}"
KUBECONFIG="${KUBECONFIG:-hyperstack/kubeconfig.yaml}"
METRICS_FILE="${METRICS_FILE:-logs/kv-metrics.jsonl}"
MODEL="microsoft/Phi-3-mini-4k-instruct"
ROUND=0

mkdir -p "$(dirname "$METRICS_FILE")"

# Long system prompt + user message to consume as many KV blocks as possible
SYSTEM="You are a senior SkyPortal support engineer. A customer has filed a detailed incident report describing cascading failures across their GPU cluster. Analyse the situation thoroughly, identify all root causes, list every affected component, propose a remediation plan with step-by-step instructions, estimate recovery time, and draft a post-incident review summary."

MESSAGES=(
  "Since yesterday afternoon our entire GPU fleet has been unreachable. We have 48 A100 nodes across three availability zones. The monitoring dashboard shows all nodes as offline but our billing is still running. SSH connections time out after 30 seconds with no error. The last thing we did before the outage was apply a routine OS patch via our config management system. We have a production ML training job that was at 94% completion and we cannot afford to restart it from scratch. Please help us understand what happened, how to recover the nodes without losing the checkpoint, and what we need to do to prevent this in future."
  "We are processing financial transactions through our inference API and we have noticed that since last Tuesday response times have increased from an average of 800ms to over 6 seconds. Our SLA requires sub-second responses. We have not changed our model or infrastructure. The only change was that our DevOps team increased the max_num_seqs parameter in the vLLM config from 12 to 32 to handle more concurrent users. Transaction volume has also increased 3x since we launched a new product last week. We need to understand if these two things are related and what the fastest path to recovery is without taking the service down."
  "Our data science team accidentally deleted the production model weights from our shared storage last night. We have backups from 3 days ago but we have done 2 days of fine-tuning since then that is not backed up anywhere. The fine-tuning runs were logged to our experiment tracker but the actual checkpoint files are gone. Is there any way to recover the lost checkpoints? What should we do right now? We have a board demo in 18 hours that depends on this model."
  "We are getting CUDA out of memory errors on all our inference nodes simultaneously. The error is: RuntimeError: CUDA out of memory. Tried to allocate 2.50 GiB with 1.23 GiB left. This started happening after we deployed a new version of our application that sends longer prompts to the model. Our GPU nodes have 80GB of VRAM each and this was never a problem before. The application is serving 400 concurrent users and we cannot restart it during business hours. What are our options?"
  "Three of our kubernetes nodes are stuck in NotReady state after a cluster upgrade from 1.27 to 1.28. The upgrade was done by our cloud provider's managed service. The nodes show the following in kubectl describe: container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized. We have 47 other nodes that are fine. The affected nodes are running our vLLM inference workloads and we have active user sessions that will be dropped if we drain them."
)

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
  'max_tokens': 512,
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
