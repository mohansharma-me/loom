# P0-06 Implementation Plan: Python Adapter Base + vLLM/MLX Backends

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a shared Python adapter base class and three backend adapters (vLLM, MLX, Mock) that communicate with `loom_port` via the line-delimited JSON wire protocol.

**Architecture:** Abstract base class (`loom_adapter_base.py`) owns protocol I/O, stdin watchdog, asyncio event loop, startup sequence, and error wrapping. Three subclasses implement 5 abstract async methods each. Each adapter is a standalone executable.

**Tech Stack:** Python 3.11+, asyncio, abc, vLLM 0.6.x, mlx-lm 0.20+, pynvml, psutil, unittest

**Spec:** `.github/plans/6-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `priv/python/loom_adapter_base.py` | Create | ABC: protocol I/O, watchdog, startup, command loop, error wrapping |
| `priv/python/loom_adapter_mock.py` | Create | Mock backend subclass for CI testing |
| `priv/python/loom_adapter_vllm.py` | Create | vLLM 0.6.x AsyncLLMEngine wrapper |
| `priv/python/loom_adapter_mlx.py` | Create | mlx-lm wrapper for Apple Silicon |
| `priv/python/requirements-vllm.txt` | Create | vLLM dependencies |
| `priv/python/requirements-mlx.txt` | Create | MLX dependencies |
| `test/adapter_base_test.py` | Create | Base class tests via mock adapter subprocess |
| `test/adapter_vllm_integration_test.py` | Create | vLLM integration tests (skipUnless CUDA) |
| `test/adapter_mlx_integration_test.py` | Create | MLX integration tests (skipUnless mlx_lm) |
| `.github/workflows/ci.yml` | Modify | Add Python adapter test step |
| `ROADMAP.md` | Modify | Mark P0-06 done, note P1-12 pulled forward |

---

### Task 1: Project Scaffold

**Files:**
- Create: `priv/python/requirements-vllm.txt`
- Create: `priv/python/requirements-mlx.txt`

- [ ] **Step 1: Create priv/python/ directory and requirements files**

```
# priv/python/requirements-vllm.txt
vllm>=0.6.0,<0.7.0

# priv/python/requirements-mlx.txt
mlx-lm>=0.20.0
psutil
```

Run: `ls priv/python/`
Expected: `requirements-mlx.txt  requirements-vllm.txt`

- [ ] **Step 2: Commit**

```bash
git add priv/python/requirements-vllm.txt priv/python/requirements-mlx.txt
git commit -m "chore: scaffold priv/python/ with requirements files for P0-06"
```

---

### Task 2: Base Class - Protocol I/O and CLI Framework

**Files:**
- Create: `priv/python/loom_adapter_base.py`

Build the base class skeleton: imports, `__init__`, CLI arg parsing, `send_msg`, `send_token`, `send_done`, `send_error` helpers, and abstract method declarations. No event loop or command dispatch yet.

- [ ] **Step 1: Write the base class skeleton**

```python
#!/usr/bin/env python3
"""Abstract base class for Loom inference engine adapters.

Owns the protocol I/O layer (line-delimited JSON on stdio), stdin watchdog,
asyncio event loop, startup heartbeat sequence, and command dispatch.
Subclasses implement 5 abstract async methods for engine-specific behavior.

Uses only Python stdlib -- no external dependencies.
"""
import abc
import argparse
import asyncio
import json
import logging
import os
import queue
import sys
import threading
import time
import traceback

logger = logging.getLogger("loom_adapter")


class LoomAdapterBase(abc.ABC):
    """Abstract base for all Loom inference adapters."""

    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.cancelled_requests: set[str] = set()
        self._active_requests: set[str] = set()
        self._line_queue: queue.Queue[bytes] = queue.Queue()

    # --- Abstract methods (5) ---

    @abc.abstractmethod
    async def load_model(self) -> tuple[str, str]:
        """Load the model. Return (model_name, backend_name) for ready message."""

    @abc.abstractmethod
    async def generate(self, request_id: str, prompt: str, params: dict) -> None:
        """Stream tokens via self.send_token(), then self.send_done()."""

    @abc.abstractmethod
    async def get_health(self) -> dict:
        """Return {"status", "gpu_util", "mem_used_gb", "mem_total_gb"}."""

    @abc.abstractmethod
    async def get_memory(self) -> dict:
        """Return {"total_gb", "used_gb", "available_gb"}."""

    @abc.abstractmethod
    async def cancel_request(self, request_id: str) -> None:
        """Cancel an in-progress generation. Fire-and-forget."""

    # --- Protocol I/O helpers ---

    def send_msg(self, msg: dict) -> None:
        """Write a JSON message + newline to stdout and flush."""
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()

    def send_token(self, request_id: str, token_id: int, text: str,
                   finished: bool = False) -> None:
        """Send a token message."""
        self.send_msg({
            "type": "token",
            "id": request_id,
            "token_id": token_id,
            "text": text,
            "finished": finished,
        })

    def send_done(self, request_id: str, tokens_generated: int,
                  time_ms: int) -> None:
        """Send a done message (end of generation)."""
        self.send_msg({
            "type": "done",
            "id": request_id,
            "tokens_generated": tokens_generated,
            "time_ms": time_ms,
        })

    def send_error(self, request_id: str | None, code: str,
                   message: str) -> None:
        """Send an error message. request_id=None serializes as JSON null."""
        self.send_msg({
            "type": "error",
            "id": request_id,
            "code": code,
            "message": message,
        })

    # --- CLI arg parsing ---

    @classmethod
    def add_args(cls, parser: argparse.ArgumentParser) -> None:
        """Override in subclass to add backend-specific CLI args."""
        pass

    @classmethod
    def parse_args(cls, argv: list[str] | None = None) -> argparse.Namespace:
        """Parse CLI args with common + subclass-specific arguments."""
        parser = argparse.ArgumentParser(
            description="Loom inference adapter"
        )
        parser.add_argument("--model", required=True,
                            help="Model name or path to load")
        parser.add_argument("--heartbeat-interval", type=float, default=5.0,
                            help="Seconds between heartbeats during loading "
                                 "(must be < loom_port heartbeat_timeout_ms, "
                                 "default 15s)")
        parser.add_argument("--log-level", default="INFO",
                            choices=["DEBUG", "INFO", "WARNING", "ERROR"],
                            help="Logging level (default: INFO)")
        cls.add_args(parser)
        return parser.parse_args(argv)
