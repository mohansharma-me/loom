"""Tests for LoomAdapterBase via the mock adapter subprocess.

Spawns loom_adapter_mock.py as a subprocess and exercises the base class
through the JSON wire protocol: startup sequence, command handling, error
handling, shutdown, stdin watchdog, and load failure.

Uses only Python stdlib — no external dependencies.
"""
import json
import os
import subprocess
import sys
import threading
import unittest

MOCK_ADAPTER_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'priv', 'python', 'loom_adapter_mock.py'
)


def _read_json_line(proc, timeout=5.0):
    """Read one JSON line from proc.stdout with a deadline.

    Uses readline() on the raw stdout pipe so the call blocks at the OS level.
    Timeout is enforced by a daemon thread; if the deadline passes the
    caller gets a TimeoutError rather than hanging forever.
    """
    result = []
    error = []

    def _reader():
        try:
            line = proc.stdout.readline()
            result.append(line)
        except Exception as exc:
            error.append(exc)

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
    """Start loom_adapter_mock.py as a subprocess and return the Popen object."""
    return subprocess.Popen(
        [sys.executable, MOCK_ADAPTER_PATH, '--model', 'mock'] + list(extra_args),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def _send(proc, msg):
    """Write a JSON-encoded message followed by a newline to the adapter stdin."""
    proc.stdin.write((json.dumps(msg) + '\n').encode())
    proc.stdin.flush()


# ---------------------------------------------------------------------------
# TestStartupProtocol
# ---------------------------------------------------------------------------

class TestStartupProtocol(unittest.TestCase):
    """Startup sequence: first heartbeat, then ready message."""

    def test_startup_sends_heartbeat_then_ready(self):
        """Adapter sends heartbeat (status=loading) then ready (model=mock, backend=mock)."""
        proc = _start_adapter()
        try:
            hb = _read_json_line(proc, timeout=5)
            self.assertEqual(hb.get("type"), "heartbeat")
            self.assertEqual(hb.get("status"), "loading")

            ready = _read_json_line(proc, timeout=5)
            self.assertEqual(ready.get("type"), "ready")
            self.assertEqual(ready.get("model"), "mock")
            self.assertEqual(ready.get("backend"), "mock")
        finally:
            proc.stdin.close()
            proc.wait(timeout=5)

    def test_startup_delay_sends_heartbeats(self):
        """With --startup-delay 1.5 and --heartbeat-interval 0.3, adapter sends >=2 heartbeats before ready."""
        # ASSUMPTION: A 1.5s startup delay with 0.3s heartbeat interval produces
        # at least 2 heartbeats (initial + at least one periodic) before ready.
        proc = _start_adapter('--startup-delay', '1.5', '--heartbeat-interval', '0.3')
        try:
            messages = []
            # Collect messages until we see 'ready' or exhaust 20 reads
            for _ in range(20):
                msg = _read_json_line(proc, timeout=10)
                messages.append(msg)
                if msg.get("type") == "ready":
                    break

            types = [m["type"] for m in messages]
            heartbeats = [m for m in messages if m["type"] == "heartbeat"]

            self.assertIn("ready", types, f"Never received ready. Got: {types}")
            self.assertGreaterEqual(
                len(heartbeats), 2,
                f"Expected >=2 heartbeats with startup-delay=1.5 and interval=0.3, got: {types}"
            )
            # ready must be the last message
            self.assertEqual(messages[-1]["type"], "ready")
        finally:
            proc.stdin.close()
            proc.wait(timeout=10)


# ---------------------------------------------------------------------------
# TestCommandHandling
# ---------------------------------------------------------------------------

class TestCommandHandling(unittest.TestCase):
    """Command handlers (health, memory, generate, cancel) after startup."""

    def setUp(self):
        self.proc = _start_adapter()
        # Drain startup messages so tests begin in command-loop state
        _read_json_line(self.proc, timeout=5)  # heartbeat
        _read_json_line(self.proc, timeout=5)  # ready

    def tearDown(self):
        try:
            self.proc.kill()
        except Exception:
            pass
        self.proc.wait(timeout=3)

    def test_health(self):
        """Health command returns type=health, status=ok, zeroed GPU stats."""
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "health")
        self.assertEqual(resp["status"], "ok")
        self.assertEqual(resp["gpu_util"], 0.0)
        self.assertEqual(resp["mem_used_gb"], 0.0)
        self.assertEqual(resp["mem_total_gb"], 80.0)

    def test_memory(self):
        """Memory command returns type=memory with 80 GB total and 0 used."""
        _send(self.proc, {"type": "memory"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "memory")
        self.assertEqual(resp["total_gb"], 80.0)
        self.assertEqual(resp["used_gb"], 0.0)
        self.assertEqual(resp["available_gb"], 80.0)

    def test_generate(self):
        """Generate streams 5 token messages then a done message."""
        _send(self.proc, {"type": "generate", "id": "req-001", "prompt": "Hello", "params": {}})

        expected_texts = ["Hello", "from", "Loom", "mock", "adapter"]
        responses = [_read_json_line(self.proc, timeout=5) for _ in range(6)]

        # Verify each token message
        for i, expected_text in enumerate(expected_texts):
            tok = responses[i]
            self.assertEqual(tok["type"], "token", f"responses[{i}] type mismatch")
            self.assertEqual(tok["id"], "req-001")
            self.assertEqual(tok["token_id"], i + 1)
            self.assertEqual(tok["text"], expected_text)
            self.assertFalse(tok["finished"])

        # Verify done message
        done = responses[5]
        self.assertEqual(done["type"], "done")
        self.assertEqual(done["id"], "req-001")
        self.assertEqual(done["tokens_generated"], 5)
        self.assertIn("time_ms", done)

    def test_cancel_returns_no_response(self):
        """Cancel produces no response; the next response is from the following health command."""
        _send(self.proc, {"type": "cancel", "id": "req-1"})
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=5)
        # Cancel is fire-and-forget: first readable response must be health
        self.assertEqual(resp["type"], "health")

    def test_multiple_messages_in_session(self):
        """Three sequential commands return three responses in order."""
        _send(self.proc, {"type": "health"})
        _send(self.proc, {"type": "memory"})
        _send(self.proc, {"type": "health"})
        r1 = _read_json_line(self.proc, timeout=5)
        r2 = _read_json_line(self.proc, timeout=5)
        r3 = _read_json_line(self.proc, timeout=5)
        self.assertEqual(r1["type"], "health")
        self.assertEqual(r2["type"], "memory")
        self.assertEqual(r3["type"], "health")


