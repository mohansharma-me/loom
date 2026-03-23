"""Integration tests for the vLLM adapter (loom_adapter_vllm.py).

These tests spawn the vLLM adapter as a subprocess, exercise the full
wire protocol against a real AsyncLLMEngine, and verify GPU metric
responses.  All tests are skipped when vLLM is not installed or CUDA
is not available.

Set the environment variable LOOM_TEST_VLLM_MODEL to override the
default model (facebook/opt-125m).

Uses only Python stdlib — no external test dependencies.
"""
import json
import os
import subprocess
import sys
import threading
import unittest

# ---------------------------------------------------------------------------
# Skip guard: skip the entire module when vLLM / CUDA is unavailable.
# ASSUMPTION: torch.cuda.is_available() is the authoritative check for
# whether a CUDA-capable GPU is present.  vLLM requires CUDA; without it
# the engine cannot initialise and the tests would simply hang or crash.
# ---------------------------------------------------------------------------
try:
    import vllm  # noqa: F401
    import torch
    HAS_VLLM = torch.cuda.is_available()
except ImportError:
    HAS_VLLM = False

# ASSUMPTION: facebook/opt-125m is chosen as the default because it is the
# smallest publicly available OPT model (~250 MB) and loads quickly on any
# CUDA-capable GPU.  Override via LOOM_TEST_VLLM_MODEL if a different model
# is already cached or a larger test is desired.
TEST_MODEL = os.environ.get("LOOM_TEST_VLLM_MODEL", "facebook/opt-125m")

ADAPTER_PATH = os.path.join(
    os.path.dirname(__file__), "..", "priv", "python", "loom_adapter_vllm.py"
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
    """Start loom_adapter_vllm.py as a subprocess and return the Popen object."""
    return subprocess.Popen(
        [sys.executable, ADAPTER_PATH, "--model", TEST_MODEL] + list(extra_args),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


# ---------------------------------------------------------------------------
# VllmIntegrationTests
# ---------------------------------------------------------------------------

@unittest.skipUnless(HAS_VLLM, "vLLM not installed or CUDA not available")
class VllmIntegrationTests(unittest.TestCase):
    """Integration tests for VllmAdapter against a real AsyncLLMEngine.

    setUpClass starts the adapter subprocess and waits up to 60 heartbeats
    (with 10s timeout each) for the ready message, which accommodates slow
    model downloads and CUDA initialisation.

    tearDownClass sends a shutdown command, waits up to 30s for clean exit,
    then kills the process if it hasn't exited.
    """

    proc = None  # shared subprocess across all tests in this class

    @classmethod
    def setUpClass(cls):
        """Start the adapter and wait for the ready message."""
        cls.proc = _start_adapter()

        # ASSUMPTION: Model startup (download + CUDA init) can take up to
        # 10 minutes on a cold cache.  We allow 60 heartbeats with a 10s
        # timeout each (= 600s maximum) before failing.  In practice,
        # facebook/opt-125m with a warm cache loads in ~30s.
        max_heartbeats = 60
        hb_timeout = 10.0  # seconds per readline attempt

        for attempt in range(max_heartbeats):
            try:
                msg = _read_json_line(cls.proc, timeout=hb_timeout)
            except TimeoutError:
                raise RuntimeError(
                    f"Timed out waiting for adapter startup message "
                    f"(attempt {attempt + 1}/{max_heartbeats})"
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
            f"Adapter did not send ready message after {max_heartbeats} "
            f"heartbeats (model: {TEST_MODEL})"
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

    def test_generate_streams_tokens(self):
        """Generate request produces token messages followed by a done message."""
        _send(
            self.proc,
            {
                "type": "generate",
                "id": "vllm-test-001",
                "prompt": "Hello, world",
                "params": {"max_tokens": 5},
            },
        )

        # Collect messages until we see a done message or run out of budget.
        # ASSUMPTION: With max_tokens=5 the engine produces at most 5 token
        # messages then a done.  We allow up to 10 reads with 30s timeout
        # each to accommodate slow generation on under-resourced hardware.
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
            self.assertEqual(tok["id"], "vllm-test-001")
            self.assertEqual(tok["token_id"], i + 1, "token_id must be 1-based sequence")
            self.assertIsInstance(tok["text"], str)
            self.assertGreater(len(tok["text"]), 0, "token text must be non-empty")
            self.assertFalse(tok["finished"], "token.finished must be False")

        # Validate done message
        done = done_msgs[0]
        self.assertEqual(done["type"], "done")
        self.assertEqual(done["id"], "vllm-test-001")
        self.assertIn("tokens_generated", done)
        self.assertIn("time_ms", done)
        self.assertGreater(done["tokens_generated"], 0)
        self.assertGreaterEqual(done["time_ms"], 0)

        # tokens_generated must match the token messages we received
        self.assertEqual(done["tokens_generated"], len(tokens))

    def test_health_returns_gpu_stats(self):
        """Health command returns real GPU utilisation and memory stats."""
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=10.0)

        self.assertEqual(resp["type"], "health")
        self.assertEqual(resp["status"], "ok")

        # ASSUMPTION: On a real CUDA GPU, mem_total_gb must be > 0 (any GPU
        # has some VRAM).  gpu_util may legitimately be 0.0 between requests.
        self.assertIn("gpu_util", resp)
        self.assertIn("mem_used_gb", resp)
        self.assertIn("mem_total_gb", resp)

        self.assertIsInstance(resp["gpu_util"], float)
        self.assertIsInstance(resp["mem_used_gb"], float)
        self.assertIsInstance(resp["mem_total_gb"], float)

        self.assertGreater(
            resp["mem_total_gb"], 0.0,
            "mem_total_gb must be > 0 on a real GPU"
        )
        self.assertGreaterEqual(resp["gpu_util"], 0.0)
        self.assertGreaterEqual(resp["mem_used_gb"], 0.0)

    def test_memory_returns_gpu_memory(self):
        """Memory command returns real GPU memory breakdown with total > 0."""
        _send(self.proc, {"type": "memory"})
        resp = _read_json_line(self.proc, timeout=10.0)

        self.assertEqual(resp["type"], "memory")

        self.assertIn("total_gb", resp)
        self.assertIn("used_gb", resp)
        self.assertIn("available_gb", resp)

        self.assertIsInstance(resp["total_gb"], float)
        self.assertIsInstance(resp["used_gb"], float)
        self.assertIsInstance(resp["available_gb"], float)

        # ASSUMPTION: On a real CUDA GPU with a loaded model, total_gb > 0
        # and available_gb > 0 (the model occupies VRAM but doesn't fill it
        # entirely for a small model like facebook/opt-125m).
        self.assertGreater(resp["total_gb"], 0.0, "total_gb must be > 0 on a real GPU")
        self.assertGreater(resp["available_gb"], 0.0, "available_gb must be > 0")
        self.assertGreaterEqual(resp["used_gb"], 0.0)


if __name__ == "__main__":
    unittest.main()