```

- [ ] **Step 2: Verify syntax**

Run: `python3 -c "import ast; ast.parse(open('priv/python/loom_adapter_base.py').read()); print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add priv/python/loom_adapter_base.py
git commit -m "feat(adapter): add base class skeleton with protocol I/O helpers"
```

---

### Task 3: Base Class - Stdin Watchdog and Asyncio Event Loop

**Files:**
- Modify: `priv/python/loom_adapter_base.py`

Add the stdin watchdog thread, `run()` entry point, `_startup_sequence()`, and `_command_loop()` to the base class.

- [ ] **Step 1: Add watchdog and run methods**

Add the following methods to `LoomAdapterBase`:

```python
    # --- Stdin watchdog ---

    def _stdin_watchdog(self) -> None:
        """Daemon thread: read stdin lines, detect EOF, force-exit.

        Sole reader of sys.stdin. Puts lines into _line_queue.
        On EOF, calls os._exit(1) -- cross-platform force-kill when
        loom_port closes the Erlang port.
        """
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                logger.info("stdin closed (watchdog), force-exiting")
                os._exit(1)
            self._line_queue.put(line)

    # --- Main entry point ---

    def run(self) -> None:
        """Start the adapter: watchdog, event loop, startup, command loop."""
        # Configure logging to stderr (stdout is protocol channel)
        logging.basicConfig(
            level=getattr(logging, self.args.log_level),
            format="[%(name)s] %(levelname)s: %(message)s",
            stream=sys.stderr,
        )

        # Defense-in-depth: line-buffer stdout
        sys.stdout.reconfigure(line_buffering=True)

        # Validate heartbeat interval vs loom_port timeout
        # ASSUMPTION: loom_port default heartbeat_timeout_ms is 15000 (15s).
        # The adapter interval must be strictly less to avoid being killed.
        if self.args.heartbeat_interval >= 15.0:
            logger.warning(
                "heartbeat-interval (%.1fs) >= loom_port default "
                "heartbeat_timeout_ms (15s). The adapter may be killed "
                "during model loading. Reduce --heartbeat-interval.",
                self.args.heartbeat_interval,
            )

        # Start stdin watchdog as daemon thread
        watchdog = threading.Thread(
            target=self._stdin_watchdog, daemon=True, name="stdin-watchdog"
        )
        watchdog.start()

        # Run async main
        asyncio.run(self._async_main())

    async def _async_main(self) -> None:
        """Async entry: startup sequence then command loop."""
        try:
            await self._startup_sequence()
        except Exception as e:
            logger.error("Failed to load model: %s", e)
            traceback.print_exc(file=sys.stderr)
            os._exit(2)
        await self._command_loop()

    # --- Startup sequence ---

    async def _startup_sequence(self) -> None:
        """Send heartbeats during model loading, then send ready.

        First heartbeat is sent BEFORE load_model() to ensure loom_port
        transitions from spawning->loading before spawn_timeout fires.
        """
        self.send_msg({
            "type": "heartbeat",
            "status": "loading",
            "detail": "initializing adapter",
        })

        # Run load_model with periodic heartbeats
        load_task = asyncio.create_task(self.load_model())
        interval = self.args.heartbeat_interval

        while not load_task.done():
            try:
                model_name, backend_name = await asyncio.wait_for(
                    asyncio.shield(load_task), timeout=interval
                )
                break
            except asyncio.TimeoutError:
                # Model still loading, send heartbeat
                self.send_msg({
                    "type": "heartbeat",
                    "status": "loading",
                    "detail": "loading model",
                })
        else:
            # Task completed in the while condition check
            model_name, backend_name = load_task.result()

        self.send_msg({
            "type": "ready",
            "model": model_name,
            "backend": backend_name,
        })

    # --- Command loop ---

    async def _command_loop(self) -> None:
        """Read lines from watchdog queue, parse JSON, dispatch commands."""
        loop = asyncio.get_event_loop()

        while True:
            # Read from queue without blocking the event loop
            raw_line = await loop.run_in_executor(None, self._line_queue.get)
            line = raw_line.decode(errors="replace").strip()
            if not line:
                continue

            try:
                msg = json.loads(line)
            except json.JSONDecodeError as e:
                self.send_error(None, "invalid_json", f"invalid JSON: {e}")
                continue

            msg_type = msg.get("type")
            if msg_type is None:
                self.send_error(None, "missing_type",
                                "message missing 'type' field")
                continue

            await self._dispatch_command(msg_type, msg)

    async def _dispatch_command(self, msg_type: str, msg: dict) -> None:
        """Dispatch a parsed command to the appropriate handler."""
        try:
            if msg_type == "generate":
                request_id = msg.get("id")
                if request_id is None:
                    self.send_error(None, "missing_field",
                                    "generate request missing 'id' field")
                    return
                prompt = msg.get("prompt", "")
                params = msg.get("params", {})
                self._active_requests.add(request_id)
                try:
                    await self.generate(request_id, prompt, params)
                finally:
                    self._active_requests.discard(request_id)
                    self.cancelled_requests.discard(request_id)

            elif msg_type == "health":
                result = await self.get_health()
                self.send_msg({"type": "health", **result})

            elif msg_type == "memory":
                result = await self.get_memory()
                self.send_msg({"type": "memory", **result})

            elif msg_type == "cancel":
                request_id = msg.get("id")
                if request_id is not None:
                    await self.cancel_request(request_id)

            elif msg_type == "shutdown":
                logger.info("shutdown requested, exiting")
                sys.stdout.flush()
                os._exit(0)

            else:
                self.send_error(
                    msg.get("id"), "unknown_type",
                    f"unknown message type: {msg_type}"
                )

        except Exception as e:
            logger.error("Command %s failed: %s", msg_type, e)
            traceback.print_exc(file=sys.stderr)
            self.send_error(
                msg.get("id"), "internal_error",
                f"{type(e).__name__}: {e}"
            )
