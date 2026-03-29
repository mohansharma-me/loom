# Wire Protocol Reference

Complete reference for the Loom adapter wire protocol — the communication layer
between Erlang (loom\_port) and external inference engine subprocesses.

**Source of truth:** [`src/loom_protocol.erl`](../src/loom_protocol.erl) (type specs and codecs),
[`src/loom_port.erl`](../src/loom_port.erl) (state machine and timeouts),
[`priv/python/loom_adapter_base.py`](../priv/python/loom_adapter_base.py) (Python base class),
[`priv/scripts/mock_adapter.py`](../priv/scripts/mock_adapter.py) (reference implementation).

---

## 1. Overview

The wire protocol uses **line-delimited JSON over stdio**:

- One JSON object per line, terminated by `\n` (newline).
- UTF-8 encoding.
- Direction convention:
  - `→` **Outbound** — Erlang (loom\_port) writes to adapter's stdin.
  - `←` **Inbound** — Adapter writes to stdout, read by Erlang (loom\_port).
- **Stderr** is reserved for adapter logging. Erlang never parses stderr.

Lines are framed by the Erlang port's `{line, MaxLineLength}` mode (default
1,048,576 bytes). The protocol codec (`loom_protocol:feed/2`) reassembles
partial lines and splits on `\n` boundaries.

---

## 2. Startup Sequence

```
Erlang (loom_port)              Python (adapter)
      |                               |
      |--- spawn_executable --------->|
      |                               |-- heartbeat(loading) -->|
      |<-- heartbeat(loading) --------|                         |
      |                               |   (model loading...)    |
      |<-- heartbeat(loading) --------|                         |
      |                               |   (model loaded)        |
      |<-- ready(model, backend) -----|                         |
      |                               |                         |
      |--- generate/health/etc ------>|                         |
      |<-- token/done/health ---------|                         |
```

### State Transitions

loom\_port is a `gen_statem` with four states: `spawning -> loading -> ready -> shutting_down`.

1. **spawning**: Port has been opened. Waiting for the first heartbeat.
2. **loading**: First heartbeat received. Waiting for `ready` (heartbeats reset the timeout).
3. **ready**: `ready` message received. Commands can be sent.
4. **shutting\_down**: Shutdown initiated. 3-level escalation in progress.

A `ready` message received in either `spawning` or `loading` transitions
directly to `ready` (skipping `loading` if the adapter is fast enough).

### Timeout Behavior

| Parameter | Default | Description |
|-----------|---------|-------------|
| `spawn_timeout_ms` | 5000 | Max time to receive the first heartbeat after spawn. If no heartbeat arrives, the port stops with `{shutdown, spawn_timeout}`. |
| `heartbeat_timeout_ms` | 15000 | Max gap between heartbeats during `loading`. Each heartbeat resets this timer. If it fires, the port stops with `{shutdown, heartbeat_timeout}`. |
| `shutdown_timeout_ms` | 10000 | Time to wait for graceful exit after sending `{"type": "shutdown"}` (Level 1). |
| `post_close_timeout_ms` | 5000 | Time to wait for process exit after `port_close()` (Level 2). |

If `ready` never arrives, the port times out via `heartbeat_timeout`, stops
with `{shutdown, heartbeat_timeout}`, and the supervisor restarts it.

---

## 3. Outbound Message Reference (Erlang -> Adapter)

Source: `loom_protocol.erl` — `outbound_msg()` type spec and `encode/1` clauses.

### generate

Start a text generation request.

```json
{
  "type": "generate",
  "id": "req-abc123",
  "prompt": "Hello",
  "params": {"max_tokens": 128, "temperature": 0.7}
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"generate"`. |
| `id` | string | yes | Unique request identifier. Used to correlate response messages. |
| `prompt` | string | yes | Input prompt text. |
| `params` | object | yes | Generation parameters (see below). |
| `params.max_tokens` | integer | no | Maximum number of tokens to generate. |
| `params.temperature` | float | no | Sampling temperature. |
| `params.top_p` | float | no | Nucleus sampling threshold. |
| `params.stop` | string[] | no | Stop sequences. |

### health

Request current health metrics from the adapter.

```json
{"type": "health"}
```

No additional fields.

### memory

Request current GPU memory usage.

```json
{"type": "memory"}
```

No additional fields.

### cancel

Cancel an in-flight generation request. Fire-and-forget — no response is sent.

```json
{"type": "cancel", "id": "req-abc123"}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"cancel"`. |
| `id` | string | yes | Request ID to cancel. |

### shutdown

