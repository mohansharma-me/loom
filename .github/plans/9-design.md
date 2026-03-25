# Design: loom_engine_coordinator (P0-08)

**Issue:** [#9](https://github.com/mohansharma-me/loom/issues/9)
**Module:** `loom_engine_coordinator`
**Type:** `gen_statem`
**Depends on:** P0-04 (loom_protocol), P0-05 (loom_port), P0-07 (loom_gpu_monitor)

---

## Overview

`loom_engine_coordinator` is the core process managing a single inference engine's lifecycle, request routing, and in-flight tracking. It sits between the router (Phase 1) and `loom_port`, owning the engine subprocess lifecycle and correlating request/response messages.

---

## State Machine

```
starting --(port ready)--> ready --(drain requested)--> draining --(in-flight=0)--> stopped
   ^                         |                                                        |
   +---(port crash/restart)--+                                                        |
   ^                                                                                  |
   +-----------------------------(restart requested)----------------------------------+
```

### States

| State | Accepts generate? | Description |
|-------|-------------------|-------------|
| `starting` | No (`{error, not_ready}`) | Port is spawning/loading model. Waiting for `{loom_port_ready, ...}`. State timeout for startup failure. |
| `ready` | Yes | Accepting requests, routing tokens, tracking in-flight. Self-heals on port crash. |
| `draining` | No (`{error, draining}`) | Graceful shutdown initiated. Waiting for in-flight requests to complete. Drain timeout force-cancels stuck requests. |
| `stopped` | No (`{error, stopped}`) | Terminal state. Port is down. Can transition to `starting` on explicit restart request (Phase 2 model swap). |

### Transitions

| From | To | Trigger |
|------|-----|---------|
| `starting` | `ready` | `{loom_port_ready, Ref, Model, Backend}` received |
| `starting` | `stopped` | Startup timeout fires, or port exits before ready |
| `ready` | `starting` | Port crashes — self-heal: notify callers, clear state, spawn new port |
| `ready` | `draining` | `shutdown/1` called |
| `draining` | `stopped` | In-flight count reaches 0, or drain timeout fires |
| `draining` | `stopped` | Port crashes during drain (respects operator intent, no self-heal) |
| `stopped` | `starting` | Explicit restart request (Phase 2) |

---

## Self-Healing on Port Crash

When the port crashes during `ready` state, the coordinator does NOT die. Instead:

1. Receives `{loom_port_exit, PortRef, ExitCode}`
2. Iterates all in-flight requests in ETS
3. Normalizes exit reason: `ExitCode` may be an integer or the atom `killed` (from force-kill escalation). Coordinator converts to binary: `integer_to_binary(N)` or `<<"killed">>`.
4. Sends `{loom_error, RequestId, <<"engine_crashed">>, NormalizedReason}` to each caller
5. Demonitors all callers
6. Clears requests ETS table
7. Updates meta ETS table with `status => starting`
8. Spawns new `loom_port` with a new `PortRef`
9. Transitions to `starting`
10. Late messages from old port are ignored (old `PortRef` doesn't match)

The supervisor is the backstop — if the coordinator itself crashes, the supervisor restarts it.

**Exception:** Port crash during `draining` transitions to `stopped`, not `starting`. Drain is an intentional shutdown — self-healing would fight operator intent.

---

## ETS Tables

Two ETS tables per coordinator, both `protected` (coordinator writes, anyone reads).

### Requests Table

- **Name:** `loom_coord_reqs_<EngineId>` (atom, e.g., `loom_coord_reqs_engine_0`)
- **Type:** `set`, keyed by `RequestId`
- **Created in:** `init/1` (destroyed automatically on coordinator crash)

**Row format:**

```erlang
{RequestId :: binary(),
 CallerPid :: pid(),
 MonitorRef :: reference(),
 StartTime :: integer()}        %% erlang:monotonic_time(millisecond)
```

No prompt storage — prompts can be large (64K+ tokens of text) and are not needed after being sent to the port. Keeps copy-on-read cost minimal.

### Meta Table

- **Name:** `loom_coord_meta_<EngineId>` (atom, e.g., `loom_coord_meta_engine_0`)
- **Type:** `set`, single row
- **Updated on:** every state transition

**Row format:**

```erlang
{meta,
 Status :: starting | ready | draining | stopped,
 EngineId :: binary(),
 Model :: binary(),
 Backend :: binary(),
 PortPid :: pid() | undefined,
 StartedAt :: integer()}        %% erlang:monotonic_time(millisecond)
```

### ETS Read Discipline

All hot-path reads are direct ETS lookups — no message passing to the coordinator.

| Function | ETS Operation | Copy Cost |
|----------|---------------|-----------|
| `get_load(EngineId)` | `ets:info(ReqsTable, size)` | None (returns integer) |
| `get_status(EngineId)` | `ets:lookup(MetaTable, meta)` | One small tuple |
| `get_info(EngineId)` | `ets:lookup(MetaTable, meta)` + `ets:info(ReqsTable, size)` | One small tuple + integer |

**No `tab2list` anywhere.** Admin/debug introspection (`get_in_flight/1`) uses `ets:select` with a match spec returning only `{RequestId, StartTime}` — never copies caller pids or monitor refs to the caller's heap.

---

## Request Lifecycle

### 1. Request Accepted

Caller calls `generate(CoordinatorPid, Prompt, Params)` (synchronous `gen_statem:call`).

**Two-phase delivery model:** The `gen_statem:call` is used only for the acceptance/rejection reply. The coordinator extracts `CallerPid` from the `From = {Pid, Tag}` tuple provided by `gen_statem:call`. After replying `{ok, RequestId}` via `gen_statem:reply(From, ...)`, all subsequent messages (tokens, done, errors) are sent directly to `CallerPid` via `CallerPid ! {loom_token, ...}` — NOT through the call/reply mechanism. The caller must enter a `receive` loop after `generate/3` returns to consume the token stream.

In `ready` state:
1. Check `ets:info(ReqsTable, size) < MaxConcurrent`, else return `{error, overloaded}`
2. Generate unique `RequestId` using `erlang:unique_integer([positive, monotonic])`
3. Format as `<<"req-", Integer/binary>>`
4. Extract `CallerPid` from `From` (`{CallerPid, _Tag} = From`)
5. Monitor caller: `MonitorRef = erlang:monitor(process, CallerPid)`
6. Insert into ETS: `ets:insert(ReqsTable, {RequestId, CallerPid, MonitorRef, erlang:monotonic_time(millisecond)})`
7. Send to port: `loom_port:send(PortPid, {generate, RequestId, Prompt, Params})`
8. Reply `{ok, RequestId}` via `gen_statem:reply(From, {ok, RequestId})`
9. Log: `[INFO] Engine <id> accepted request <req_id> (in_flight=<N>/<max>)`

### 2. Token Delivery

Coordinator receives `{loom_port_msg, PortRef, {token, Id, TokenId, Text, Finished}}`:
1. Verify `PortRef` matches current port ref (ignore stale)
2. Look up `Id` in ETS — if not found, silently drop (cancelled request)
3. Forward `{loom_token, Id, Text, Finished}` to caller pid

### 3. Generation Complete

Coordinator receives `{loom_port_msg, PortRef, {done, Id, TokensGenerated, TimeMs}}`:
1. Look up `Id` in ETS
2. Forward `{loom_done, Id, #{tokens => TokensGenerated, time_ms => TimeMs}}` to caller
3. Demonitor caller (`erlang:demonitor(MonitorRef, [flush])`)
4. Delete ETS entry
5. Log: `[INFO] Engine <id> request <req_id> completed (tokens=<N>, time=<ms>ms)`
6. If in `draining` state and `ets:info(ReqsTable, size) =:= 0` → transition to `stopped`

### 4. Engine Error on Request

Coordinator receives `{loom_port_msg, PortRef, {error, Id, Code, Message}}`:
1. Look up `Id` in ETS (if `Id` is `undefined`, log warning and skip)
2. Forward `{loom_error, Id, Code, Message}` to caller
3. Demonitor, delete ETS entry
4. Log: `[INFO] Engine <id> request <req_id> failed: <Code> - <Message>`

### 5. Caller Dies Mid-Stream

Coordinator receives `{'DOWN', MonitorRef, process, CallerPid, _Reason}`:
1. Find ETS entry matching `MonitorRef` via `ets:match_object(ReqsTable, {'_', '_', MonitorRef, '_'})`
2. Send `loom_port:send(PortPid, {cancel, RequestId})` to stop generation (frees GPU)
3. Delete ETS entry
4. Log: `[INFO] Engine <id> caller <pid> died, cancelling request <req_id>`
5. Subsequent tokens/done for that `RequestId` silently dropped (no ETS match)

### 6. Port Crashes Mid-Stream

See [Self-Healing on Port Crash](#self-healing-on-port-crash) above.

---

## Messages Sent to Callers

```erlang
{loom_token, RequestId :: binary(), Text :: binary(), Finished :: boolean()}
{loom_done, RequestId :: binary(), Stats :: #{tokens => integer(), time_ms => integer()}}
{loom_error, RequestId :: binary(), Code :: binary(), Message :: binary()}
```

---

## Configuration

Map passed to `start_link/1`:

```erlang
#{
    engine_id          => binary(),          %% required, e.g., <<"engine_0">>
    command            => string(),          %% required, adapter executable path
    args               => [string()],        %% default: []
    model              => binary(),          %% required, e.g., <<"meta-llama/Llama-3-8B">>
    backend            => binary(),          %% required, e.g., <<"vllm">> | <<"mlx">>
    startup_timeout_ms => pos_integer(),     %% default: 120_000 (2 min)
    drain_timeout_ms   => pos_integer(),     %% default: 30_000
    max_concurrent     => pos_integer(),     %% default: 64
    port_opts          => map()              %% passed through to loom_port:start_link
}
```

### Config Validation

On `init/1`, validate:
- `engine_id`, `command`, `model`, `backend` are present and non-empty
- `startup_timeout_ms > 0`, `drain_timeout_ms > 0`, `max_concurrent > 0`
- Fail fast with `{stop, {invalid_config, Reason}}` on validation failure

---

## Public API

```erlang
%% Lifecycle
-spec start_link(Config :: map()) -> {ok, pid()} | {error, term()}.
-spec shutdown(pid()) -> ok.            %% initiates drain (async)
-spec stop(pid()) -> ok.                %% immediate stop, no drain (async)

%% Requests (only succeeds in ready state)
-spec generate(pid(), Prompt :: binary(), Params :: map()) ->
    {ok, RequestId :: binary()} | {error, not_ready | draining | overloaded | stopped}.

%% Read API (ETS-backed, no message passing)
-spec get_status(EngineId :: binary()) -> starting | ready | draining | stopped.
-spec get_load(EngineId :: binary()) -> non_neg_integer().
-spec get_info(EngineId :: binary()) ->
    #{engine_id => binary(), model => binary(), backend => binary(),
      status => atom(), load => integer(), started_at => integer()}.
```

---

## Logging

INFO-level logging at every key decision point. Uses `logger:info/2` with structured metadata.

### State Transitions

```
[INFO] Engine <id> entering starting state
[INFO] Engine <id> ready (model=<model>, backend=<backend>, startup_time=<ms>ms)
[INFO] Engine <id> drain started, <N> in-flight requests remaining
[INFO] Engine <id> drain complete, transitioning to stopped
[INFO] Engine <id> stopped
```

### Request Lifecycle

```
[INFO] Engine <id> accepted request <req_id> (in_flight=<N>/<max>)
[INFO] Engine <id> request <req_id> completed (tokens=<N>, time=<ms>ms)
[INFO] Engine <id> request <req_id> rejected: <reason>
```

### Failure & Recovery

```
[INFO] Engine <id> port crashed (exit_code=<code>), notifying <N> in-flight callers
[INFO] Engine <id> self-healing, spawning new port
[INFO] Engine <id> caller <pid> died, cancelling request <req_id>
[INFO] Engine <id> startup timeout after <ms>ms
[INFO] Engine <id> drain timeout, force-cancelling <N> requests
```

### GPU Alerts

```
[INFO] Engine <id> received GPU alert: <type> (<value> > threshold <threshold>)
```

All log messages include `#{engine_id => EngineId}` in metadata for structured log filtering.

---

## Error Handling & Edge Cases

| Scenario | Behavior |
|----------|----------|
| Startup timeout | Shutdown port, transition to `stopped`, log info |
| Port crash during `starting` | No callers to notify, transition to `stopped` |
| Port crash during `ready` | Notify all in-flight, clear ETS, self-heal to `starting` |
| Port crash during `draining` | Notify remaining callers, transition to `stopped` (no self-heal) |
| Token for unknown request ID | Silently drop (cancelled or already completed) |
| Stale messages from old port | Ignored via `PortRef` mismatch |
| Multiple callers die simultaneously | Each `'DOWN'` handled independently, each triggers cancel |
| `generate` when not `ready` | Return `{error, not_ready | draining | stopped}` |
| `generate` at max concurrent | Return `{error, overloaded}` |
| Drain timeout | Force-cancel remaining requests, notify callers, stop |
| Invalid config | Fail fast in `init/1` with `{stop, {invalid_config, Reason}}` |
| Port decode error | Receive `{loom_port_error, Ref, {decode_error, Reason}}`, log warning, continue |

---

## Testing Strategy

### EUnit Tests (`test/loom_engine_coordinator_tests.erl`)

- Request ID generation is unique and monotonic
- ETS read functions return correct values with mock data
- Config validation: missing required fields, invalid values, defaults applied

### Common Test Suite (`test/loom_engine_coordinator_SUITE.erl`)

Uses `priv/scripts/mock_adapter.py`.

| # | Test Case | Validates |
|---|-----------|-----------|
| 1 | Happy path: start → ready → generate → tokens → done | Basic lifecycle |
| 2 | Startup timeout: slow adapter, short timeout | Timeout handling |
| 3 | Not-ready rejection: generate before ready | State gating |
| 4 | Port crash with in-flight: kill adapter mid-stream | Self-healing, caller notification |
| 5 | Caller death: kill caller mid-stream | Active cancellation, ETS cleanup |
| 6 | Max concurrent: exceed limit | Overload rejection |
| 7 | Drain protocol: shutdown with in-flight | Graceful drain |
| 8 | Drain timeout: adapter never finishes | Force-cancel |
| 9 | Port crash during drain | Goes to stopped, not starting |
| 10 | Self-heal then succeed: crash → recover → new request works | End-to-end recovery |

---

## Integration Points

| Component | Interaction |
|-----------|-------------|
| `loom_port` | Coordinator starts and owns the port. Receives ready/token/done/error/exit messages. Sends generate/cancel/shutdown. |
| `loom_gpu_monitor` | Sends `{gpu_alert, GpuId, AlertType, Value, Threshold}` to coordinator. Coordinator logs alerts. (Phase 0: informational only. Phase 2: may trigger drain.) |
| `loom_engine_sup` (P0-09) | `rest_for_one` supervisor. Coordinator is first child. If coordinator crashes, monitors restart too. |
| `loom_router` (P1-03) | Calls `get_load/1`, `get_status/1` via ETS reads for routing decisions. |
| `loom_request` (P1-06) | Caller process that handles retry/reroute on `{loom_error, ..., <<"engine_crashed">>, ...}`. |
| `loom_metrics` (P1-09) | Scrapes ETS tables for in-flight counts, status, request latencies. |
