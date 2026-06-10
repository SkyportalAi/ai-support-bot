"""Interactive CLI for the support agent."""

import argparse
from agent.agent import SupportAgent, DEFAULT_MODEL


def main() -> None:
    parser = argparse.ArgumentParser(description="SkyPortal AI Support Agent (vLLM)")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="vLLM model name")
    args = parser.parse_args()

    print(f"SkyPortal Support Agent [{args.model}]")
    print("Commands: 'exit' to quit, 'reset' to start a new conversation\n")

    agent = SupportAgent(model=args.model)

    while True:
        try:
            user_input = input("You: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nGoodbye.")
            break

        if not user_input:
            continue
        if user_input.lower() == "exit":
            break
        if user_input.lower() == "reset":
            agent.reset()
            print("Conversation reset.\n")
            continue

        response = agent.chat(user_input)
        print(f"\nAgent: {response}\n")

        if agent.escalated:
            print("(Handed off to human agent. Goodbye.)")
            break


if __name__ == "__main__":
    main()