Request graceful shutdown. See [Shutdown Protocol](#5-shutdown-protocol) for the
full escalation sequence.

```json
{"type": "shutdown"}
```

No additional fields.

### crash (test-only)

Trigger an immediate `os._exit()` with the specified exit code. **Test-only** —
used by crash recovery tests. Production code must never send this.

```json
{"type": "crash", "exit_code": 1}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"crash"`. |
| `exit_code` | integer | yes | Exit code 0-255. Triggers immediate `os._exit(exit_code)`. |

---

## 4. Inbound Message Reference (Adapter -> Erlang)

Source: `loom_protocol.erl` — `inbound_msg()` type spec and `decode_by_type/2` clauses.

### token

A single generated token in a streaming response.

```json
{
  "type": "token",
  "id": "req-abc123",
  "token_id": 1,
  "text": "Hello",
  "finished": false
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"token"`. |
| `id` | string | yes | Request ID this token belongs to. |
| `token_id` | integer (>= 0) | yes | Sequential counter for this token within the request. |
| `text` | string | yes | Decoded text for this token increment. |
| `finished` | boolean | yes | Always `false` for token messages. The `done` message is the authoritative end-of-generation signal. |

### done

Signals that generation is complete for a request.

```json
{
  "type": "done",
  "id": "req-abc123",
  "tokens_generated": 47,
  "time_ms": 1820
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"done"`. |
| `id` | string | yes | Request ID that completed. |
| `tokens_generated` | integer (>= 0) | yes | Total number of tokens generated for this request. |
| `time_ms` | integer (>= 0) | yes | Total generation time in milliseconds. |

### error

Reports an error. Can be request-scoped (with `id`) or protocol-level (with `id` null or absent).

```json
{
  "type": "error",
  "id": "req-abc123",
  "code": "model_error",
  "message": "CUDA OOM"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"error"`. |
| `id` | string or null | no | Request ID, or `null`/absent for protocol-level errors. Erlang decodes `null` to `undefined`. |
| `code` | string | yes | Machine-readable error code (see [Error Handling Contract](#6-error-handling-contract)). |
| `message` | string | yes | Human-readable error description. |

### health\_response

Response to a `health` command. Note: the `type` field is `"health"`, not `"health_response"` — the Erlang decoder distinguishes inbound health from outbound health by direction.

```json
{
  "type": "health",
  "status": "ok",
  "gpu_util": 0.73,
  "mem_used_gb": 62.4,
  "mem_total_gb": 80.0
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"health"`. |
| `status` | string | yes | Health status (e.g., `"ok"`). |
| `gpu_util` | float | yes | GPU utilization as a fraction (0.0 to 1.0). |
| `mem_used_gb` | float | yes | GPU memory in use, in GB. |
| `mem_total_gb` | float | yes | Total GPU memory, in GB. |

### memory\_response

Response to a `memory` command. The `type` field is `"memory"` on the wire.

```json
{
  "type": "memory",
  "total_gb": 80.0,
  "used_gb": 62.4,
  "available_gb": 17.6
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"memory"`. |
| `total_gb` | float | yes | Total GPU memory in GB. |
| `used_gb` | float | yes | GPU memory currently in use, in GB. |
| `available_gb` | float | yes | Available GPU memory in GB. |

Additional fields beyond the required three are preserved by the Erlang decoder
(the `type` key is stripped, all others are kept in the `memory_response` map).

### ready

Signals that the adapter has finished loading and is ready to accept commands.
Sent once during startup, after all heartbeats.

```json
{
  "type": "ready",
  "model": "Qwen/Qwen2.5-1.5B-Instruct",
  "backend": "vllm"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"ready"`. |
| `model` | string | yes | Model identifier (e.g., HuggingFace model path). |
| `backend` | string | yes | Inference backend name (e.g., `"vllm"`, `"mlx"`, `"mock"`). |

### heartbeat

Sent periodically during model loading to keep loom\_port's heartbeat timeout alive.

```json
{
  "type": "heartbeat",
  "status": "loading",
  "detail": "downloading weights"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | Always `"heartbeat"`. |
| `status` | string | yes | Current status (e.g., `"loading"`). |
| `detail` | string | no | Human-readable progress description. Defaults to `""` when absent. |

---

## 5. Shutdown Protocol

loom\_port implements a 3-level escalation when shutting down an adapter subprocess.
Each level is a fallback if the previous level fails within its timeout.

```
Level 1: Send {"type": "shutdown"} via stdin
  |  adapter should flush, cleanup, exit(0)
  |  wait shutdown_timeout_ms (default 10000)
  v
Level 2: port_close() -- closes stdin, triggers EOF
  |  adapter's stdin watchdog detects EOF, calls os._exit(1)
  |  wait post_close_timeout_ms (default 5000)
  v
Level 3: OS force-kill (loom_os:force_kill/1)
  |  SIGKILL on Unix (kill -9), taskkill /F on Windows
  v  process is dead
```

### Why Three Levels?

**Level 1 — Graceful shutdown.** The adapter receives the shutdown command and
can save state, flush output buffers, and exit cleanly with code 0. This is the
happy path.

**Level 2 — Stdin EOF.** Closing the Erlang port closes the adapter's stdin pipe.
A dedicated watchdog thread in the adapter detects EOF on stdin and calls
`os._exit(1)` to force-terminate immediately. This level exists because Python's
signal handling is unreliable in threaded programs — a shutdown command could be
missed if the main thread is blocked on a GPU operation. The stdin watchdog is a
cross-platform mechanism that works on both Unix and Windows.

**Level 3 — OS kill.** Last resort for truly stuck processes. If the adapter is
unresponsive even to stdin EOF (e.g., the GPU driver is hung, or the watchdog
thread was killed), `loom_os:force_kill/1` sends `SIGKILL` on Unix or
`taskkill /F /PID` on Windows. The process is unconditionally terminated.

### Implementation Details

In the `shutting_down` state of loom\_port's gen\_statem:

1. **On enter:** Send `{"type": "shutdown"}` via `port_command/2`. Start
   `shutdown_timeout_ms` timer.
2. **On `shutdown_timeout`:** Call `port_close(Port)` to close stdin. Store the
   closed port reference for matching late `exit_status` messages. Start
   `post_close_timeout_ms` timer.
3. **On `post_close_timeout`:** Call `loom_os:force_kill(OsPid)`. Notify owner
   with `{loom_port_exit, Ref, killed}`. Stop the gen\_statem.
4. **On `exit_status` at any point:** The process exited (success or failure).
   Notify owner and stop.

---

## 6. Error Handling Contract

### Adapter Error Codes

Error codes returned by adapters in `error` messages:

| Code | Meaning |
|------|---------|
| `invalid_json` | Input was not valid JSON. |
| `missing_type` | JSON object had no `type` field. |
| `unknown_type` | Unrecognized `type` value. |
| `missing_field` | A required field was absent from the message. |
| `invalid_exit_code` | The `exit_code` in a `crash` message was not 0-255. |
| `internal_error` | Unexpected adapter error (exception in handler). |
| `model_error` | Engine-specific error (e.g., CUDA OOM, model load failure). |

### Erlang-Side Decode Errors

`loom_protocol:decode/1` returns `{error, Reason}` where `Reason` is one of:

| Reason | Form |
|--------|------|
| Invalid JSON | `{invalid_json, Term}` |
| Missing type field | `missing_type` |
| Unknown type string | `{unknown_type, Binary}` |
| Type field not a string | `{invalid_type_field, Value}` |
| Required field missing | `{missing_field, FieldName, TypeName}` |
| Field has wrong type | `{invalid_field, FieldName, ExpectedType, ActualValue}` |

### What Happens on Errors

**Protocol/decode errors** (invalid JSON, missing fields, unknown types):
loom\_port notifies the owner with `{loom_port_error, Ref, {decode_error, Reason}}`.
The message is dropped. The port remains open.

**Adapter crash** (port sends `exit_status`):
loom\_port notifies the owner with `{loom_port_exit, Ref, ExitCode}` and stops.
The coordinator (`loom_engine_coordinator`) then:
1. Notifies **all** in-flight callers with `{loom_error, RequestId, <<"engine_crashed">>, ExitCodeBinary}`.
2. Clears the in-flight request table.
3. Attempts self-heal by starting a new port.

**Generation error** (adapter sends an `error` message with a request `id`):
loom\_port forwards the error to the owner via `{loom_port_msg, Ref, {error, Id, Code, Message}}`.
The coordinator routes it to the specific request caller.

**Heartbeat timeout** (ready never arrives, or heartbeats stop):
loom\_port stops with `{shutdown, heartbeat_timeout}`. The coordinator notifies
all in-flight callers with `{loom_error, RequestId, <<"engine_timeout">>, <<"heartbeat_timeout">>}`
and transitions to `stopped`.

---

## 7. Writing a New Adapter

### Option A: Subclass LoomAdapterBase (recommended)

For production adapters that wrap a real inference engine.

**Step 1.** Create `priv/python/loom_adapter_<name>.py`.

**Step 2.** Subclass `LoomAdapterBase` from `priv/python/loom_adapter_base.py`.

**Step 3.** Implement the 5 abstract methods:

| Method | Signature | Description |
|--------|-----------|-------------|
| `load_model()` | `async def load_model(self) -> tuple` | Load the model. Return `(model_name, backend_name)`. Heavy imports go here. |
| `generate()` | `async def generate(self, request_id, prompt, params) -> None` | Stream tokens via `self.send_token()`, then call `self.send_done()`. |
| `get_health()` | `async def get_health(self) -> dict` | Return `{"status", "gpu_util", "mem_used_gb", "mem_total_gb"}`. |
| `get_memory()` | `async def get_memory(self) -> dict` | Return `{"total_gb", "used_gb", "available_gb"}`. |
| `cancel_request()` | `async def cancel_request(self, request_id) -> None` | Cancel in-flight generation. Add ID to `self.cancelled_requests`. |

**Step 4.** Add a `__main__` entry point:

```python
if __name__ == "__main__":
    MyAdapter.main()
```

The base class handles everything else: stdin watchdog, heartbeat loop during
model loading, command dispatch, protocol I/O, and error wrapping.

To add backend-specific CLI arguments, override the `add_args(cls, parser)` classmethod.

### Option B: Standalone Script (for testing/prototyping)

For quick tests without the base class. See `priv/scripts/mock_adapter.py` for a
complete working example.

**1. Protocol I/O.** Read stdin line by line, write JSON to stdout. All messages
are line-delimited JSON. Use stderr for logging — never write non-JSON to stdout.

```python
import json, sys

def send_msg(msg):
    sys.stdout.write(json.dumps(msg) + '\n')
    sys.stdout.flush()
```

**2. Startup sequence.** Send at least one heartbeat with `status=loading`, then
send `ready` with `model` and `backend`:

```python
send_msg({"type": "heartbeat", "status": "loading", "detail": "initializing"})
# ... load model ...
send_msg({"type": "ready", "model": "my-model", "backend": "custom"})
```

**3. Command loop.** Parse each stdin line as JSON, dispatch by `type` field,
return response messages:

```python
while True:
    line = line_queue.get().decode().strip()
    msg = json.loads(line)
    if msg["type"] == "health":
        send_msg({"type": "health", "status": "ok", ...})
    elif msg["type"] == "generate":
        # stream tokens, then done
        ...
```

**4. Stdin watchdog.** A daemon thread that reads stdin; on EOF, calls
`os._exit(1)`. This is critical for cleanup — it ensures the adapter exits when
Erlang closes the port.

```python
import threading, os

def stdin_watchdog(line_queue):
    while True:
        line = sys.stdin.buffer.readline()
        if not line:  # EOF
            os._exit(1)
        line_queue.put(line)

watchdog = threading.Thread(target=stdin_watchdog, args=(q,), daemon=True)
watchdog.start()
```

**5. Token streaming.** For `generate`, send `token` messages one at a time
(with `finished: false`), then a single `done` message:

```python
for i, text in enumerate(tokens):
    send_msg({"type": "token", "id": req_id, "token_id": i + 1,
              "text": text, "finished": False})
send_msg({"type": "done", "id": req_id,
          "tokens_generated": len(tokens), "time_ms": elapsed})
```

**6. Shutdown handler.** On `{"type": "shutdown"}`, flush buffers and exit
cleanly:

```python
if msg["type"] == "shutdown":
    sys.stdout.flush()
    os._exit(0)
```

### Testing Your Adapter

**Test protocol directly** (no Erlang needed):

```bash
echo '{"type": "health"}' | python3 priv/scripts/mock_adapter.py
```

**Test via loom\_port in Erlang shell:**

```bash
rebar3 shell
```

```erlang
{ok, Pid} = loom_port:start_link(#{
    command => os:find_executable("python3"),
    args => ["priv/scripts/mock_adapter.py"]
}).
loom_port:send(Pid, {health}).
```

### Configuration

Engine configuration in Loom's JSON config (`config/loom.json`):

```json
{
  "engines": [
    {
      "name": "my_engine",
      "backend": "custom",
      "model": "my-model",
      "adapter_cmd": "/path/to/my_adapter",
      "gpu_ids": [0]
    }
  ]
}
```

For known backends (`vllm`, `mlx`, `tensorrt`, `mock`), Loom wraps the adapter
with `python3` automatically. For custom backends, `adapter_cmd` is executed
directly as the port command.
