# P0-06 Design: Python Adapter wrapping vLLM AsyncLLMEngine + MLX Backend

> Design spec for [#6](https://github.com/mohansharma-me/loom/issues/6) and [#63](https://github.com/mohansharma-me/loom/issues/63) (pulled forward from P1-12 for local testability on Apple Silicon).

## Overview

Create a shared Python adapter base class and three backend implementations (vLLM, MLX, Mock) that communicate with `loom_port` via the line-delimited JSON wire protocol defined in `loom_protocol.erl`. Each adapter is a standalone executable script launched by `loom_port` as a subprocess.

## File Layout

```
priv/python/
  loom_adapter_base.py          # Abstract base class (stdlib only)
  loom_adapter_vllm.py          # vLLM 0.6.x backend (executable)
  loom_adapter_mlx.py           # mlx-lm backend (executable)
  loom_adapter_mock.py          # Mock backend for CI testing of base class
  requirements-vllm.txt         # vllm>=0.6.0,<0.7.0
  requirements-mlx.txt          # mlx-lm>=0.20.0, psutil

test/
  mock_adapter_test.py              # Existing (keep, tests standalone mock)
  adapter_base_test.py              # Tests base class via mock adapter
  adapter_vllm_integration_test.py  # skipUnless vllm + CUDA available
  adapter_mlx_integration_test.py   # skipUnless mlx_lm importable
```

### Relation to existing mock_adapter.py

`priv/scripts/mock_adapter.py` stays as-is. It is stdlib-only and used by existing `loom_port` Erlang tests. The new mock adapter in `priv/python/loom_adapter_mock.py` subclasses the base and serves as the CI test vehicle for the base class protocol layer. The old mock can be deprecated once the new one is proven.

### Backend selection

Each adapter is a separate script. The Erlang side (currently `loom_port`, eventually `loom_engine_coordinator` in P0-08) launches the right script via the `command` option. Config-driven backend selection (`{"backend": "mlx", "model": "...", ...}`) is a future concern (CC-04 `loom_config` + P0-08 coordinator). For P0-06, tests and manual usage pass the script path directly.

## Architecture: Shared Base Class (ABC)

### Approach

Approach 1 (shared ABC) was chosen over composition (Approach 2) and minimal shared utilities (Approach 3). The protocol/lifecycle layer is non-trivial (watchdog, heartbeat loop, graceful shutdown, error wrapping) and must be identical across all backends. An ABC makes this explicit and enforceable.

### Async Strategy

Option C: asyncio base with abstract coroutines. Both backends implement `async def` methods. vLLM is natively async. MLX wraps its synchronous calls in `loop.run_in_executor()` inside its own `async def` implementations. The base class does not need to know which pattern the backend uses.

### Base Class: loom_adapter_base.py

**Lifecycle:**

```
__init__(args) -> run() -> _startup_sequence() -> _command_loop()
                                |                       |
                           load_model()            dispatch commands
                           heartbeat loop          until shutdown/EOF
```

**Key components:**

1. **`run()`** -- entry point. Starts stdin watchdog thread, creates asyncio event loop, runs `_startup_sequence()` then `_command_loop()`.

2. **Stdin watchdog thread** -- daemon thread reads `sys.stdin.buffer.readline()`, puts lines in a `queue.Queue`, calls `os._exit(1)` on EOF. Sole stdin reader. Same proven pattern as `mock_adapter.py`.

3. **`_startup_sequence()`** -- sends initial heartbeat, calls `await self.load_model()`, sends periodic heartbeats while model loads (configurable interval, default 5s), sends `ready` when done. **Critical:** the first heartbeat MUST be sent before any heavy imports (vLLM, MLX) occur. Subclass `__init__` must not perform heavy imports that delay `run()`. Heavy imports happen inside `load_model()`, which runs after the first heartbeat is already sent. This ensures `loom_port` transitions from `spawning` to `loading` before the `spawn_timeout_ms` (default 5s) fires.

**Heartbeat/timeout coordination with loom_port:** The adapter's `--heartbeat-interval` (default 5s) must be strictly less than `loom_port`'s `heartbeat_timeout_ms` (default 15s). Each heartbeat resets the Erlang-side timeout. If the adapter interval exceeds the port timeout, `loom_port` will kill the subprocess during model loading. This constraint should be documented in CLI `--help` and validated at startup.

4. **`_command_loop()`** -- pulls lines from queue via `loop.run_in_executor` (non-blocking), parses JSON, dispatches to handler by `type` field.

5. **Dispatch table:**
   - `generate` -> `await self.generate(request_id, prompt, params)`
   - `health` -> `await self.get_health()`
   - `memory` -> `await self.get_memory()`
   - `cancel` -> `await self.cancel_request(request_id)`
   - `shutdown` -> flush, `os._exit(0)`

6. **`send_msg(msg)`** -- writes JSON + newline to stdout, flushes. Only called from asyncio loop.

7. **Error wrapping** -- every command dispatch wrapped in try/except. Single-request failures send `error` response, never crash the adapter.

8. **CLI arg parsing** -- base adds common args (`--model`, `--heartbeat-interval`, `--log-level`). Subclasses extend via `classmethod add_args(parser)`.

**Abstract methods (5):**

```python
@abstractmethod
async def load_model(self) -> tuple[str, str]:
    """Load the model. Return (model_name, backend_name) for the ready message."""

@abstractmethod
async def generate(self, request_id: str, prompt: str, params: dict) -> None:
    """Stream tokens via self.send_token(), then self.send_done()."""

@abstractmethod
async def get_health(self) -> dict:
    """Return {"status", "gpu_util", "mem_used_gb", "mem_total_gb"}."""

@abstractmethod
async def get_memory(self) -> dict:
    """Return {"total_gb", "used_gb", "available_gb"}."""

@abstractmethod
async def cancel_request(self, request_id: str) -> None:
    """Cancel an in-progress generation. Fire-and-forget."""
```

**Helper methods provided by base:**

- `send_token(request_id, token_id, text, finished)` -- sends a `token` message
- `send_done(request_id, tokens_generated, time_ms)` -- sends a `done` message
- `send_error(request_id, code, message)` -- sends an `error` message. When `request_id` is `None`, the `id` field is serialized as JSON `null` (which `loom_protocol.erl` decodes as `undefined`). Never serialize Python `None` as the string `"None"`.

**Streaming contract for `generate()`:** The method communicates via side-effect helper calls rather than returning an async iterator. This is because vLLM returns cumulative text that requires diffing inside the adapter, making the adapter responsible for the streaming loop. The contract is:
1. Send each token with `send_token(..., finished=False)`
2. After the last token, send `send_done(...)` as a separate message
3. The `finished` field on `token` messages is always `False` -- the `done` message is the authoritative end-of-generation signal (matching `mock_adapter.py` behavior)

**Stdout buffering:** The base class `run()` method sets `sys.stdout.reconfigure(line_buffering=True)` as defense-in-depth. All protocol output still goes through `send_msg()` which explicitly flushes, but this prevents interleaved/delayed output if a subclass accidentally writes to stdout outside the helper.

## vLLM Adapter: loom_adapter_vllm.py

Targets vLLM 0.6.x with `AsyncLLMEngine` and `SamplingParams`.

**CLI args (beyond base):**
- `--tensor-parallel-size` (default 1)
- `--dtype` (default `auto`)
- `--gpu-memory-utilization` (default 0.9)
- `--max-model-len` (optional)

**load_model():**

```python
from vllm import AsyncLLMEngine, AsyncEngineArgs

engine_args = AsyncEngineArgs(
    model=self.args.model,
    tensor_parallel_size=self.args.tensor_parallel_size,
    dtype=self.args.dtype,
    gpu_memory_utilization=self.args.gpu_memory_utilization,
)
self.engine = AsyncLLMEngine.from_engine_args(engine_args)
return (self.args.model, "vllm")
```

**generate():**

Uses `self.engine.generate(prompt, sampling_params, request_id)` which returns an async generator of `RequestOutput`. Each output has cumulative text in `outputs[0].text` -- the adapter diffs to extract incremental tokens.

**ASSUMPTION:** `token_id` in the protocol is a 1-based sequence counter per request, not a vocabulary token ID. Sufficient for Phase 0.

**get_health():**

Queries `pynvml` (installed transitively with vllm):
```python
import pynvml
handle = pynvml.nvmlDeviceGetHandleByIndex(0)
util = pynvml.nvmlDeviceGetUtilizationRates(handle)
mem = pynvml.nvmlDeviceGetMemoryInfo(handle)
```

**ASSUMPTION:** For TP > 1, reports stats from GPU 0 only. Multi-GPU aggregation is a P0-07 concern.

**get_memory():**

Same `pynvml` memory info, returning `total_gb`, `used_gb`, `available_gb`.

**cancel_request():**

Calls `await self.engine.abort(request_id)`.

**In-flight tracking:** `Set[str]` of active request IDs. `generate()` adds on start, removes on completion. `cancel_request()` checks membership before calling `abort()`.

## MLX Adapter: loom_adapter_mlx.py

Wraps `mlx-lm` for Apple Silicon inference.

**CLI args (beyond base):**
- `--max-tokens` (default 256)
- `--dtype` (default `float16`)

**load_model():**

```python
from mlx_lm import load

# Synchronous -- wrapped in executor
loop = asyncio.get_event_loop()
self.model, self.tokenizer = await loop.run_in_executor(
    None, lambda: load(self.args.model)
)
return (self.args.model, "mlx")
```

**generate():**

Uses `mlx_lm.utils.generate_step` -- a synchronous generator. Wrapped to yield back to event loop periodically. Checks `self.cancelled_requests` between tokens for cancellation support.

**ASSUMPTION:** `mlx_lm.utils.generate_step` is the low-level streaming API. Exact signature pinned to mlx-lm version.

**Concurrency limitation:** MLX runs single-request at a time. There is no continuous batching in mlx-lm (unlike vLLM's `AsyncLLMEngine`). Concurrent `generate` calls will be serialized. **This is an mlx-lm limitation, not a Loom architectural constraint.** The adapter protocol fully supports concurrent requests via `request_id`. If mlx-lm adds batching support in the future, the adapter can adopt it without protocol changes. For Phase 0 local development and testing, single-request throughput is sufficient.

**get_health():**

Apple Silicon uses unified memory. No direct Metal GPU utilization API exists.

```python
import psutil
mem = psutil.virtual_memory()
return {
    "status": "ok",
    "gpu_util": 0.0,  # No Metal utilization API
    "mem_used_gb": mem.used / (1024**3),
    "mem_total_gb": mem.total / (1024**3),
}
```

**ASSUMPTION:** `gpu_util` reported as 0.0 -- known limitation. Value present for protocol validity.

**ASSUMPTION:** On unified memory Macs, system memory IS GPU memory. `psutil.virtual_memory()` is the closest equivalent to NVML memory stats.

**get_memory():**

Same `psutil.virtual_memory()`, returning `total_gb`, `used_gb`, `available_gb`.

**cancel_request():**

Cooperative cancellation via `self.cancelled_requests: Set[str]`. The `generate()` loop checks this set between tokens and breaks early if found.

## Mock Adapter: loom_adapter_mock.py

Subclasses the base for CI testing. Exercises the full base class without external dependencies.

- `load_model()` -- optional `--startup-delay` sleep, returns `("mock", "mock")`
- `generate()` -- yields 5 hardcoded tokens with small delays
- `get_health()` -- returns zeroed stats
- `get_memory()` -- returns 80GB H100-approximation
- `cancel_request()` -- adds to cancelled set

## Error Handling

**Base class error wrapping:**

```python
try:
    await self.handle_command(msg)
except Exception as e:
    self.send_error(msg.get("id"), "internal_error", f"{type(e).__name__}: {e}")
```

**Adapter exit conditions:**
- `shutdown` command -> `os._exit(0)`
- stdin EOF (watchdog) -> `os._exit(1)`
- Unrecoverable error during `load_model()` -> `os._exit(2)`

**Edge cases:**

| Scenario | Behavior |
|----------|----------|
| Malformed JSON | `error` response, `code: "invalid_json"` |
| Missing `type` field | `error`, `code: "missing_type"` |
| Unknown command type | `error`, `code: "unknown_type"` |
| `generate` missing `id` | `error`, `code: "missing_field"` |
| Engine error mid-generation | `error` with request `id`, adapter continues |
| `cancel` for unknown ID | No-op, no response (fire-and-forget). If `cancel_request()` raises, the error wrapper sends an `error` response as safety net |
| Model fails to load | Log to stderr, exit code 2 |
| Blank lines on stdin | Ignored silently |
| Multiple rapid requests (vLLM) | Concurrent via AsyncLLMEngine |
| Multiple rapid requests (MLX) | Serialized (mlx-lm limitation) |

**Logging:** All diagnostic output to stderr. Uses Python `logging` with `--log-level` CLI arg.

## Wire Protocol Compatibility

No protocol changes. The adapters implement the exact wire format defined in `loom_protocol.erl` and already spoken by `mock_adapter.py`.

**Outbound (Erlang -> adapter stdin):**

| Command | Fields |
|---------|--------|
| `generate` | `type, id, prompt, params` |
| `health` | `type` |
| `memory` | `type` |
| `cancel` | `type, id` |
| `shutdown` | `type` |

**Inbound (adapter stdout -> Erlang):**

| Response | Fields |
|----------|--------|
| `heartbeat` | `type, status, detail` |
| `ready` | `type, model, backend` |
| `token` | `type, id, token_id, text, finished` |
| `done` | `type, id, tokens_generated, time_ms` |
| `health` | `type, status, gpu_util, mem_used_gb, mem_total_gb` |
| `memory` | `type, total_gb, used_gb, available_gb` |
| `error` | `type, id, code, message` |

## Dependencies

**vLLM adapter (`requirements-vllm.txt`):**
```
vllm>=0.6.0,<0.7.0
```
(pynvml installed transitively)

**MLX adapter (`requirements-mlx.txt`):**
```
mlx-lm>=0.20.0
psutil
```
(mlx installed transitively)

**Base class and mock adapter:** stdlib only.

## Testing

**`adapter_base_test.py`** -- spawns `loom_adapter_mock.py` as subprocess:
- Startup protocol: heartbeat(s) -> ready
- All 5 command types: generate, health, memory, cancel, shutdown
- Error handling: malformed JSON, missing fields, unknown types
- Stdin watchdog: close stdin -> adapter exits
- Startup delay with heartbeat loop

**`adapter_vllm_integration_test.py`** -- `@unittest.skipUnless(vllm + CUDA)`:
- Loads a small model
- Generate request with token streaming
- Health/memory return real GPU stats

**`adapter_mlx_integration_test.py`** -- `@unittest.skipUnless(mlx_lm)`:
- Loads `mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit`
- Generate request with token streaming
- Health/memory return real unified memory stats

**Test runner:** Python tests are run via `python -m unittest discover test/ -p "adapter_*_test.py"` (or `python -m pytest test/` if pytest is available). CI invokes this in the GitHub Actions workflow alongside the Erlang tests.

**CI:** Base + mock tests run unconditionally. Integration tests run when environment supports them. GPU CI setup is P0-14 scope.

## Assumptions Summary

- vLLM 0.6.x `AsyncLLMEngine.generate()` returns async generator of `RequestOutput` with cumulative text
- `mlx_lm.utils.generate_step` is the streaming API; exact signature pinned to mlx-lm version
- `token_id` is a 1-based sequence counter, not vocabulary ID
- For TP > 1, vLLM health reports GPU 0 only; multi-GPU aggregation is P0-07
- Apple Silicon `gpu_util` reported as 0.0 (no Metal utilization API)
- Unified memory on Mac means `psutil.virtual_memory()` approximates GPU memory
- Config-driven backend selection is a future concern (P0-08 coordinator + CC-04 loom_config)
- MLX single-request serialization is an mlx-lm limitation, not Loom's
