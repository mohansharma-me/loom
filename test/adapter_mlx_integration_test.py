"""Integration tests for the MLX adapter (loom_adapter_mlx.py).

These tests spawn the MLX adapter as a subprocess, exercise the full
wire protocol against a real mlx-lm model on Apple Silicon, and verify
memory metric responses.  All tests are skipped when mlx-lm or mlx.core
is not installed.

Set the environment variable LOOM_TEST_MLX_MODEL to override the default
model (mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit).

Uses only Python stdlib -- no external test dependencies.

ASSUMPTION: Tests use a 4-bit quantised 1.1B model by default because it
is small enough to load on any Apple Silicon device (even 8 GB RAM) and is
publicly available on the Hugging Face Hub via mlx-community.  The first
run may download ~700 MB; subsequent runs use the Hub cache.
"""
import json
import os
import subprocess
import sys
import threading
import time
import unittest

# ---------------------------------------------------------------------------
# Skip guard: skip the entire module when mlx-lm / mlx.core is unavailable.
# ASSUMPTION: Both mlx_lm and mlx.core must be importable for these tests to
# make sense.  If either is missing the adapter will fail to load, so we
# skip early rather than waiting for a subprocess to crash.
# ---------------------------------------------------------------------------
try:
    import mlx_lm   # noqa: F401
    import mlx.core  # noqa: F401
    HAS_MLX = True
except ImportError:
    HAS_MLX = False

# ASSUMPTION: mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit is the smallest
# readily available mlx-community model (~700 MB quantised).  Override via
# LOOM_TEST_MLX_MODEL to use an already-cached model or a larger one.
TEST_MODEL = os.environ.get(
    "LOOM_TEST_MLX_MODEL",
    "mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit",
)

ADAPTER_PATH = os.path.join(
    os.path.dirname(__file__), "..", "priv", "python", "loom_adapter_mlx.py"
)


# ---------------------------------------------------------------------------
# Subprocess helpers (shared across test classes)
# ---------------------------------------------------------------------------

