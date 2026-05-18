# ai-support-bot

A simple support agent demo that runs entirely on your machine using [Ollama](https://ollama.com) — no API key, no cloud, no cost.

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

## Running with Docker (recommended)

Everything — the agent and Ollama — runs as containers. No local Python or Ollama install needed.

```bash
# 1. Start both containers (pulls Ollama image automatically)
docker compose up -d

# 2. Pull a model into the Ollama sidecar (one-time)
docker compose exec ollama ollama pull llama3.2

# 3. Chat with the agent
docker compose run --rm agent

# Use a different model
MODEL=mistral docker compose run --rm agent
```

The `ollama_data` volume persists downloaded models between restarts.

## Running locally (without Docker)

Install and start [Ollama](https://ollama.com), then:

```bash
ollama pull llama3.2

poetry install
poetry run support-agent

# Use a different model
poetry run support-agent --model mistral
```

## Running tests

No Ollama connection needed — tests cover tool logic only:

```bash
python -m unittest discover tests -v
```

## Project structure

```
agent/
  agent.py   — SupportAgent class (ReAct loop over Ollama)
  tools.py   — Tool schemas + stub implementations
  main.py    — Interactive CLI
tests/
  test_tools.py — Unit tests (no LLM calls)
```

## Extending

- **Add knowledge base entries**: edit `_KB` in `tools.py`
- **Connect a real ticketing system**: replace the stub in `escalate_to_human()` with a call to Linear, Zendesk, or Slack
- **Swap the model**: pass `--model <name>` at the CLI, or any model you've pulled with `ollama pull`
