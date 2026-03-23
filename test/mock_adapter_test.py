"""Tests for the mock inference engine adapter.

Spawns mock_adapter.py as a subprocess and exercises the startup protocol
(heartbeat + ready), stdin watchdog, and command handling.

Uses only Python stdlib — no external dependencies.
"""
import json
import os
import subprocess
import time
import unittest

ADAPTER_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'priv', 'scripts', 'mock_adapter.py'
)


def _read_json_line(proc, timeout=5.0):
    """Read one JSON line from proc.stdout with a deadline.

    Uses readline() on the raw (unbuffered) file descriptor so the call
    blocks at the OS level without Python-level buffering interfering.
    The timeout is enforced by a separate timer thread that kills the process.
    """
    import threading

    result = []
    error = []

    def _reader():
        try:
            line = proc.stdout.readline()
            result.append(line)
        except Exception as e:
            error.append(e)

    t = threading.Thread(target=_reader, daemon=True)
    t.start()
    t.join(timeout=timeout)

    if t.is_alive():
        raise TimeoutError(f"Timed out waiting for JSON line after {timeout}s")
    if error:
        raise error[0]
    line = result[0] if result else b""
    if not line:
        raise EOFError("stdout closed unexpectedly")
    return json.loads(line.decode().strip())


def _start_adapter(*extra_args):
    """Start the adapter subprocess and return the Popen object."""
    return subprocess.Popen(
        ['python3', ADAPTER_PATH] + list(extra_args),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def _send(proc, msg):
    """Write a JSON message to the adapter's stdin."""
    proc.stdin.write((json.dumps(msg) + '\n').encode())
    proc.stdin.flush()


class TestStartupProtocol(unittest.TestCase):
    """Startup sequence: heartbeat(s) then ready."""

    def test_startup_sends_heartbeat_then_ready(self):
        """Adapter sends one heartbeat then ready immediately (no startup delay)."""
        proc = _start_adapter()
        try:
            hb = _read_json_line(proc, timeout=5)
            self.assertEqual(hb.get("type"), "heartbeat")
            self.assertEqual(hb.get("status"), "loading")
            self.assertIn("detail", hb)

            ready = _read_json_line(proc, timeout=5)
            self.assertEqual(ready.get("type"), "ready")
            self.assertEqual(ready.get("model"), "mock")
            self.assertEqual(ready.get("backend"), "mock")
        finally:
            proc.stdin.close()
            proc.wait(timeout=5)

    def test_startup_delay_sends_heartbeats(self):
        """With --startup-delay 2, adapter sends heartbeats before ready."""
        # ASSUMPTION: --heartbeat-interval is set low (0.3s) so we get at least
        # one extra heartbeat during the 2-second delay without making the test slow.
        proc = _start_adapter('--startup-delay', '0.9', '--heartbeat-interval', '0.3')
        try:
            messages = []
            # Collect messages until we see 'ready' or timeout
            for _ in range(20):
                msg = _read_json_line(proc, timeout=5)
                messages.append(msg)
                if msg.get("type") == "ready":
                    break

            types = [m["type"] for m in messages]
            heartbeats = [m for m in messages if m["type"] == "heartbeat"]
            self.assertIn("ready", types, f"Never got ready. Got: {types}")
            self.assertGreaterEqual(
                len(heartbeats), 2,
                f"Expected at least 2 heartbeats with startup-delay 0.9 and interval 0.3, got: {types}"
            )
            # ready must be last
            self.assertEqual(messages[-1]["type"], "ready")
        finally:
            proc.stdin.close()
            proc.wait(timeout=5)


class TestStdinWatchdog(unittest.TestCase):
    """Stdin watchdog: closing stdin must kill the adapter."""

    def test_stdin_close_kills_adapter(self):
        """Closing stdin causes adapter to exit (watchdog fires os._exit(1))."""
        proc = _start_adapter()
        try:
            # Wait for startup to complete
            _read_json_line(proc, timeout=5)  # heartbeat
            _read_json_line(proc, timeout=5)  # ready

            # Close stdin — watchdog thread should detect EOF and call os._exit(1)
            proc.stdin.close()

            try:
                ret = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                self.fail("Adapter did not exit after stdin was closed (watchdog failed)")

            # os._exit(1) produces exit code 1
            self.assertEqual(ret, 1, f"Expected exit code 1 from watchdog, got {ret}")
        except Exception:
            proc.kill()
            proc.wait()
            raise


class TestCommandHandling(unittest.TestCase):
    """Command handlers still work correctly after startup."""

    def setUp(self):
        self.proc = _start_adapter()
        # Drain startup messages
        _read_json_line(self.proc, timeout=5)  # heartbeat
        _read_json_line(self.proc, timeout=5)  # ready

    def tearDown(self):
        try:
            self.proc.kill()
        except Exception:
            pass
        self.proc.wait(timeout=3)

    def test_health(self):
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "health")
        self.assertEqual(resp["status"], "ok")
        self.assertEqual(resp["gpu_util"], 0.0)
        self.assertEqual(resp["mem_used_gb"], 0.0)
        self.assertEqual(resp["mem_total_gb"], 80.0)

    def test_memory(self):
        _send(self.proc, {"type": "memory"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "memory")
        self.assertEqual(resp["total_gb"], 80.0)
        self.assertEqual(resp["used_gb"], 0.0)
        self.assertEqual(resp["available_gb"], 80.0)

    def test_generate(self):
        _send(self.proc, {"type": "generate", "id": "req-001", "prompt": "Hello", "params": {}})
        responses = []
        for _ in range(6):
            responses.append(_read_json_line(self.proc, timeout=5))

        expected_tokens = ["Hello", "from", "Loom", "mock", "adapter"]
        for i, token_text in enumerate(expected_tokens):
            resp = responses[i]
            self.assertEqual(resp["type"], "token")
            self.assertEqual(resp["id"], "req-001")
            self.assertEqual(resp["token_id"], i + 1)
            self.assertEqual(resp["text"], token_text)
            self.assertFalse(resp["finished"])

        done = responses[5]
        self.assertEqual(done["type"], "done")
        self.assertEqual(done["id"], "req-001")
        self.assertEqual(done["tokens_generated"], 5)
        self.assertIn("time_ms", done)

    def test_unknown_type(self):
        _send(self.proc, {"type": "bogus"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "unknown_type")
        self.assertIn("bogus", resp["message"])

    def test_missing_type(self):
        _send(self.proc, {"no_type_field": True})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "missing_type")

    def test_generate_missing_id(self):
        _send(self.proc, {"type": "generate", "prompt": "Hi"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "missing_field")
        self.assertIn("missing 'id' field", resp["message"])

    def test_invalid_json(self):
        self.proc.stdin.write(b"{this is not valid json\n")
        self.proc.stdin.flush()
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "invalid_json")

    def test_cancel_returns_no_response(self):
        # Send cancel then health to verify cancel produced no response
        _send(self.proc, {"type": "cancel", "id": "req-1"})
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=5)
        # Should get health response, not a cancel response
        self.assertEqual(resp["type"], "health")

    def test_multiple_messages_in_session(self):
        _send(self.proc, {"type": "health"})
        _send(self.proc, {"type": "memory"})
        _send(self.proc, {"type": "health"})
        r1 = _read_json_line(self.proc, timeout=5)
        r2 = _read_json_line(self.proc, timeout=5)
        r3 = _read_json_line(self.proc, timeout=5)
        self.assertEqual(r1["type"], "health")
        self.assertEqual(r2["type"], "memory")
        self.assertEqual(r3["type"], "health")

    def test_blank_lines_ignored(self):
        self.proc.stdin.write(b"\n\n")
        self.proc.stdin.flush()
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "health")


class TestShutdown(unittest.TestCase):
    """Shutdown command causes clean exit."""

    def test_shutdown_exits_cleanly(self):
        """Shutdown command causes clean exit with code 0."""
        proc = _start_adapter()
        try:
            _read_json_line(proc, timeout=5)  # heartbeat
            _read_json_line(proc, timeout=5)  # ready

            _send(proc, {"type": "shutdown"})

            try:
                ret = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                self.fail("Adapter did not exit after shutdown command")

            self.assertEqual(ret, 0, f"Expected clean exit (0) after shutdown, got {ret}")

            stderr = proc.stderr.read().decode()
            self.assertIn("shutdown requested", stderr)
        except Exception:
            proc.kill()
            proc.wait()
            raise


if __name__ == '__main__':
    unittest.main()