```

- [ ] **Step 2: Verify syntax**

Run: `python3 -c "import ast; ast.parse(open('priv/python/loom_adapter_base.py').read()); print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add priv/python/loom_adapter_base.py
git commit -m "feat(adapter): add watchdog, startup sequence, and command loop to base class"
```

---

### Task 4: Mock Adapter

**Files:**
- Create: `priv/python/loom_adapter_mock.py`

Subclass the base for CI testing. Must be executable standalone.

- [ ] **Step 1: Write mock adapter**

```python
#!/usr/bin/env python3
"""Mock inference adapter for testing the base class protocol layer.

Subclasses LoomAdapterBase with fake implementations of all 5 abstract
methods. Used in CI to test the base class without GPU dependencies.

Uses only Python stdlib -- no external dependencies.
"""
import asyncio
import sys
import os
import time

# ASSUMPTION: loom_adapter_base.py is in the same directory.
# Add parent to path so import works when run as script.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from loom_adapter_base import LoomAdapterBase


# ASSUMPTION: Fixed mock tokens match the existing mock_adapter.py for
# behavioral parity in protocol tests.
MOCK_TOKENS = ["Hello", "from", "Loom", "mock", "adapter"]


class MockAdapter(LoomAdapterBase):
    """Mock adapter that returns fixed responses without any engine."""

    @classmethod
    def add_args(cls, parser):
        parser.add_argument(
            "--startup-delay", type=float, default=0.0,
            help="Simulated model loading delay in seconds (default: 0)"
        )

    async def load_model(self) -> tuple[str, str]:
        if self.args.startup_delay > 0:
            await asyncio.sleep(self.args.startup_delay)
        return ("mock", "mock")

    async def generate(self, request_id: str, prompt: str,
                       params: dict) -> None:
        start = time.monotonic()
        max_tokens = params.get("max_tokens", len(MOCK_TOKENS))
        tokens_to_send = MOCK_TOKENS[:max_tokens]

        for i, token_text in enumerate(tokens_to_send):
            if request_id in self.cancelled_requests:
                break
            self.send_token(request_id, i + 1, token_text, finished=False)
            # Small yield to allow cancel checks
            await asyncio.sleep(0)

        elapsed_ms = int((time.monotonic() - start) * 1000)
        self.send_done(request_id, len(tokens_to_send), elapsed_ms)

    # ASSUMPTION: Returns zeroed GPU metrics since no real GPU is present.
    async def get_health(self) -> dict:
        return {
            "status": "ok",
            "gpu_util": 0.0,
            "mem_used_gb": 0.0,
            "mem_total_gb": 80.0,
        }

    # ASSUMPTION: Returns 80GB total to approximate H100 GPU specs.
    async def get_memory(self) -> dict:
        return {
            "total_gb": 80.0,
            "used_gb": 0.0,
            "available_gb": 80.0,
        }

    async def cancel_request(self, request_id: str) -> None:
        self.cancelled_requests.add(request_id)


def main():
    args = MockAdapter.parse_args()
    adapter = MockAdapter(args)
    adapter.run()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify it starts and sends heartbeat + ready**

Run: `echo '{"type":"shutdown"}' | python3 priv/python/loom_adapter_mock.py --model mock 2>/dev/null`
Expected output (3 lines):
```
{"type": "heartbeat", "status": "loading", "detail": "initializing adapter"}
{"type": "ready", "model": "mock", "backend": "mock"}
```
(Then exits on shutdown command)

- [ ] **Step 3: Commit**

```bash
git add priv/python/loom_adapter_mock.py
git commit -m "feat(adapter): add mock adapter subclassing base for CI testing"
```

---

### Task 5: Base Class Tests - Startup Protocol

**Files:**
- Create: `test/adapter_base_test.py`

Tests spawn `loom_adapter_mock.py` as a subprocess and exercise the base class through the protocol.

- [ ] **Step 1: Write test scaffolding and startup tests**

