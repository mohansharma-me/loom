"""Tests for the mock inference engine adapter.

Spawns mock_adapter.py as a subprocess and exercises the line-delimited
JSON protocol: generate, health, memory, and unknown message types.
"""
import json
import os
import subprocess
import unittest

ADAPTER_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'priv', 'scripts', 'mock_adapter.py'
)


class MockAdapterTest(unittest.TestCase):
    """Test the mock adapter's JSON protocol responses."""

    def _send_receive(self, message):
        """Send a JSON message to the adapter and return parsed responses."""
        proc = subprocess.Popen(
            ['python3', ADAPTER_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stdout, stderr = proc.communicate(
            input=json.dumps(message) + '\n', timeout=5
        )
        lines = [l for l in stdout.strip().split('\n') if l]
        return [json.loads(line) for line in lines]

    def _send_receive_multi(self, messages):
        """Send multiple JSON messages in one session, return all responses."""
        proc = subprocess.Popen(
            ['python3', ADAPTER_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        input_data = '\n'.join(json.dumps(m) for m in messages) + '\n'
        stdout, stderr = proc.communicate(input=input_data, timeout=5)
        lines = [l for l in stdout.strip().split('\n') if l]
        return [json.loads(line) for line in lines]

    def test_health(self):
        responses = self._send_receive({"type": "health"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "health")
        self.assertEqual(resp["status"], "ok")
        self.assertEqual(resp["gpu_util"], 0.0)
        self.assertEqual(resp["mem_used_gb"], 0.0)

    def test_memory(self):
        responses = self._send_receive({"type": "memory"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "memory")
        self.assertEqual(resp["total_gb"], 80.0)
        self.assertEqual(resp["used_gb"], 0.0)
        self.assertEqual(resp["available_gb"], 80.0)

    def test_generate(self):
        responses = self._send_receive(
            {"type": "generate", "id": "req-001", "prompt": "Hello", "params": {}},
        )
        self.assertEqual(len(responses), 6)

        # First 5 are token messages
        expected_tokens = ["Hello", "from", "Loom", "mock", "adapter"]
        for i, token_text in enumerate(expected_tokens):
            resp = responses[i]
            self.assertEqual(resp["type"], "token")
            self.assertEqual(resp["id"], "req-001")
            self.assertEqual(resp["token_id"], i + 1)
            self.assertEqual(resp["text"], token_text)
            self.assertFalse(resp["finished"])

        # Last is done message
        done = responses[5]
        self.assertEqual(done["type"], "done")
        self.assertEqual(done["id"], "req-001")
        self.assertEqual(done["tokens_generated"], 5)
        self.assertIn("time_ms", done)

    def test_unknown_type(self):
        responses = self._send_receive({"type": "bogus"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "error")
        self.assertIn("bogus", resp["message"])

    def test_missing_type(self):
        responses = self._send_receive({"no_type_field": True})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "error")

    def test_generate_missing_id(self):
        responses = self._send_receive({"type": "generate", "prompt": "Hi"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "error")

    def test_multiple_messages_in_session(self):
        """Verify the adapter handles multiple messages in a single session."""
        responses = self._send_receive_multi([
            {"type": "health"},
            {"type": "memory"},
            {"type": "health"},
        ])
        self.assertEqual(len(responses), 3)
        self.assertEqual(responses[0]["type"], "health")
        self.assertEqual(responses[1]["type"], "memory")
        self.assertEqual(responses[2]["type"], "health")


if __name__ == '__main__':
    unittest.main()
