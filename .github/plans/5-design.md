# Design: loom_port GenServer for Port-based subprocess management

**Issue:** [#5 — P0-05](https://github.com/mohansharma-me/loom/issues/5)
**Date:** 2026-03-23
**Status:** Approved

---

## Overview

`loom_port` is a `gen_statem` process that manages an external OS subprocess via Erlang's `open_port/2`. It is the foundational communication layer between the BEAM and inference engine adapters. It owns the Port, sends encoded commands, receives and decodes responses, detects crashes, manages startup readiness via heartbeats, and executes a 3-level shutdown escalation.

The module is **engine-agnostic** — it takes a command path and arguments, and forwards decoded messages to an owner process. It does not know about vLLM, TensorRT-LLM, or MLX.

---

## Design Decisions

### Owner process model (not callback behaviour)

Decoded messages are sent directly to the owner pid as Erlang messages (`{loom_port_msg, Ref, Msg}`), following the same pattern as `gen_tcp`'s controlling process. This avoids premature abstraction — only `loom_engine_coordinator` will consume these messages in practice.

**Performance:** Message passing adds ~0.1-1us per message (term copy + mailbox enqueue). This is negligible compared to Port I/O (10-100us) and token generation rate (~50-200 tokens/sec). Large binaries (>64 bytes) are reference-counted, not copied.

### gen_statem (not gen_server)

`loom_port` is fundamentally a state machine with distinct states that accept different events. `gen_statem` makes state boundaries impossible to violate at the framework level, provides built-in `state_timeout` for heartbeat and shutdown timers, and is more self-documenting than manual state tracking in a `gen_server` record.

**Serialization is correct:** One stdin pipe + one stdout pipe = inherently serial I/O. The `gen_statem` reflects this physical constraint. Concurrency comes from multiple `loom_port` instances (one per engine), not parallelism within a single Port.

### Async startup with heartbeat-guarded loading

All three supported backends (vLLM, TensorRT-LLM, MLX) have blocking, potentially very long initialization (seconds to tens of minutes). None provides a native async readiness callback.

`start_link` returns immediately after the OS process spawns. The adapter sends periodic heartbeats during model loading. `loom_port` tracks the last heartbeat time and declares timeout only if heartbeats stop — not based on wall-clock time since spawn. A model that takes 30 minutes to load is fine as long as heartbeats keep arriving.

### Port {line, N} framing (not manual buffering)

The Port is opened with `{line, MaxLineLen}` which delivers complete lines as `{eol, Line}` messages. This delegates line framing to the Port driver (C-level). `loom_protocol:feed/2` is NOT used by `loom_port` because `{line, N}` handles line framing at the Port driver level — using both would be redundant. `feed/2` remains available for other consumers (e.g., tests, future gRPC raw byte streams). The `noeol` case (line exceeds max length) is handled by accumulating fragments in the `line_buf` field of the state data record until a final `{eol, _}` arrives.

### 3-level shutdown escalation

Designed to be cross-platform and forward-compatible with the Phase 4+ gRPC migration (where Port is retained for lifecycle, gRPC takes over data path).

---

## State Machine

```
  spawning ----> loading ----> ready ----> shutting_down
     |              |            |              |
     +---error------+---error----+---error------+--> (terminate)
```

### States

| State | Entry condition | Accepts | Exits to |
|-------|----------------|---------|----------|
| `spawning` | `init/1` — Port opened | Port data only | `loading` (first heartbeat), `ready` (immediate ready, no heartbeat needed), `shutting_down` (shutdown called) |
| `loading` | First heartbeat arrives | Heartbeats from adapter | `ready` (ready msg), `shutting_down` (shutdown called), terminate (heartbeat timeout) |
| `ready` | `ready` message decoded | `send/2` calls, Port data | `shutting_down` (shutdown called), terminate (Port exit) |
| `shutting_down` | `shutdown/1` called from any state | Port exit signals | terminate (exit received or escalation timeout) |

**Note:** `shutdown/1` is accepted in ALL states, transitioning to `shutting_down`. This handles application shutdown, supervisor termination, and coordinator-initiated stop during any phase including loading. A `ready` message from the adapter is treated as an implicit "loading complete" signal — adapters that skip the loading phase (e.g., pre-loaded models) can send `ready` immediately without any preceding heartbeat.

### Per-state behavior

**Internal state data record:**
```erlang
-record(data, {
    port          :: port() | undefined,
    os_pid        :: non_neg_integer() | undefined,
    ref           :: reference(),
    owner         :: pid(),
    owner_mon     :: reference(),        %% monitor ref for owner process
    line_buf      :: binary(),           %% accumulator for noeol fragments
    opts          :: map()
}).
```

`erlang:monitor(process, Owner)` is called in `init/1` — the owner is guaranteed alive at that point since `gen_statem:start_link/3` is synchronous.

**spawning:**
- Opens Port with `{spawn_executable, Cmd}`, options: `[{line, MaxLineLen}, stderr_to_stdout, binary, exit_status, use_stdio]`
- Captures OS pid via `erlang:port_info(Port, os_pid)`
- Sets `{state_timeout, SpawnTimeoutMs, spawn_timeout}` (default 5s)
- Port exit in this state -> notify owner, terminate

**loading:**
- Each heartbeat resets `{state_timeout, HeartbeatTimeoutMs, heartbeat_timeout}` by re-entering the same state
- If timeout fires (3 missed heartbeats at default 5s interval) -> notify owner `{loom_port_timeout, Ref}`, terminate
- If `ready` arrives -> transition to `ready`

**ready:**
- Notifies owner `{loom_port_ready, Ref, Model, Backend}` on entry
- Owner sends commands via `loom_port:send(Pid, OutboundMsg)` -> encoded and written to Port stdin
- Incoming Port data decoded and forwarded as `{loom_port_msg, Ref, InboundMsg}`
- Port exit -> notify owner `{loom_port_exit, Ref, ExitCode}`, terminate

**shutting_down:**
- Sends `{shutdown}` encoded to stdin
- Sets `{state_timeout, ShutdownTimeoutMs, shutdown_timeout}` (default 10s)
- Port exits within timeout -> notify owner `{loom_port_exit, Ref, ExitCode}`, terminate
- Timeout fires -> `port_close(Port)` (closes stdin, adapter stdin-watchdog calls `os._exit(1)`)
- After `port_close`, waits up to 5s (`post_close_timeout_ms`, configurable) for exit signal
- If exit signal arrives -> notify owner `{loom_port_exit, Ref, killed}`, terminate
- If no exit signal after post-close timeout -> log warning about orphaned process (OS pid captured at spawn), notify owner `{loom_port_exit, Ref, killed}`, terminate. The orphaned process is a known edge case when the adapter is truly stuck (e.g., hung CUDA kernel); OS-level cleanup is deferred to external monitoring (loom_gpu_monitor or container runtime)

---

## Public API

```erlang
-module(loom_port).
-behaviour(gen_statem).

%% --- Lifecycle ---

-spec start_link(Opts :: map()) -> {ok, pid()} | {error, term()}.
%% Opts:
%%   command => string()                 -- path to executable (required)
%%   args => [string()]                  -- command arguments (default: [])
%%   owner => pid()                      -- message recipient (default: self())
%%   max_line_length => pos_integer()    -- Port line buffer (default: 1048576 = 1MB)
%%   heartbeat_timeout_ms => pos_integer() -- ms since last heartbeat (default: 15000)
%%   shutdown_timeout_ms => pos_integer()  -- ms to wait after shutdown cmd (default: 10000)
%%   spawn_timeout_ms => pos_integer()     -- ms for first heartbeat/ready (default: 5000)
%%   post_close_timeout_ms => pos_integer() -- ms to wait after port_close for exit (default: 5000)

-spec send(pid(), loom_protocol:outbound_msg()) -> ok | {error, not_ready}.
%% Sends a command to the adapter. Only works in `ready` state.
%% Synchronous call — returns ok if command was written to stdin,
%% or {error, not_ready} if not in ready state. Responses from
%% the adapter arrive asynchronously as {loom_port_msg, ...}.

-spec shutdown(pid()) -> ok.
%% Initiates 3-level shutdown. Async — returns immediately.

-spec get_state(pid()) -> spawning | loading | ready | shutting_down.
%% Introspection for debugging and tests.
```

### Messages sent to owner

```erlang
{loom_port_ready, Ref, Model :: binary(), Backend :: binary()}
%% Adapter finished loading, ready to accept commands.

{loom_port_msg, Ref, loom_protocol:inbound_msg()}
%% Decoded message from adapter (token, done, health_response, etc.)

{loom_port_exit, Ref, ExitCode :: non_neg_integer() | killed}
%% Port process exited. `killed` if escalated to port_close.

{loom_port_timeout, Ref}
%% Heartbeat timeout during loading. Process terminates after this.

{loom_port_error, Ref, {decode_error, Reason :: term()}}
%% Adapter sent malformed data that failed protocol decode.
%% loom_port continues operating — this is informational, not fatal.
```

`Ref` is created via `make_ref()` at `start_link` time — unique, lightweight, allows owner to distinguish multiple `loom_port` instances.

---

## Shutdown Sequence

```
Owner calls shutdown/1
        |
        v
  shutting_down (enter)
  1. Send {shutdown} via stdin
  2. Set state_timeout = 10s
        |
   +----+-------+
   v             v
Port exits    Timeout fires
within 10s    (level 2)
   |             |
   v             v
Owner gets    port_close(Port)
{exit, Code}  -> stdin EOF
   |          -> adapter watchdog
terminate       calls os._exit(1)
                 |
                 v
              Owner gets
              {exit, killed}
                 |
              terminate
```

**Edge cases:**
- `send/2` during `shutting_down` -> returns `{error, not_ready}`
- `send/2` during `spawning` or `loading` -> returns `{error, not_ready}`
- Port exits during `ready` (crash) -> owner notified directly, never enters `shutting_down`
- `shutdown/1` from any state -> transitions to `shutting_down` (sends shutdown command if Port is open)
- Double `shutdown/1` call -> no-op (already in `shutting_down`)
- Owner dies -> `loom_port` monitors owner (monitor set in `init/1`), initiates shutdown automatically (prevents orphaned adapter holding GPU memory)
- Decode error on incoming Port data -> log warning, send `{loom_port_error, Ref, {decode_error, Reason}}` to owner, continue operating (do not crash on a single bad message)

---

## Protocol Additions

### New heartbeat message (adapter -> Erlang only)

Wire format:
```json
{"type": "heartbeat", "status": "loading", "detail": "loading weights 3/32 layers"}
```

Erlang type:
```erlang
{heartbeat, Status :: binary(), Detail :: binary()}
```

- `status`: required (e.g., `<<"loading">>`, `<<"initializing">>`)
- `detail`: optional, defaults to `<<"">>` if absent. Free-form progress text for logging. `decode_heartbeat/1` uses custom handling for this optional field (similar pattern to `decode_error_msg/1` handling optional `id`).
- Added to `loom_protocol:inbound_msg()` type and `decode_by_type/2`
- No outbound encoding needed (adapter -> Erlang only)

---

## Mock Adapter Updates

Changes to `priv/scripts/mock_adapter.py`:

1. **Send heartbeat on startup** — at least one `{"type": "heartbeat", "status": "loading", "detail": "initializing mock engine"}` before ready
2. **Send ready message** — `{"type": "ready", "model": "mock", "backend": "mock"}`
3. **Stdin watchdog thread** — background thread detects stdin EOF, calls `os._exit(1)`
4. **`--startup-delay` flag** — (default: 0) simulates slow model loading with periodic heartbeats every 5s during the delay
5. **Verify shutdown** — already implemented, confirm exit code 0

---

## Configuration

All defaults are configurable via JSON config (`config/loom.json`), overridable per engine. Below is the complete config shape showing multi-model setup with per-engine port overrides:

```json
{
  "engines": [
    {
      "name": "qwen2.5-1.5b",
      "backend": "vllm",
      "model": "Qwen/Qwen2.5-1.5B-Instruct",
      "gpu_ids": [0],
      "tp_size": 1
    },
    {
      "name": "llama-70b",
      "backend": "vllm",
      "model": "meta-llama/Llama-3-70B-Instruct",
      "gpu_ids": [1, 2, 3, 4],
      "tp_size": 4,
      "port": {
        "heartbeat_timeout_ms": 30000,
        "shutdown_timeout_ms": 20000
      }
    },
    {
      "name": "tinyllama-mlx",
      "backend": "mlx",
      "model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
      "gpu_ids": [],
      "tp_size": 1
    }
  ],
  "port": {
    "defaults": {
      "max_line_length": 1048576,
      "heartbeat_timeout_ms": 15000,
      "spawn_timeout_ms": 5000,
      "shutdown_timeout_ms": 10000,
      "post_close_timeout_ms": 5000,
      "heartbeat_interval_ms": 5000
    }
  },
  "server": {
    "port": 8080
  }
}
```

**Merge precedence:** per-engine `"port"` overrides > top-level `"port.defaults"` > hardcoded defaults in `loom_port`.

`loom_port` does not read config directly — it receives a merged `Opts` map at `start_link`. The coordinator (or whoever starts it) merges defaults + per-engine overrides from config and passes the final map. `heartbeat_interval_ms` is enforced adapter-side, documented here for adapter authors.

---

## Testing Strategy

| Test | Type | Verifies |
|------|------|----------|
| Happy path startup | EUnit | spawn -> heartbeat -> ready -> owner notified |
| Heartbeat timeout | EUnit | No heartbeat within 15s -> owner gets timeout |
| Spawn timeout | EUnit | Adapter never sends heartbeat -> timeout after 5s |
| Send in ready state | EUnit | `send/2` -> adapter receives command -> response forwarded |
| Send in non-ready state | EUnit | `send/2` returns `{error, not_ready}` |
| Adapter crash | Common Test | Kill OS process -> owner gets exit within ms |
| Graceful shutdown | Common Test | `shutdown/1` -> adapter exits code 0 |
| Shutdown escalation | Common Test | Adapter ignores shutdown -> port_close after timeout |
| Owner death | Common Test | Kill owner -> loom_port self-terminates, adapter dies |
| Concurrent sends | Common Test | Multiple generate requests -> all responses forwarded |
| Startup delay | Common Test | `--startup-delay 3` -> heartbeats during loading -> ready after 3s |
| Bad command path | EUnit | Nonexistent executable -> Port exits immediately -> owner notified |
| noeol accumulation | EUnit | Small max_line_length (64B) -> long response -> fragments reassembled correctly |
| Decode error in ready | EUnit | Adapter sends malformed JSON -> owner gets `loom_port_error`, port stays alive |
| Shutdown during loading | Common Test | `shutdown/1` while adapter is still loading -> clean escalation |

---

## Scope Boundary

**In scope (P0-05):**
- `loom_port` gen_statem module
- `heartbeat` addition to `loom_protocol`
- Mock adapter updates (ready, heartbeat, stdin watchdog, --startup-delay)
- EUnit + Common Test suites

**Out of scope:**
- JSON config parsing module (separate cross-cutting item CC-04)
- `loom_engine_coordinator` (P0-08)
- Real vLLM/TensorRT/MLX adapters (P0-06, P1-08, P1-12)
- gRPC migration (P4-01)
