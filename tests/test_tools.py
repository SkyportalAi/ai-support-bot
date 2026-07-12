"""Unit tests for tool implementations — no Ollama connection required."""

import json
import unittest
from agent.tools import search_knowledge_base, get_ticket_status, escalate_to_human, dispatch


class TestSearchKnowledgeBase(unittest.TestCase):
    def test_known_topic_returns_results(self):
        result = search_knowledge_base("password reset")
        self.assertTrue(result["found"])
        self.assertGreater(len(result["results"]), 0)

    def test_unknown_topic_returns_not_found(self):
        result = search_knowledge_base("quantum entanglement please help")
        self.assertFalse(result["found"])
        self.assertEqual(result["results"], [])

    def test_partial_match(self):
        result = search_knowledge_base("how do I reset my password?")
        self.assertTrue(result["found"])


class TestGetTicketStatus(unittest.TestCase):
    def test_existing_ticket(self):
        result = get_ticket_status("TKT-1001")
        self.assertTrue(result["found"])
        self.assertIn("status", result)

    def test_missing_ticket(self):
        result = get_ticket_status("TKT-9999")
        self.assertFalse(result["found"])


class TestEscalateToHuman(unittest.TestCase):
    def test_creates_ticket(self):
        result = escalate_to_human("billing question", "user wants refund", "medium")
        self.assertTrue(result["escalated"])
        self.assertTrue(result["ticket_id"].startswith("TKT-"))

    def test_urgency_values(self):
        for urgency in ("low", "medium", "high"):
            result = escalate_to_human("test", "test summary", urgency)
            self.assertTrue(result["escalated"])


class TestDispatch(unittest.TestCase):
    def test_dispatch_search(self):
        result = json.loads(dispatch("search_knowledge_base", '{"query": "api key"}'))
        self.assertIn("found", result)

    def test_dispatch_escalate(self):
        result = json.loads(dispatch("escalate_to_human", '{"reason": "x", "summary": "y", "urgency": "low"}'))
        self.assertTrue(result["escalated"])

    def test_unknown_tool_returns_error(self):
        # dispatch() must never raise — an ill-behaved local model's tool call
        # is remote input, and a bare exception here kills the whole chat
        # request (agent.chat()'s multiprocessing.Process has no top-level
        # handler for it) instead of giving the model a chance to retry.
        result = json.loads(dispatch("nonexistent_tool", "{}"))
        self.assertIn("error", result)

    def test_missing_required_argument_returns_error(self):
        result = json.loads(dispatch("get_ticket_status", "{}"))
        self.assertIn("error", result)

    def test_unexpected_argument_returns_error(self):
        result = json.loads(dispatch("search_knowledge_base", '{"query": "api key", "bogus": 1}'))
        self.assertIn("error", result)

    def test_malformed_json_returns_error(self):
        result = json.loads(dispatch("search_knowledge_base", '{"query": "api key"'))
        self.assertIn("error", result)


if __name__ == "__main__":
    unittest.main()