```python
"""Tests for the adapter base class via the mock adapter.

Spawns loom_adapter_mock.py as a subprocess and exercises the base class
protocol layer: startup sequence, command handling, error handling, and
stdin watchdog.

Uses only Python stdlib -- no external dependencies.
"""
import json
import os
import subprocess
import sys
import threading
import time
import unittest

MOCK_ADAPTER_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'priv', 'python', 'loom_adapter_mock.py'
)


def _read_json_line(proc, timeout=5.0):
    """Read one JSON line from proc.stdout with a deadline."""
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
    """Start the mock adapter subprocess."""
    return subprocess.Popen(
        [sys.executable, MOCK_ADAPTER_PATH, '--model', 'mock'] + list(extra_args),
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
        proc = _start_adapter()
        try:
            hb = _read_json_line(proc, timeout=5)
            self.assertEqual(hb["type"], "heartbeat")
            self.assertEqual(hb["status"], "loading")
            self.assertIn("detail", hb)

            ready = _read_json_line(proc, timeout=5)
            self.assertEqual(ready["type"], "ready")
            self.assertEqual(ready["model"], "mock")
            self.assertEqual(ready["backend"], "mock")
        finally:
            proc.stdin.close()
            proc.wait(timeout=5)

    def test_startup_delay_sends_heartbeats(self):
        proc = _start_adapter('--startup-delay', '1.5',
                              '--heartbeat-interval', '0.3')
        try:
            messages = []
            for _ in range(20):
                msg = _read_json_line(proc, timeout=10)
                messages.append(msg)
                if msg.get("type") == "ready":
                    break

            types = [m["type"] for m in messages]
            heartbeats = [m for m in messages if m["type"] == "heartbeat"]
            self.assertIn("ready", types)
            self.assertGreaterEqual(len(heartbeats), 2)
            self.assertEqual(messages[-1]["type"], "ready")
        finally:
            proc.stdin.close()
            proc.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 2: Run tests**

Run: `python3 -m unittest test.adapter_base_test.TestStartupProtocol -v`
Expected: 2 tests pass

- [ ] **Step 3: Commit**

```bash
git add test/adapter_base_test.py
git commit -m "test(adapter): add startup protocol tests for base class"
```

---

### Task 6: Base Class Tests - Command Handling

**Files:**
- Modify: `test/adapter_base_test.py`

Add test classes for generate, health, memory, cancel, and multiple commands.

- [ ] **Step 1: Add command handling tests**

Append to `test/adapter_base_test.py`:

```python
class TestCommandHandling(unittest.TestCase):
    """Command handlers work correctly via the base class dispatch."""

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
        _send(self.proc, {"type": "generate", "id": "req-001",
                          "prompt": "Hello", "params": {}})
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

    def test_cancel_returns_no_response(self):
        _send(self.proc, {"type": "cancel", "id": "req-1"})
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=5)
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
```

- [ ] **Step 2: Run tests**

Run: `python3 -m unittest test.adapter_base_test.TestCommandHandling -v`
Expected: 5 tests pass

- [ ] **Step 3: Commit**

```bash
git add test/adapter_base_test.py
git commit -m "test(adapter): add command handling tests for base class"
```

---

### Task 7: Base Class Tests - Error Handling, Shutdown, Watchdog

**Files:**
- Modify: `test/adapter_base_test.py`

Add tests for malformed input, unknown types, shutdown, stdin watchdog, and blank lines.

- [ ] **Step 1: Add error handling and shutdown tests**

Append to `test/adapter_base_test.py`:

```python
class TestErrorHandling(unittest.TestCase):
    """Error handling: malformed input, unknown types, missing fields."""

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

    def test_invalid_json(self):
        self.proc.stdin.write(b"{this is not valid json\n")
        self.proc.stdin.flush()
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "invalid_json")

    def test_missing_type(self):
        _send(self.proc, {"no_type_field": True})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "missing_type")

    def test_unknown_type(self):
        _send(self.proc, {"type": "bogus"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "unknown_type")
        self.assertIn("bogus", resp["message"])

    def test_generate_missing_id(self):
        _send(self.proc, {"type": "generate", "prompt": "Hi"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        self.assertEqual(resp["code"], "missing_field")

    def test_error_without_request_has_null_id(self):
        _send(self.proc, {"type": "bogus"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "error")
        # id should be None (serialized as null)
        self.assertIsNone(resp.get("id"))

    def test_blank_lines_ignored(self):
        self.proc.stdin.write(b"\n\n")
        self.proc.stdin.flush()
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=5)
        self.assertEqual(resp["type"], "health")


class TestShutdown(unittest.TestCase):
    """Shutdown command causes clean exit."""

    def test_shutdown_exits_cleanly(self):
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

            self.assertEqual(ret, 0)
        except Exception:
            proc.kill()
            proc.wait()
            raise


class TestStdinWatchdog(unittest.TestCase):
    """Stdin watchdog: closing stdin kills the adapter."""

    def test_stdin_close_kills_adapter(self):
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
                self.fail("Adapter did not exit after stdin close")

            self.assertEqual(ret, 1)
        except Exception:
            proc.kill()
            proc.wait()
            raise
```

Also add a test for load_model failure producing exit code 2. The mock adapter doesn't have a `--fail-on-load` flag, so we test this by passing a subclass that raises during load. Simpler approach: test it with an invalid `--model` arg if the mock adapter validates it, or add a `--fail-on-load` flag to the mock adapter.

Add `--fail-on-load` flag to mock adapter's `add_args()` (Task 4):
```python
        parser.add_argument(
            "--fail-on-load", action="store_true",
            help="Simulate model load failure (for testing)"
        )
```

And in `load_model()`:
```python
    async def load_model(self) -> tuple[str, str]:
        if getattr(self.args, 'fail_on_load', False):
            raise RuntimeError("Simulated model load failure")
        if self.args.startup_delay > 0:
            await asyncio.sleep(self.args.startup_delay)
        return ("mock", "mock")
```

Then add this test:
```python
class TestLoadFailure(unittest.TestCase):
    """Model load failure produces exit code 2."""

    def test_load_failure_exits_with_code_2(self):
        proc = _start_adapter('--fail-on-load')
        try:
            # Should get heartbeat then exit
            _read_json_line(proc, timeout=5)  # heartbeat

            try:
                ret = proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                self.fail("Adapter did not exit after load failure")

            self.assertEqual(ret, 2,
                             f"Expected exit code 2 on load failure, got {ret}")
        except Exception:
            proc.kill()
            proc.wait()
            raise
```

- [ ] **Step 2: Run all base tests**

Run: `python3 -m unittest test.adapter_base_test -v`
Expected: All tests pass (startup: 2, commands: 5, errors: 6, shutdown: 1, watchdog: 1, load failure: 1 = 16 total)

- [ ] **Step 3: Commit**

```bash
git add test/adapter_base_test.py
git commit -m "test(adapter): add error handling, shutdown, and watchdog tests"
```

---

### Task 8: vLLM Adapter

**Files:**
- Create: `priv/python/loom_adapter_vllm.py`

- [ ] **Step 1: Write vLLM adapter**

```python
#!/usr/bin/env python3
"""vLLM inference adapter for Loom.

Wraps vLLM 0.6.x AsyncLLMEngine to speak the Loom wire protocol.
Reads line-delimited JSON from stdin, dispatches to vLLM, streams
token responses to stdout.

Dependencies: vllm>=0.6.0,<0.7.0 (see requirements-vllm.txt)
"""
import asyncio
import logging
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from loom_adapter_base import LoomAdapterBase

logger = logging.getLogger("loom_adapter")


class VllmAdapter(LoomAdapterBase):
    """Adapter wrapping vLLM AsyncLLMEngine."""

    def __init__(self, args):
        super().__init__(args)
        self.engine = None
        self._nvml_handle = None

    @classmethod
    def add_args(cls, parser):
        parser.add_argument(
            "--tensor-parallel-size", type=int, default=1,
            help="Number of GPUs for tensor parallelism (default: 1)"
        )
        parser.add_argument(
            "--dtype", default="auto",
            help="Model dtype (default: auto)"
        )
        parser.add_argument(
            "--gpu-memory-utilization", type=float, default=0.9,
            help="Fraction of GPU memory to use (default: 0.9)"
        )
        parser.add_argument(
            "--max-model-len", type=int, default=None,
            help="Maximum model context length (default: auto-detect)"
        )

    async def load_model(self) -> tuple[str, str]:
        from vllm import AsyncLLMEngine
        from vllm.engine.arg_utils import AsyncEngineArgs

        engine_args = AsyncEngineArgs(
            model=self.args.model,
            tensor_parallel_size=self.args.tensor_parallel_size,
            dtype=self.args.dtype,
            gpu_memory_utilization=self.args.gpu_memory_utilization,
            max_model_len=self.args.max_model_len,
        )
        self.engine = AsyncLLMEngine.from_engine_args(engine_args)

        # Initialize NVML once for health/memory queries
        try:
            import pynvml
            pynvml.nvmlInit()
            self._nvml_handle = pynvml.nvmlDeviceGetHandleByIndex(0)
        except Exception:
            logger.warning("pynvml initialization failed; health/memory "
                           "will return zeroed stats")

        return (self.args.model, "vllm")

    async def generate(self, request_id: str, prompt: str,
                       params: dict) -> None:
        from vllm import SamplingParams

        sampling_params = SamplingParams(
            max_tokens=params.get("max_tokens", 256),
            temperature=params.get("temperature", 1.0),
            top_p=params.get("top_p", 1.0),
            stop=params.get("stop", []),
        )

        start = time.monotonic()
        token_count = 0
        prev_text = ""

        # ASSUMPTION: vLLM 0.6.x generate() returns async generator of
        # RequestOutput with cumulative text in outputs[0].text.
        async for result in self.engine.generate(prompt, sampling_params,
                                                  request_id):
            if request_id in self.cancelled_requests:
                break

            if result.outputs:
                current_text = result.outputs[0].text
                # Extract incremental text by diffing with previous
                incremental = current_text[len(prev_text):]
                if incremental:
                    token_count += 1
                    self.send_token(request_id, token_count, incremental,
                                    finished=False)
                prev_text = current_text

        elapsed_ms = int((time.monotonic() - start) * 1000)
        self.send_done(request_id, token_count, elapsed_ms)

    async def get_health(self) -> dict:
        # ASSUMPTION: For TP > 1, reports GPU 0 only. Multi-GPU is P0-07.
        if self._nvml_handle is not None:
            try:
                import pynvml
                util = pynvml.nvmlDeviceGetUtilizationRates(self._nvml_handle)
                mem = pynvml.nvmlDeviceGetMemoryInfo(self._nvml_handle)
                return {
                    "status": "ok",
                    "gpu_util": util.gpu / 100.0,
                    "mem_used_gb": mem.used / (1024 ** 3),
                    "mem_total_gb": mem.total / (1024 ** 3),
                }
            except Exception:
                pass
        return {
            "status": "ok",
            "gpu_util": 0.0,
            "mem_used_gb": 0.0,
            "mem_total_gb": 0.0,
        }

    async def get_memory(self) -> dict:
        if self._nvml_handle is not None:
            try:
                import pynvml
                mem = pynvml.nvmlDeviceGetMemoryInfo(self._nvml_handle)
                return {
                    "total_gb": mem.total / (1024 ** 3),
                    "used_gb": mem.used / (1024 ** 3),
                    "available_gb": mem.free / (1024 ** 3),
                }
            except Exception:
                pass
        return {
            "total_gb": 0.0,
            "used_gb": 0.0,
            "available_gb": 0.0,
        }

    async def cancel_request(self, request_id: str) -> None:
        self.cancelled_requests.add(request_id)
        if self.engine is not None and request_id in self._active_requests:
            await self.engine.abort(request_id)


def main():
    args = VllmAdapter.parse_args()
    adapter = VllmAdapter(args)
    adapter.run()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify syntax**

Run: `python3 -c "import ast; ast.parse(open('priv/python/loom_adapter_vllm.py').read()); print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add priv/python/loom_adapter_vllm.py
git commit -m "feat(adapter): add vLLM adapter wrapping AsyncLLMEngine"
```

---

### Task 9: vLLM Integration Tests

**Files:**
- Create: `test/adapter_vllm_integration_test.py`

- [ ] **Step 1: Write vLLM integration tests**

```python
"""Integration tests for the vLLM adapter.

Requires: vllm installed, CUDA GPU available.
Skipped automatically when dependencies are not met.

These tests load a real (small) model and exercise the full adapter
pipeline including actual token generation.
"""
import json
import os
import subprocess
import sys
import threading
import unittest

# Skip entire module if vllm or CUDA not available
try:
    import vllm  # noqa: F401
    import torch
    HAS_VLLM = torch.cuda.is_available()
except ImportError:
    HAS_VLLM = False

VLLM_ADAPTER_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'priv', 'python', 'loom_adapter_vllm.py'
)

# ASSUMPTION: A small model that fits on a single GPU for testing.
TEST_MODEL = os.environ.get("LOOM_TEST_VLLM_MODEL", "facebook/opt-125m")


def _read_json_line(proc, timeout=60.0):
    """Read one JSON line with timeout."""
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
        raise TimeoutError(f"Timed out after {timeout}s")
    if error:
        raise error[0]
    line = result[0] if result else b""
    if not line:
        raise EOFError("stdout closed")
    return json.loads(line.decode().strip())


def _send(proc, msg):
    proc.stdin.write((json.dumps(msg) + '\n').encode())
    proc.stdin.flush()


@unittest.skipUnless(HAS_VLLM, "vLLM or CUDA not available")
class TestVllmAdapter(unittest.TestCase):
    """Integration tests with real vLLM engine."""

    @classmethod
    def setUpClass(cls):
        cls.proc = subprocess.Popen(
            [sys.executable, VLLM_ADAPTER_PATH,
             '--model', TEST_MODEL,
             '--gpu-memory-utilization', '0.5',
             '--heartbeat-interval', '5'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # Wait for startup (model loading can take 30-60s)
        messages = []
        for _ in range(60):
            msg = _read_json_line(cls.proc, timeout=10)
            messages.append(msg)
            if msg.get("type") == "ready":
                break
        else:
            cls.proc.kill()
            cls.proc.wait()
            raise RuntimeError(f"Adapter never became ready. Got: {messages}")

    @classmethod
    def tearDownClass(cls):
        try:
            _send(cls.proc, {"type": "shutdown"})
            cls.proc.wait(timeout=10)
        except Exception:
            cls.proc.kill()
            cls.proc.wait()

    def test_generate_streams_tokens(self):
        _send(self.proc, {
            "type": "generate", "id": "test-1",
            "prompt": "Hello world",
            "params": {"max_tokens": 5},
        })
        tokens = []
        done_msg = None
        for _ in range(20):
            msg = _read_json_line(self.proc, timeout=30)
            if msg["type"] == "token":
                tokens.append(msg)
                self.assertEqual(msg["id"], "test-1")
                self.assertFalse(msg["finished"])
            elif msg["type"] == "done":
                done_msg = msg
                break
        self.assertIsNotNone(done_msg)
        self.assertEqual(done_msg["id"], "test-1")
        self.assertGreater(done_msg["tokens_generated"], 0)
        self.assertGreater(len(tokens), 0)

    def test_health_returns_gpu_stats(self):
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=10)
        self.assertEqual(resp["type"], "health")
        self.assertEqual(resp["status"], "ok")
        self.assertIsInstance(resp["gpu_util"], (int, float))
        self.assertGreater(resp["mem_total_gb"], 0)

    def test_memory_returns_gpu_memory(self):
        _send(self.proc, {"type": "memory"})
        resp = _read_json_line(self.proc, timeout=10)
        self.assertEqual(resp["type"], "memory")
        self.assertGreater(resp["total_gb"], 0)
        self.assertGreaterEqual(resp["used_gb"], 0)
        self.assertGreater(resp["available_gb"], 0)


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 2: Verify syntax (tests will be skipped without GPU)**

Run: `python3 -m unittest test.adapter_vllm_integration_test -v`
Expected: 3 tests skipped with "vLLM or CUDA not available"

- [ ] **Step 3: Commit**

```bash
git add test/adapter_vllm_integration_test.py
git commit -m "test(adapter): add vLLM integration tests (skipUnless CUDA)"
```

---

### Task 10: MLX Adapter

**Files:**
- Create: `priv/python/loom_adapter_mlx.py`

- [ ] **Step 1: Write MLX adapter**

```python
#!/usr/bin/env python3
"""MLX inference adapter for Loom (Apple Silicon).

Wraps mlx-lm for local inference on Apple Silicon Macs.
Reads line-delimited JSON from stdin, dispatches to mlx-lm,
streams token responses to stdout.

Concurrency: mlx-lm runs single-request at a time (no continuous
batching). This is an mlx-lm limitation, not a Loom constraint.
Concurrent generate calls are serialized.

Dependencies: mlx-lm>=0.20.0, psutil (see requirements-mlx.txt)
"""
import asyncio
import logging
import sys
import os
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from loom_adapter_base import LoomAdapterBase

logger = logging.getLogger("loom_adapter")


class MlxAdapter(LoomAdapterBase):
    """Adapter wrapping mlx-lm for Apple Silicon inference."""

    def __init__(self, args):
        super().__init__(args)
        self.model = None
        self.tokenizer = None

    @classmethod
    def add_args(cls, parser):
        parser.add_argument(
            "--max-tokens", type=int, default=256,
            help="Default max tokens for generation (default: 256)"
        )
        parser.add_argument(
            "--dtype", default="float16",
            help="Model dtype (default: float16)"
        )

    async def load_model(self) -> tuple[str, str]:
        from mlx_lm import load

        loop = asyncio.get_event_loop()
        model_path = self.args.model
        # ASSUMPTION: mlx_lm.load() accepts model path/name and returns
        # (model, tokenizer). dtype is not passed to load() directly --
        # mlx-lm infers it from the model config or quantization format.
        self.model, self.tokenizer = await loop.run_in_executor(
            None, lambda: load(model_path)
        )
        return (self.args.model, "mlx")

    async def generate(self, request_id: str, prompt: str,
                       params: dict) -> None:
        from mlx_lm.utils import generate_step
        import mlx.core as mx

        loop = asyncio.get_event_loop()
        start = time.monotonic()
        max_tokens = params.get("max_tokens", self.args.max_tokens)
        temp = params.get("temperature", 1.0)
        top_p = params.get("top_p", 1.0)

        # Tokenize prompt
        input_ids = mx.array(self.tokenizer.encode(prompt))

        token_count = 0

        # ASSUMPTION: generate_step is a sync generator that yields
        # (token, logprobs) tuples. Wrapped in executor to avoid
        # blocking the event loop.
        def _generate_sync():
            """Run the sync generation loop, yielding token IDs."""
            for (token, _logprobs), _n in zip(
                generate_step(input_ids, self.model, temp=temp, top_p=top_p),
                range(max_tokens),
            ):
                tok_id = token.item()
                yield tok_id
                if tok_id == self.tokenizer.eos_token_id:
                    break

        # Run generation step-by-step, yielding to event loop between tokens
        gen = _generate_sync()

        while True:
            if request_id in self.cancelled_requests:
                break
            token_id_val = await loop.run_in_executor(
                None, lambda: next(gen, None)
            )
            if token_id_val is None:
                break

            token_count += 1
            text = self.tokenizer.decode([token_id_val])
            self.send_token(request_id, token_count, text, finished=False)

        elapsed_ms = int((time.monotonic() - start) * 1000)
        self.send_done(request_id, token_count, elapsed_ms)

    # ASSUMPTION: On unified memory Macs, system memory IS GPU memory.
    # gpu_util is 0.0 because Apple has no direct Metal utilization API.
    async def get_health(self) -> dict:
        import psutil
        mem = psutil.virtual_memory()
        return {
            "status": "ok",
            "gpu_util": 0.0,
            "mem_used_gb": mem.used / (1024 ** 3),
            "mem_total_gb": mem.total / (1024 ** 3),
        }

    async def get_memory(self) -> dict:
        import psutil
        mem = psutil.virtual_memory()
        return {
            "total_gb": mem.total / (1024 ** 3),
            "used_gb": mem.used / (1024 ** 3),
            "available_gb": mem.available / (1024 ** 3),
        }

    async def cancel_request(self, request_id: str) -> None:
        self.cancelled_requests.add(request_id)


def main():
    args = MlxAdapter.parse_args()
    adapter = MlxAdapter(args)
    adapter.run()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify syntax**

Run: `python3 -c "import ast; ast.parse(open('priv/python/loom_adapter_mlx.py').read()); print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add priv/python/loom_adapter_mlx.py
git commit -m "feat(adapter): add MLX adapter wrapping mlx-lm for Apple Silicon"
```

---

### Task 11: MLX Integration Tests

**Files:**
- Create: `test/adapter_mlx_integration_test.py`

- [ ] **Step 1: Write MLX integration tests**

```python
"""Integration tests for the MLX adapter (Apple Silicon).

Requires: mlx-lm installed, Apple Silicon Mac.
Skipped automatically when dependencies are not met.

These tests load a real (small quantized) model and exercise the full
adapter pipeline including actual token generation on Metal.
"""
import json
import os
import subprocess
import sys
import threading
import unittest

try:
    import mlx_lm  # noqa: F401
    import mlx.core as mx  # noqa: F401
    HAS_MLX = True
except ImportError:
    HAS_MLX = False

MLX_ADAPTER_PATH = os.path.join(
    os.path.dirname(__file__), '..', 'priv', 'python', 'loom_adapter_mlx.py'
)

# ASSUMPTION: Small 4-bit quantized model for fast test runs on Mac.
TEST_MODEL = os.environ.get(
    "LOOM_TEST_MLX_MODEL", "mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit"
)


def _read_json_line(proc, timeout=60.0):
    """Read one JSON line with timeout."""
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
        raise TimeoutError(f"Timed out after {timeout}s")
    if error:
        raise error[0]
    line = result[0] if result else b""
    if not line:
        raise EOFError("stdout closed")
    return json.loads(line.decode().strip())


def _send(proc, msg):
    proc.stdin.write((json.dumps(msg) + '\n').encode())
    proc.stdin.flush()


@unittest.skipUnless(HAS_MLX, "mlx-lm not available")
class TestMlxAdapter(unittest.TestCase):
    """Integration tests with real MLX engine on Apple Silicon."""

    @classmethod
    def setUpClass(cls):
        cls.proc = subprocess.Popen(
            [sys.executable, MLX_ADAPTER_PATH,
             '--model', TEST_MODEL,
             '--heartbeat-interval', '5',
             '--max-tokens', '20'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        # Wait for startup (model download + loading)
        messages = []
        for _ in range(60):
            msg = _read_json_line(cls.proc, timeout=10)
            messages.append(msg)
            if msg.get("type") == "ready":
                break
        else:
            cls.proc.kill()
            cls.proc.wait()
            stderr = cls.proc.stderr.read().decode()
            raise RuntimeError(
                f"Adapter never became ready. Got: {messages}\nStderr: {stderr}"
            )

    @classmethod
    def tearDownClass(cls):
        try:
            _send(cls.proc, {"type": "shutdown"})
            cls.proc.wait(timeout=10)
        except Exception:
            cls.proc.kill()
            cls.proc.wait()

    def test_generate_streams_tokens(self):
        _send(self.proc, {
            "type": "generate", "id": "mlx-test-1",
            "prompt": "Once upon a time",
            "params": {"max_tokens": 5},
        })
        tokens = []
        done_msg = None
        for _ in range(20):
            msg = _read_json_line(self.proc, timeout=30)
            if msg["type"] == "token":
                tokens.append(msg)
                self.assertEqual(msg["id"], "mlx-test-1")
                self.assertFalse(msg["finished"])
                self.assertIsInstance(msg["text"], str)
            elif msg["type"] == "done":
                done_msg = msg
                break
        self.assertIsNotNone(done_msg)
        self.assertEqual(done_msg["id"], "mlx-test-1")
        self.assertGreater(done_msg["tokens_generated"], 0)
        self.assertGreater(len(tokens), 0)

    def test_health_returns_memory_stats(self):
        _send(self.proc, {"type": "health"})
        resp = _read_json_line(self.proc, timeout=10)
        self.assertEqual(resp["type"], "health")
        self.assertEqual(resp["status"], "ok")
        # gpu_util is 0.0 on Apple Silicon (no Metal utilization API)
        self.assertEqual(resp["gpu_util"], 0.0)
        # Unified memory -- should report real system memory
        self.assertGreater(resp["mem_total_gb"], 0)
        self.assertGreater(resp["mem_used_gb"], 0)

    def test_memory_returns_system_memory(self):
        _send(self.proc, {"type": "memory"})
        resp = _read_json_line(self.proc, timeout=10)
        self.assertEqual(resp["type"], "memory")
        self.assertGreater(resp["total_gb"], 0)
        self.assertGreater(resp["available_gb"], 0)


if __name__ == '__main__':
    unittest.main()
```

- [ ] **Step 2: Run tests locally (should work on your Mac if mlx-lm is installed)**

Run: `python3 -m unittest test.adapter_mlx_integration_test -v`
Expected: If mlx-lm installed: 3 tests pass. If not: 3 tests skipped.

- [ ] **Step 3: Commit**

```bash
git add test/adapter_mlx_integration_test.py
git commit -m "test(adapter): add MLX integration tests (skipUnless mlx_lm)"
```

---

### Task 12: CI Workflow Update

**Files:**
- Modify: `.github/workflows/ci.yml`

Add a Python adapter test step to the test job. The base+mock tests use only stdlib so they run without pip install.

- [ ] **Step 1: Add Python adapter tests to CI workflow**

In `.github/workflows/ci.yml`, add after the "Common Test" step in the `test` job:

```yaml
      - name: Python adapter tests
        run: python3 -m unittest discover test -p "adapter_*_test.py" -v
```

Also update the docker job: **replace** the existing `Run mock adapter tests` step with a broader discovery pattern that covers both old and new tests:

```yaml
      - name: Run Python adapter tests
        run: |
          docker compose run --rm test python3 -m unittest test.mock_adapter_test -v
          docker compose run --rm test python3 -m unittest discover test -p "adapter_*_test.py" -v
```

This keeps the old mock_adapter_test running (it tests the standalone mock, not the base class) and adds the new base class tests.

- [ ] **Step 2: Verify workflow syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml')); print('OK')" 2>/dev/null || echo "Install pyyaml or verify manually"`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add Python adapter base class tests to CI pipeline"
```

---

### Task 13: GitHub Sub-Issues and ROADMAP Update

**Files:**
- Modify: `ROADMAP.md`

- [ ] **Step 1: Create design plan sub-issue for #6**

```bash
gh issue create \
  --title "Design Plan: Python adapter wrapping vLLM AsyncLLMEngine" \
  --body "Design spec: \`.github/plans/6-design.md\`

Parent: #6" \
  --label "plan"
```

Then add as sub-issue to #6:
```bash
gh issue edit <new-issue-number> --add-parent 6
```

- [ ] **Step 2: Create implementation plan sub-issue for #6**

```bash
gh issue create \
  --title "Implementation Plan: Python adapter wrapping vLLM AsyncLLMEngine" \
  --body "Implementation plan: \`.github/plans/6-implementation.md\`

Parent: #6" \
  --label "plan"
```

Then add as sub-issue to #6:
```bash
gh issue edit <new-issue-number> --add-parent 6
```

- [ ] **Step 3: Create issue for MLX adapter (pulling P1-12 forward)**

Check if #63 already exists. If so, add a comment noting it's being pulled forward to Phase 0 for local testability. If not, create it.

- [ ] **Step 4: Update ROADMAP.md**

Mark P0-06 as done. Add a note about P1-12 being pulled forward.

In the "Core Communication" section:
```markdown
- [x] `loom_adapter.py` wrapping vLLM AsyncLLMEngine — [#6](https://github.com/mohansharma-me/loom/issues/6) `P0-06`
```

In the "Additional Backends" section, add note:
```markdown
- [~] `loom_adapter_mlx.py` for MLX (Apple Silicon) — [#63](https://github.com/mohansharma-me/loom/issues/63) `P1-12` *(pulled to P0 for local testability)*
```

Update Progress Summary table (P1-12 moves to Phase 0 as in-progress):
```markdown
| Phase 0 | 17 | 6 | 1 | 10 |
| Phase 1 | 11 | 0 | 0 | 11 |
```

- [ ] **Step 5: Commit**

```bash
git add ROADMAP.md
git commit -m "docs: mark P0-06 as implemented, note P1-12 pulled forward"
```

---

## Execution Order

Tasks 1-7 are sequential (each builds on the previous). Tasks 8-11 (vLLM adapter + tests, MLX adapter + tests) are independent and can be parallelized. Task 12 (CI) depends on tasks 5-7. Task 13 (ROADMAP) is done last.

```
Task 1 (scaffold)
  → Task 2 (base skeleton)
    → Task 3 (base watchdog + loop)
      → Task 4 (mock adapter)
        → Task 5 (startup tests)
          → Task 6 (command tests)
            → Task 7 (error/shutdown tests)
              → Task 12 (CI update)

Task 3 (base complete)
  → Task 8 (vLLM adapter)  ─→ Task 9 (vLLM tests)
  → Task 10 (MLX adapter)  ─→ Task 11 (MLX tests)

All tasks → Task 13 (ROADMAP + issues)
```
