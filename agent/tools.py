"""Tool definitions and stub implementations for the support agent."""

import json
import os
import uuid

# --- Knowledge base (replace with a real DB/vector store later) ---

_KB: dict[str, str] = {
    "password reset": "Go to Settings → Security → Reset Password. A reset link is sent to your email.",
    "cancel subscription": "Subscriptions can be cancelled from Settings → Billing → Cancel Plan.",
    "api key": "API keys live under Settings → Developer → API Keys. Rotate if compromised.",
    "gpu quota": "GPU quotas are set per-org. Contact your account manager to request an increase.",
    "ssh connection": "Ensure port 22 is open and your public key is added under Settings → SSH Keys.",
    "refund": "Refund requests require human review.",
    "billing": "Billing questions must be handled by the finance team.",
}


def search_knowledge_base(query: str | dict) -> dict:
    # some models pass {"query": "..."} as a nested object instead of a plain string
    if isinstance(query, dict):
        query = query.get("query", "")
    q = str(query).lower()
    results = [
        {"topic": topic, "answer": answer}
        for topic, answer in _KB.items()
        if any(word in q for word in topic.split())
    ]
    return {"found": bool(results), "results": results}


def get_ticket_status(ticket_id: str) -> dict:
    stub = {
        "TKT-1001": {"status": "open", "assigned_to": "Alice"},
        "TKT-1002": {"status": "resolved", "resolution": "Password reset completed."},
    }
    if ticket_id in stub:
        return {"found": True, "ticket_id": ticket_id, **stub[ticket_id]}
    return {"found": False, "ticket_id": ticket_id}


def get_vllm_metrics(last_n: int = 10) -> dict:
    metrics_file = os.environ.get("METRICS_FILE", "logs/kv-metrics.jsonl")
    if not os.path.exists(metrics_file):
        return {"error": "No metrics file found. Is the load generator running?", "snapshots": []}
    with open(metrics_file) as f:
        lines = f.readlines()
    snapshots = [json.loads(l) for l in lines[-last_n:] if l.strip()]
    if not snapshots:
        return {"error": "Metrics file is empty.", "snapshots": []}
    latest = snapshots[-1]
    peak_gpu = max(s["gpu_kv_pct"] for s in snapshots)
    peak_pending = max(s["pending"] for s in snapshots)
    return {
        "snapshots": snapshots,
        "latest": latest,
        "peak_gpu_kv_pct": peak_gpu,
        "peak_pending_requests": peak_pending,
        "saturating": peak_gpu > 50,
    }


def escalate_to_human(reason: str, summary: str, urgency: str) -> dict:
    ticket_id = f"TKT-{uuid.uuid4().hex[:6].upper()}"
    print(f"\n[ESCALATION] {ticket_id} | urgency={urgency} | reason={reason}")
    return {
        "escalated": True,
        "ticket_id": ticket_id,
        "message": f"Escalated to a human agent (ticket {ticket_id}). Someone will follow up shortly.",
    }


# --- OpenAI-style function schemas for Ollama ---

TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "search_knowledge_base",
            "description": (
                "Search the support knowledge base for an answer. "
                "Always try this before escalating."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "The user's question or topic."}
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_ticket_status",
            "description": "Look up the status of an existing support ticket by ID.",
            "parameters": {
                "type": "object",
                "properties": {
                    "ticket_id": {"type": "string", "description": "Ticket ID, e.g. TKT-1234."}
                },
                "required": ["ticket_id"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_vllm_metrics",
            "description": (
                "Read recent vLLM KV cache metrics from the local snapshot file. "
                "Use this to diagnose latency regressions — look for high gpu_kv_pct "
                "and pending_requests > 0 which indicate KV cache saturation."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "last_n": {
                        "type": "integer",
                        "description": "Number of recent snapshots to return (default 10).",
                    }
                },
                "required": [],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "escalate_to_human",
            "description": (
                "Escalate to a human agent. Use when: the knowledge base has no answer, "
                "the user asks for a human, or the issue involves billing/refunds/security."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "reason": {"type": "string", "description": "Why escalating."},
                    "summary": {"type": "string", "description": "Conversation summary for the human agent."},
                    "urgency": {"type": "string", "enum": ["low", "medium", "high"]},
                },
                "required": ["reason", "summary", "urgency"],
            },
        },
    },
]


def dispatch(name: str, arguments: str) -> str:
    args = json.loads(arguments)
    if name == "search_knowledge_base":
        return json.dumps(search_knowledge_base(**args))
    if name == "get_ticket_status":
        return json.dumps(get_ticket_status(**args))
    if name == "get_vllm_metrics":
        return json.dumps(get_vllm_metrics(**args))
    if name == "escalate_to_human":
        return json.dumps(escalate_to_human(**args))
    raise ValueError(f"Unknown tool: {name}")
