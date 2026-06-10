#!/usr/bin/env python3
"""
Stream vLLM kubectl logs and write structured JSONL to a file.

Captures three record types:
  {"type": "metric",  "ts": ..., "gpu_kv_pct": ..., "running": ..., "pending": ...}
  {"type": "request", "ts": ..., "request_id": ..., "prompt_tokens": ...}
  {"type": "raw",     "ts": ..., "line": ...}

Usage:
  kubectl logs -n vllm -l app=vllm -f | python3 scripts/vllm_logger.py logs/kv-metrics.jsonl
"""

import sys
import re
import json
import time

metrics_file = sys.argv[1] if len(sys.argv) > 1 else "logs/kv-metrics.jsonl"


def write(record: dict):
    with open(metrics_file, "a") as f:
        f.write(json.dumps(record) + "\n")


def ts() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


for raw_line in sys.stdin:
    line = raw_line.rstrip()
    now = ts()

    # Always echo the raw line to stdout so terminal still shows logs
    print(line, flush=True)

    # Metrics line
    if "GPU KV cache usage" in line:
        run  = re.search(r"Running: (\d+)", line)
        pend = re.search(r"Pending: (\d+)", line)
        swap = re.search(r"Swapped: (\d+)", line)
        gpu  = re.search(r"GPU KV cache usage: ([0-9.]+)%", line)
        gen  = re.search(r"Avg generation throughput: ([0-9.]+)", line)
        prompt = re.search(r"Avg prompt throughput: ([0-9.]+)", line)
        if gpu:
            pct = float(gpu.group(1))
            record = {
                "type": "metric",
                "ts": now,
                "gpu_kv_pct": pct,
                "running": int(run.group(1)) if run else 0,
                "pending": int(pend.group(1)) if pend else 0,
                "swapped": int(swap.group(1)) if swap else 0,
                "gen_tokens_per_s": float(gen.group(1)) if gen else 0.0,
                "prompt_tokens_per_s": float(prompt.group(1)) if prompt else 0.0,
                "saturating": pct > 50,
            }
            write(record)
        continue

    # Request received
    if "Received request" in line:
        req_id = re.search(r"Received request (\S+):", line)
        tokens = re.search(r"prompt_token_ids: \[([^\]]+)\]", line)
        record = {
            "type": "request",
            "ts": now,
            "request_id": req_id.group(1) if req_id else None,
            "prompt_tokens": len(tokens.group(1).split(",")) if tokens else None,
        }
        write(record)
        continue

    # Request finished
    if "Finished request" in line:
        req_id = re.search(r"Finished request (\S+)", line)
        record = {
            "type": "finished",
            "ts": now,
            "request_id": req_id.group(1) if req_id else None,
        }
        write(record)
        continue

    # Write all other non-empty lines as raw
    if line.strip():
        write({"type": "raw", "ts": now, "line": line})
