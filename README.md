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

## Prerequisites

Install and start [Ollama](https://ollama.com), then pull a model:

```bash
ollama pull llama3.2
```

## Quickstart

```bash
# Install dependencies
poetry install

# Run the interactive CLI
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
