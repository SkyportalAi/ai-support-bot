"""Support agent: ReAct loop over vLLM using the OpenAI-compatible API."""

import os
from openai import OpenAI
from agent.tools import TOOL_SCHEMAS, dispatch

SYSTEM_PROMPT = """You are a helpful support agent for SkyPortal.

Steps to follow:
1. Search the knowledge base first — always try this before anything else.
2. If you find a clear answer, respond directly.
3. Escalate to a human when:
   - The knowledge base has no answer.
   - The user is frustrated or explicitly asks for a human.
   - The issue involves billing, refunds, or account security.

Be concise and empathetic. If you escalate, give the user their ticket ID."""

DEFAULT_MODEL = "meta-llama/Llama-3.1-8B-Instruct"
VLLM_BASE_URL = "http://vllm-service.default.svc.cluster.local:8000/v1"


class SupportAgent:
    def __init__(
        self,
        model: str | None = None,
        base_url: str | None = None,
    ):
        model = model or os.environ.get("MODEL", DEFAULT_MODEL)
        base_url = base_url or os.environ.get("VLLM_BASE_URL", VLLM_BASE_URL)
        self._client = OpenAI(base_url=base_url, api_key="none")
        self._model = model
        self._messages: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]
        self.escalated = False

    def chat(self, user_message: str) -> str:
        if self.escalated:
            return "This conversation has been escalated. A human agent will be in touch."

        self._messages.append({"role": "user", "content": user_message})

        while True:
            response = self._client.chat.completions.create(
                model=self._model,
                messages=self._messages,
                tools=TOOL_SCHEMAS,
                tool_choice="auto",
            )

            msg = response.choices[0].message
            self._messages.append(msg)

            if not msg.tool_calls:
                return msg.content or "(No response)"

            for call in msg.tool_calls:
                result = dispatch(call.function.name, call.function.arguments)

                if call.function.name == "escalate_to_human":
                    self.escalated = True

                self._messages.append({
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result,
                })

    def reset(self) -> None:
        self._messages = [{"role": "system", "content": SYSTEM_PROMPT}]
        self.escalated = False
