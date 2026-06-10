#!/usr/bin/env bash
# Synthetic load generator for the KV cache saturation demo.
#
# Fires CONCURRENCY parallel /chat requests in a loop until stopped.
# Each request uses a unique session_id and a long support question
# to maximise KV block consumption per request.
#
# Usage:
#   bash scripts/load.sh              # defaults: 16 parallel, localhost:8080
#   CONCURRENCY=24 bash scripts/load.sh
#   AGENT_URL=http://localhost:8080 bash scripts/load.sh

set -euo pipefail

AGENT_URL="${AGENT_URL:-http://localhost:8080}"
CONCURRENCY="${CONCURRENCY:-16}"
ROUND=0

MESSAGES=(
  "I have been trying to reset my password for the last three days. Every time I click the reset link it says the link has expired even though I just requested it. I have cleared my cache, tried different browsers, and even a different device. Nothing works. My team is locked out of the platform and we have a deadline tomorrow morning. This is extremely urgent — please help."
  "Our API key stopped working overnight. We did not rotate it, we did not change any settings. The error we get is 401 Unauthorized on every single request. We have triple-checked the key is correct. We are running automated pipelines that are now all failing. How do we get a new key issued immediately?"
  "I need to understand exactly how GPU quota is calculated for our organisation. We have 8 nodes, each with 4 GPUs. We were told we have a quota of 16 GPUs but we can only ever schedule 12 at a time. The docs are unclear. Can you explain the quota model in detail and tell me how to request an increase?"
  "We are seeing intermittent SSH connection failures to our compute nodes. The errors appear randomly — sometimes connections succeed, sometimes they fail with connection refused even though the nodes are running. We have checked firewall rules, verified our public keys are registered, and confirmed port 22 is open. What else could cause this?"
  "I need a full breakdown of our billing for the last 6 months. We think we are being charged for resources we deprovisioned in January but the invoice does not itemise them clearly enough to confirm. Can you pull the billing history and explain each line item?"
)

fire_one() {
  local session_id msg_idx url body
  session_id="load-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')"
  msg_idx=$(( RANDOM % ${#MESSAGES[@]} ))
  url="${AGENT_URL}/chat"
  body=$(printf '{"session_id":"%s","message":"%s"}' \
    "$session_id" \
    "${MESSAGES[$msg_idx]//\"/\\\"}")

  local start end elapsed status
  start=$(date +%s%3N)
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 120 \
    -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "$body" || echo "000")
  end=$(date +%s%3N)
  elapsed=$(( end - start ))

  printf "[%s] session=%-36s status=%s latency=%dms\n" \
    "$(date +%H:%M:%S)" "$session_id" "$status" "$elapsed"
}

export -f fire_one
export AGENT_URL MESSAGES

echo "Load generator starting — target: $AGENT_URL, concurrency: $CONCURRENCY"
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