# ---------------------------------------------------------------------------
# TestErrorHandling
# ---------------------------------------------------------------------------

class TestErrorHandling(unittest.TestCase):
    """Protocol error responses for malformed or unknown inputs."""

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

    def test_invalid_json(self):
        """Sending raw invalid JSON produces an error with code=invalid_json."""
        self.proc.stdin.write(b"{this is not valid json\n")
        self.proc.stdin.flush()
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "invalid_json")

    def test_missing_type(self):
        """JSON without a 'type' field produces code=missing_type."""
        _send(self.proc, {"no_type_field": True})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "missing_type")

    def test_unknown_type(self):
        """An unrecognised type value produces code=unknown_type with the type in message."""
        _send(self.proc, {"type": "bogus"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "unknown_type")
        self.assertIn("bogus", resp["message"])

    def test_generate_missing_id(self):
        """A generate command without 'id' produces code=missing_field."""
        _send(self.proc, {"type": "generate", "prompt": "Hi"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "missing_field")

    def test_error_without_request_has_null_id(self):
        """A protocol error not tied to a request has id=null (Python None)."""
        # ASSUMPTION: unknown_type errors use msg.get("id") as request_id.
        # When the message has no 'id' field, msg.get("id") returns None,
        # which json.dumps serializes as null, decoded as Python None.
        _send(self.proc, {"type": "bogus"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertIsNone(resp["id"])

    def test_blank_lines_ignored(self):
        """Blank lines sent before a valid command are silently discarded."""
        self.proc.stdin.write(b"\n\n")
        self.proc.stdin.flush()
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "health")


# ---------------------------------------------------------------------------
# TestShutdown
# ---------------------------------------------------------------------------

class TestShutdown(unittest.TestCase):
    """Shutdown command produces a clean exit."""

    def test_shutdown_exits_cleanly(self):
        """Shutdown command causes the adapter to exit with code 0."""
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

            self.assertEqual(ret, 0, f"Expected exit code 0 after shutdown, got {ret}")
        except Exception:
            proc.kill()
            proc.wait()
            raise


# ---------------------------------------------------------------------------
# TestStdinWatchdog
# ---------------------------------------------------------------------------

class TestStdinWatchdog(unittest.TestCase):
    """Closing stdin triggers the watchdog and terminates the adapter."""

    def test_stdin_close_kills_adapter(self):
        """Closing stdin causes the watchdog thread to call os._exit(1)."""
        proc = _start_adapter()
        try:
            _read_json_line(proc, timeout=5)  # heartbeat
            _read_json_line(proc, timeout=5)  # ready

            proc.stdin.close()

            try:
                ret = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                self.fail("Adapter did not exit after stdin was closed (watchdog failed)")

            self.assertEqual(ret, 1, f"Expected exit code 1 from watchdog, got {ret}")
        except Exception:
            proc.kill()
            proc.wait()
            raise


# ---------------------------------------------------------------------------
# TestLoadFailure
# ---------------------------------------------------------------------------

class TestLoadFailure(unittest.TestCase):
    """--fail-on-load exercises the os._exit(2) error path."""

    def test_load_failure_exits_with_code_2(self):
        """When load_model() raises, the adapter exits with code 2."""
        # ASSUMPTION: --fail-on-load raises immediately before the startup delay,
        # so the adapter still sends the initial heartbeat before failing.
        proc = _start_adapter('--fail-on-load')
        try:
            hb = _read_json_line(proc, timeout=5)
            self.assertEqual(hb.get("type"), "heartbeat")

            try:
                ret = proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                self.fail("Adapter did not exit after load_model() failure")

            self.assertEqual(ret, 2, f"Expected exit code 2 on load failure, got {ret}")
        except Exception:
            proc.kill()
            proc.wait()
            raise


class TestCancelDuringGenerate(unittest.TestCase):
    """Cancel semantics during generation.

    NOTE: The P0 command loop is sequential -- cancel commands are queued
    while generate() is running and processed after it completes. True
    concurrent cancel-during-generate requires the command loop to dispatch
    generate as a background task (P1 scope). These tests verify the cancel
    protocol works correctly within P0's sequential model.
    """

    def test_cancel_does_not_break_generation(self):
        """Sending cancel during generate does not crash; generation completes."""
        proc = _start_adapter('--token-delay', '0.05')
        try:
            _read_json_line(proc, timeout=5)  # heartbeat
            _read_json_line(proc, timeout=5)  # ready

            _send(proc, {"type": "generate", "id": "cancel-test",
                         "prompt": "Hello", "params": {}})
            # Send cancel while generate is running (will be queued)
            _send(proc, {"type": "cancel", "id": "cancel-test"})

            # Collect all messages until done
            messages = []
            for _ in range(10):
                msg = _read_json_line(proc, timeout=5)
                messages.append(msg)
                if msg.get("type") == "done":
                    break

            done = messages[-1]
            self.assertEqual(done["type"], "done")
            self.assertEqual(done["id"], "cancel-test")
            # P0: generation completes fully since cancel is queued
            self.assertGreater(done["tokens_generated"], 0)

            # Adapter should still be responsive after cancel
            _send(proc, {"type": "health"})
            health = _read_json_line(proc, timeout=5)
            self.assertEqual(health["type"], "health")
        finally:
            try:
                proc.kill()
            except Exception:
                pass
            proc.wait(timeout=3)


class TestGenerateException(unittest.TestCase):
    """Generate failure sends error response and adapter continues."""

    def test_generate_failure_sends_error_and_continues(self):
        """--fail-on-generate causes error response; adapter stays alive for next command."""
        proc = _start_adapter('--fail-on-generate')
        try:
            _read_json_line(proc, timeout=5)  # heartbeat
            _read_json_line(proc, timeout=5)  # ready

            _send(proc, {"type": "generate", "id": "fail-test",
                         "prompt": "Hello", "params": {}})
            resp = _read_json_line(proc, timeout=5)
            self.assertEqual(resp["type"], "error")
            self.assertEqual(resp["id"], "fail-test")
            self.assertEqual(resp["code"], "internal_error")
            self.assertIn("RuntimeError", resp["message"])

            # Adapter should still be alive and responsive
            _send(proc, {"type": "health"})
            health = _read_json_line(proc, timeout=5)
            self.assertEqual(health["type"], "health")
        finally:
            try:
                proc.kill()
            except Exception:
                pass
            proc.wait(timeout=3)


class TestNonDictJson(unittest.TestCase):
    """Non-dict JSON input (arrays, strings) produces error response."""

    def setUp(self):
        self.proc = _start_adapter()
        _read_json_line(self.proc, timeout=5)  # heartbeat
        _read_json_line(self.proc, timeout=5)  # ready

    def tearDown(self):
        try:
            self.proc.kill()
        except Exception:
            pass
        self.proc.wait(timeout=3)

    def test_json_array_produces_error(self):
        self.proc.stdin.write(b'[1, 2, 3]\n')
        self.proc.stdin.flush()
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "invalid_json")
        self.assertIn("expected JSON object", resp["message"])

    def test_json_string_produces_error(self):
        self.proc.stdin.write(b'"hello"\n')
        self.proc.stdin.flush()
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "invalid_json")

    def test_cancel_without_id_is_silent(self):
        """Cancel with no id field produces no response (fire-and-forget)."""
        _send(self.proc, {"type": "cancel"})
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "health")


if __name__ == '__main__':
    unittest.main()