def _read_json_line(proc, timeout=10.0):
    """Read one JSON line from proc.stdout with a deadline.

    Uses readline() on the raw stdout pipe so the call blocks at the OS
    level without Python-level buffering interfering.  Timeout is enforced
    by a daemon reader thread; if the deadline passes the caller gets a
    TimeoutError rather than hanging forever.
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


def _send(proc, msg):
    """Write a JSON-encoded message followed by a newline to the adapter stdin."""
    proc.stdin.write((json.dumps(msg) + "\n").encode())
    proc.stdin.flush()


def _start_adapter(*extra_args):
    """Start loom_adapter_mlx.py as a subprocess and return the Popen object."""
    return subprocess.Popen(
        [sys.executable, ADAPTER_PATH, "--model", TEST_MODEL] + list(extra_args),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


# ---------------------------------------------------------------------------
# MlxIntegrationTests
# ---------------------------------------------------------------------------

@unittest.skipUnless(HAS_MLX, "mlx-lm or mlx.core not installed")
class MlxIntegrationTests(unittest.TestCase):
    """Integration tests for MlxAdapter against a real mlx-lm model.

    setUpClass starts the adapter subprocess and waits up to 60 heartbeats
    (with 60s timeout each) for the ready message.  The long per-message
    timeout accommodates model downloads on first run (TinyLlama 4-bit is
    ~700 MB) and Metal shader compilation on cold start.

    tearDownClass sends a shutdown command, waits up to 30s for clean exit,
    then kills the process if it hasn't exited.
    """

    proc = None  # shared subprocess across all tests in this class

    @classmethod
    def setUpClass(cls):
        """Start the adapter and wait for the ready message."""
        cls.proc = _start_adapter()

        # ASSUMPTION: Model startup (download + Metal shader compilation) can
        # take up to 60 minutes on a cold Hub cache on a slow connection.
        # We allow 60 messages with a 60s read timeout each (= 3600s maximum).
        # In practice, TinyLlama 4-bit with a warm cache loads in < 30s.
        max_messages = 60
        msg_timeout = 60.0  # seconds per readline attempt

        for attempt in range(max_messages):
            try:
                msg = _read_json_line(cls.proc, timeout=msg_timeout)
            except TimeoutError:
                raise RuntimeError(
                    f"Timed out waiting for adapter startup message "
                    f"(attempt {attempt + 1}/{max_messages}, "
                    f"timeout={msg_timeout}s per message)"
                )
            except EOFError:
                stderr_out = cls.proc.stderr.read().decode(errors="replace")
                raise RuntimeError(
                    f"Adapter stdout closed during startup. stderr:\n{stderr_out}"
                )

            msg_type = msg.get("type")
            if msg_type == "ready":
                return  # startup complete
            if msg_type == "heartbeat":
                continue  # still loading, keep waiting
            # Unexpected message type during startup
            raise RuntimeError(
                f"Unexpected message type during startup: {msg_type!r}. "
                f"Full message: {msg}"
            )

        raise RuntimeError(
            f"Adapter did not send ready message after {max_messages} "
            f"messages (model: {TEST_MODEL})"
        )

    @classmethod
    def tearDownClass(cls):
        """Send shutdown, wait for clean exit, kill if needed."""
        if cls.proc is None:
            return

        try:
            _send(cls.proc, {"type": "shutdown"})
        except Exception:
            pass  # stdin may already be closed

        try:
            cls.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            cls.proc.kill()
            cls.proc.wait()

    # -------------------------------------------------------------------------
    # Tests
    # -------------------------------------------------------------------------

    @unittest.skipUnless(HAS_MLX, "mlx-lm or mlx.core not installed")
    def test_generate_streams_tokens(self):
        """Generate request produces token messages followed by a done message."""
        _send(
            self.proc,
            {
                "type": "generate",
                "id": "mlx-test-001",
                "prompt": "Hello, world",
                "params": {"max_tokens": 5},
            },
        )

        # Collect messages until we see a done message or run out of budget.
        # ASSUMPTION: With max_tokens=5 the adapter produces at most 5 token
        # messages then a done.  We allow up to 10 reads with 30s timeout
        # each to accommodate the Metal forward pass on under-resourced hardware.
        messages = []
        for _ in range(10):
            msg = _read_json_line(self.proc, timeout=30.0)
            messages.append(msg)
            if msg.get("type") == "done":
                break

        # Separate tokens and done
        tokens = [m for m in messages if m.get("type") == "token"]
        done_msgs = [m for m in messages if m.get("type") == "done"]

        self.assertGreater(
            len(tokens), 0,
            f"Expected at least 1 token message, got: {[m['type'] for m in messages]}"
        )
        self.assertEqual(len(done_msgs), 1, "Expected exactly one done message")

        # Validate token messages
        for i, tok in enumerate(tokens):
            self.assertEqual(tok["type"], "token")
            self.assertEqual(tok["id"], "mlx-test-001")
            self.assertEqual(tok["token_id"], i + 1, "token_id must be 1-based sequence")
            self.assertIsInstance(tok["text"], str)
            # ASSUMPTION: token text may be empty for some tokenisers that
            # produce multi-byte tokens (e.g. byte-level BPE).  We accept
            # empty strings here rather than failing on edge cases.
            self.assertFalse(tok["finished"], "token.finished must be False")

        # Validate done message
        done = done_msgs[0]
        self.assertEqual(done["type"], "done")
        self.assertEqual(done["id"], "mlx-test-001")
        self.assertIn("tokens_generated", done)
        self.assertIn("time_ms", done)
        self.assertGreater(done["tokens_generated"], 0)
        self.assertGreaterEqual(done["time_ms"], 0)

        # tokens_generated must match the token messages we received
        self.assertEqual(done["tokens_generated"], len(tokens))

    @unittest.skipUnless(HAS_MLX, "mlx-lm or mlx.core not installed")
    def test_health_returns_memory_stats(self):
        """Health command returns memory stats with gpu_util=0.0 (no Metal API)."""
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=10.0)

        self.assertEqual(resp["type"], "health")
        self.assertEqual(resp["status"], "ok")

        self.assertIn("gpu_util", resp)
        self.assertIn("mem_used_gb", resp)
        self.assertIn("mem_total_gb", resp)

        self.assertIsInstance(resp["gpu_util"], float)
        self.assertIsInstance(resp["mem_used_gb"], float)
        self.assertIsInstance(resp["mem_total_gb"], float)

        # ASSUMPTION: gpu_util is always 0.0 because there is no public Metal
        # API for GPU utilisation percentage on Apple Silicon.  This is a
        # known, intentional limitation of the MLX adapter.
        self.assertEqual(
            resp["gpu_util"], 0.0,
            "gpu_util must be 0.0 (no Metal utilisation API)"
        )

        # Apple Silicon always has > 0 unified RAM.
        self.assertGreater(
            resp["mem_total_gb"], 0.0,
            "mem_total_gb must be > 0 on any Apple Silicon device"
        )
        self.assertGreater(
            resp["mem_used_gb"], 0.0,
            "mem_used_gb must be > 0 with a loaded model"
        )

    @unittest.skipUnless(HAS_MLX, "mlx-lm or mlx.core not installed")
    def test_memory_returns_system_memory(self):
        """Memory command returns system unified-memory breakdown with total > 0."""
        _send(self.proc, {"type": "memory"})
        resp = _read_json_line(self.proc, timeout=10.0)

        self.assertEqual(resp["type"], "memory")

        self.assertIn("total_gb", resp)
        self.assertIn("used_gb", resp)
        self.assertIn("available_gb", resp)

        self.assertIsInstance(resp["total_gb"], float)
        self.assertIsInstance(resp["used_gb"], float)
        self.assertIsInstance(resp["available_gb"], float)

        # ASSUMPTION: Any Apple Silicon device has at least 8 GB unified RAM.
        self.assertGreater(
            resp["total_gb"], 0.0,
            "total_gb must be > 0 on any Apple Silicon device"
        )
        self.assertGreater(
            resp["available_gb"], 0.0,
            "available_gb must be > 0 (OS always keeps some RAM free)"
        )
        self.assertGreaterEqual(resp["used_gb"], 0.0)


if __name__ == "__main__":
    unittest.main()
