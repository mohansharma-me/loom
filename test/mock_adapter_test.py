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

    def _send_receive_raw(self, raw_input):
        """Send raw text to the adapter and return parsed responses."""
        proc = subprocess.Popen(
            ['python3', ADAPTER_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            stdout, stderr = proc.communicate(input=raw_input, timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            stdout, stderr = proc.communicate()
            self.fail(
                f"Adapter timed out after 5s.\n"
                f"stderr:\n{stderr}\nstdout:\n{stdout}"
            )
        if proc.returncode != 0:
            self.fail(
                f"Adapter exited with code {proc.returncode}.\n"
                f"stderr:\n{stderr}\nstdout:\n{stdout}"
            )
        lines = [l for l in stdout.strip().split('\n') if l]
        parsed = []
        for line in lines:
            try:
                parsed.append(json.loads(line))
            except json.JSONDecodeError as e:
                self.fail(
                    f"Non-JSON output: {line!r}\nAll stdout: {stdout!r}\nError: {e}"
                )
        return parsed

    def _send_receive(self, message):
        """Send a single JSON message to the adapter and return parsed responses."""
        return self._send_receive_raw(json.dumps(message) + '\n')

    def _send_receive_multi(self, messages):
        """Send multiple JSON messages in one session, return all responses."""
        input_data = '\n'.join(json.dumps(m) for m in messages) + '\n'
        return self._send_receive_raw(input_data)

    def test_health(self):
        responses = self._send_receive({"type": "health"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "health")
        self.assertEqual(resp["status"], "ok")
        self.assertEqual(resp["gpu_util"], 0.0)
        self.assertEqual(resp["mem_used_gb"], 0.0)
        self.assertEqual(resp["mem_total_gb"], 80.0)

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
        self.assertEqual(resp["code"], "unknown_type")
        self.assertIn("bogus", resp["message"])

    def test_missing_type(self):
        responses = self._send_receive({"no_type_field": True})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "missing_type")
        self.assertIn("missing 'type' field", resp["message"])

    def test_generate_missing_id(self):
        responses = self._send_receive({"type": "generate", "prompt": "Hi"})
        self.assertEqual(len(responses), 1)
        resp = responses[0]
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "missing_field")
        self.assertIn("missing 'id' field", resp["message"])

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


    def test_invalid_json(self):
        """Verify the adapter handles malformed JSON gracefully."""
        responses = self._send_receive_raw("{this is not valid json\n")
        self.assertEqual(len(responses), 1)
        self.assertEqual(responses[0]["type"], "error")
        self.assertEqual(responses[0]["code"], "invalid_json")
        self.assertIn("invalid JSON", responses[0]["message"])

    def test_cancel_returns_no_response(self):
        """Cancel is fire-and-forget, no response expected."""
        responses = self._send_receive({"type": "cancel", "id": "req-1"})
        self.assertEqual(responses, [])

    def test_health_includes_mem_total(self):
        """Health response includes mem_total_gb field."""
        responses = self._send_receive({"type": "health"})
        self.assertEqual(len(responses), 1)
        self.assertIn("mem_total_gb", responses[0])
        self.assertEqual(responses[0]["mem_total_gb"], 80.0)

    def test_error_includes_code_field(self):
        """All error responses include a code field."""
        responses = self._send_receive_raw("not json\n")
        self.assertEqual(len(responses), 1)
        self.assertEqual(responses[0]["type"], "error")
        self.assertIn("code", responses[0])
        self.assertEqual(responses[0]["code"], "invalid_json")

    def test_blank_lines_ignored(self):
        """Verify blank lines between messages produce no output."""
        input_data = "\n\n" + json.dumps({"type": "health"}) + "\n\n\n"
        responses = self._send_receive_raw(input_data)
        self.assertEqual(len(responses), 1)
        self.assertEqual(responses[0]["type"], "health")

    def test_clean_exit_on_eof(self):
        """Verify the adapter exits cleanly when stdin closes."""
        proc = subprocess.Popen(
            ['python3', ADAPTER_PATH],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stdout, stderr = proc.communicate(input="", timeout=5)
        self.assertEqual(proc.returncode, 0)


if __name__ == '__main__':
    unittest.main()
