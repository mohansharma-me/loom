# Architecture

Deep reference for Loom's internals. This document covers the supervision tree, component responsibilities, message flows, communication boundary, and technical decisions. For a quick start and API usage, see the [main README](../README.md).

---

## 1. Overview

```
                          Loom (Erlang/OTP)
+---------------------------------------------------------+
|                                                         |
|  Clients --> HTTP/SSE API --> Router --> Engine Pool     |
|                                          |   |  |       |
|              Metrics    Planner    Registry  |  |       |
|                                              |  |       |
+---------------------------------------------------------+
                                               |  |
                        +----------------------+  +------------------+
                        v                                            v
              +------------------+                         +------------------+
              | vLLM (GPU 0,1)   |                         | TensorRT (GPU 2) |
              | Llama 70B TP=2   |                         | Llama 8B         |
              +------------------+                         +------------------+
```

Loom is a fault-tolerant inference orchestration layer built on Erlang/OTP. It uses a two-level supervision design: the top level (`loom_sup`) manages engine supervisors as independent failure units, while each engine supervisor (`loom_engine_sup`) manages a coordinator and its GPU monitors as a cohesive group with `rest_for_one` semantics. The core principle is **BEAM for orchestration, GPU for math** -- Erlang handles request lifecycle, routing, fault detection, streaming, and distributed coordination, while GPU inference engines (vLLM, TensorRT-LLM, MLX) handle the actual matrix multiplications, KV cache management, and continuous batching. Loom never crosses this boundary.

---

## 2. Supervision Tree

### Current Phase 0 Tree

Verified against `src/loom_sup.erl`. In Phase 0, engine supervisors are direct children of `loom_sup`. There is no `loom_engine_pool_sup`, `loom_router`, `loom_registry`, `loom_kv_accountant`, `loom_planner`, or `loom_metrics` yet.

```
loom_app
+-- loom_sup (one_for_one)
    +-- loom_http_server
    +-- loom_engine_sup:engine_0 (rest_for_one)
    |   +-- loom_engine_coordinator
    |   +-- loom_gpu_monitor:gpu_0 (if gpu_ids configured)
    +-- loom_engine_sup:engine_1 (rest_for_one)
        +-- loom_engine_coordinator
        +-- loom_gpu_monitor:gpu_1
```

### Planned Full Tree (Phase 1+)

```
loom_app
+-- loom_sup (one_for_one)
    +-- loom_engine_pool_sup (one_for_one)
    |   +-- loom_engine_sup:engine_0 (rest_for_one)
    |   |   +-- loom_engine_coordinator
    |   |   +-- loom_gpu_monitor:gpu_0
    |   |   +-- loom_gpu_monitor:gpu_1
    |   +-- loom_engine_sup:engine_1 (rest_for_one)
    |       +-- loom_engine_coordinator
    |       +-- loom_gpu_monitor:gpu_2
    +-- loom_router
    +-- loom_registry
    +-- loom_kv_accountant
    +-- loom_planner
    +-- loom_metrics
```

### Why Two Levels

A tensor-parallel group (e.g., 4 GPUs running one 70B model) lives or dies together -- you cannot do a forward pass with 3 out of 4 shards. So the Engine Coordinator represents the **routing/failure unit** (the TP group). But hardware fails at individual GPU level (thermal throttling, ECC errors), so GPU Monitors track individual GPUs and can signal proactive draining before a crash. This gives two granularities: engine-level for routing decisions and fault recovery, GPU-level for hardware health monitoring.

### Why rest_for_one

`loom_engine_sup` uses `rest_for_one` strategy. Children are ordered: coordinator first, then GPU monitors.

- **Coordinator crash:** Restarts the coordinator and all monitors after it. Monitors need to re-register with the new coordinator (they discover its pid via ETS table ownership at start time), so restarting them is correct.
- **Monitor crash:** Restarts only that monitor and any monitors after it in the child list. The coordinator and earlier monitors are unaffected. A single GPU health check failure should not disrupt the engine.

### Why loom_http_server Is First Child

`loom_http_server` is the first child of `loom_sup` (before any engine supervisors). The HTTP server must be ready before engines start accepting requests. With `one_for_one` strategy at the top level, children start sequentially in spec-list order. This ensures the API endpoint is available when the first engine comes online.

---

## 3. Components

### loom_app

**Purpose:** OTP application callback. Entry point that bootstraps the system.

- Implements the `application` behaviour
- Ensures `loom_config` is loaded (from `config/loom.json`) before starting supervision
- Calls `loom_sup:start_link/0` to start the supervision tree
- Config loading checks for an existing ETS table to avoid double-loading (tests pre-load config)

**State:** None (delegates to `loom_sup`).

**Restart:** Application-level -- if `loom_app:start/2` fails, the OTP application framework handles it.

### loom_sup

**Purpose:** Top-level supervisor. Builds the child spec list from engine configuration.

- Implements the `supervisor` behaviour with `one_for_one` strategy (intensity 5, period 10s)
- First child: `loom_http_server` (permanent, 5s shutdown)
- Remaining children: one `loom_engine_sup` per engine defined in `loom_config`
- Reads engine names from `loom_config:engine_names/0`, fetches each engine config, flattens nested sub-maps into the flat format `loom_engine_sup:start_link/1` expects
- Determines the adapter executable: known Python backends (vllm, mlx, tensorrt, mock) are wrapped with `python3`; custom backends use the `adapter_cmd` directly

**State:** Supervisor state only (child specs and restart counters).

**Restart:** If any child crashes beyond the restart intensity (5 crashes in 10s), `loom_sup` itself terminates, bringing down the application.

### loom_engine_sup

**Purpose:** Per-engine `rest_for_one` supervisor managing a coordinator and its GPU monitors.

- Registered as `loom_engine_sup_<engine_id>` (atom derived from engine_id binary)
- Validates config on startup: engine_id format (`[a-zA-Z0-9._-]+`, max 64 bytes), adapter_cmd, optional fields (gpus list, max_restarts, max_period, drain_timeout_ms)
- Coordinator is always the first child; GPU monitors follow (one per GPU in the `gpu_ids` list)
- Configurable restart intensity via `max_restarts` (default 5) and `max_period` (default 60s)
- GPU monitors discover the coordinator pid via ETS table ownership lookup (not `supervisor:which_children/1`, which would deadlock during init)

**State:** Supervisor state. Engine config is consumed during init to build child specs.

**Restart:** Permanent. If this supervisor itself crashes, `loom_sup` restarts it (which re-creates the coordinator and all monitors).

### loom_engine_coordinator

**Purpose:** `gen_statem` managing a single inference engine's lifecycle, request forwarding, and in-flight request tracking.

- **States:** `starting` -> `ready` -> `draining` -> `stopped`
- Owns a `loom_port` subprocess (sole owner -- no other process sends messages to the port directly)
- Tracks in-flight requests via two ETS tables:
  - **Meta table** (`loom_coord_meta_<engine_id>`): engine status, load, model info. Enables lock-free reads by the future router and metrics systems.
  - **Requests table** (`loom_coord_reqs_<engine_id>`): maps request_id to caller pid and request metadata.
- `generate/3` and `generate/4` accept a prompt and params, return `{ok, RequestId}`. Tokens stream back as messages to the calling process.
- On port crash: notifies all in-flight callers with `{error, engine_crashed}`, then crashes intentionally to let the supervisor handle restart
- Configurable: `startup_timeout_ms` (120s), `drain_timeout_ms` (30s), `max_concurrent` (64)
- Emits telemetry events on state transitions and token generation

**State:** `#data{}` record containing engine_id, config, port_pid, port_ref, ETS table references, max_concurrent limit, and started_at timestamp.

**Restart:** Permanent. On restart, creates a new `loom_port`, which spawns a new adapter process. The adapter sends heartbeats during startup and a `ready` message when initialized. The coordinator transitions through `starting` -> `ready`.

### loom_gpu_monitor

**Purpose:** GenServer polling individual GPU health via pluggable backends.

- Backend auto-detection cascade: nvidia -> apple -> mock (if allowed)
- Reports: temperature, memory utilization, GPU utilization, ECC errors
- Configurable polling interval (default 5s) using `erlang:send_after/3` (non-overlapping polls)
- Checks thresholds on metric transitions, alerts coordinator on threshold breach
- Tracks consecutive poll errors
- Monitors coordinator via `erlang:monitor/2` -- if coordinator dies, the monitor knows

**State:** `#data{}` record containing gpu_id, backend module, backend state, poll interval, timer ref, latest metrics, threshold config, breach state, consecutive error count, coordinator pid and monitor ref.

**Restart:** Permanent. On restart, re-discovers the coordinator pid via ETS table ownership, starts polling again from scratch.

### loom_port

**Purpose:** `gen_statem` managing an external inference engine subprocess via Erlang Port.

- **States:** `spawning` -> `loading` -> `ready` -> `shutting_down`
- Opens an OS Port with `open_port/2` using `spawn_executable`
- Monitors the owner process (the coordinator) -- if the owner dies, the port shuts down
- Heartbeat-guarded startup: the adapter must send periodic heartbeat messages during model loading; if heartbeats stop, the port times out
- 3-level shutdown escalation for clean adapter termination
- Line buffer for protocol messages: accumulates partial lines from the port, splits on `\n`, decodes complete lines via `loom_protocol`
- Passes `CUDA_VISIBLE_DEVICES` environment variable based on configured `gpu_ids`

**State:** `#data{}` record containing port handle, OS pid, owner pid, owner monitor ref, line buffer, opts map, model, and backend.

**Restart:** Not directly supervised -- owned by the coordinator. When the coordinator restarts, it creates a new `loom_port`.

### loom_config

**Purpose:** Parses `config/loom.json` and provides engine configuration via ETS.

- Loads JSON config file, validates structure, stores in a named ETS table (`loom_config`)
- Validates: engine names (unique, valid format), backends (known or custom), adapter script existence, required fields (name, backend, model)
- Provides `get_engine/1`, `engine_names/0`, `get_server/0`, `get/2` for accessing config
- Resolves adapter paths: maps backend name to the corresponding Python adapter script in `priv/adapters/`
- Exports defaults for all subsystems: server, port, GPU monitor, coordinator, engine_sup

**State:** ETS table (`loom_config`) owned by the process that calls `load/0` (typically the application master helper, which lives for the application lifetime).

**Restart:** Not a process -- a library module backed by an ETS table.

### loom_protocol

**Purpose:** Encodes outbound messages and decodes inbound messages for the stdio JSON protocol.

- Encodes: `{generate, Id, Prompt, Params}`, `{health}`, `{memory}`, `{cancel, Id}`, `{shutdown}`, `{crash, ExitCode}` (test-only)
- Decodes: `{token, ...}`, `{done, ...}`, `{error, ...}`, `{health_response, ...}`, `{memory_response, ...}`, `{ready, ...}`, `{heartbeat, ...}`
- Line buffer management via `new_buffer/0` and `feed/2`: accumulates bytes, splits on newline, returns decoded messages and remaining buffer
- All messages are line-delimited JSON (terminated with `\n`)

**State:** Opaque `buffer()` type (a binary accumulator).

**Restart:** Not a process -- a pure library module.

### loom_http_server

**Purpose:** GenServer lifecycle wrapper that starts and stops Cowboy.

- Implements `gen_server` behaviour but does NOT sit in the HTTP request path
- On `init/1`: calls `loom_http:start()` to create the Cowboy listener with route dispatch
- On `terminate/2`: calls `loom_http:stop()` to remove the Cowboy listener from ranch_sup
- Exists so `loom_sup` can manage Cowboy's lifecycle as a supervised child

**State:** Empty map (no meaningful state -- Cowboy manages its own process tree under `ranch_sup`).

**Restart:** Permanent, 5s shutdown. If Cowboy fails to start, the gen_server stops, and `loom_sup` retries.

### loom_handler_chat

**Purpose:** Cowboy loop handler for `/v1/chat/completions` (OpenAI-compatible API).

- Implements `cowboy_loop` behaviour
- Supports both streaming (`"stream": true`) and non-streaming modes
- Reads and parses the request body, delegates to `loom_format_openai:parse_request/1`
- Looks up the engine coordinator, calls `generate/4` to start generation
- **Streaming:** Sends SSE headers immediately, then forwards each `{loom_token, ...}` message as an SSE `data:` chunk, ends with `data: [DONE]`
- **Non-streaming:** Accumulates all tokens, then sends a single JSON response

**State:** `#state{}` record containing request_id, engine_request_id, model, stream flag, accumulated tokens, created timestamp, headers_sent flag, and inactivity_timeout.

**Restart:** Per-request process managed by Cowboy -- not directly supervised by Loom.

### loom_handler_messages

**Purpose:** Cowboy loop handler for `/v1/messages` (Anthropic-compatible API).

- Implements `cowboy_loop` behaviour
- Supports both streaming and non-streaming modes
- Reads and parses the request body, delegates to `loom_format_anthropic:parse_request/1`
- **Streaming:** Follows the Anthropic SSE event sequence: `message_start` -> `content_block_start` -> `content_block_delta` (per token) -> `content_block_stop` -> `message_delta` -> `message_stop`
- **Non-streaming:** Accumulates all tokens, sends a single Anthropic-format JSON response

**State:** `#state{}` record containing request_id, engine_request_id, model, stream flag, accumulated tokens, token_count, headers_sent flag, block_started flag, and inactivity_timeout.

**Restart:** Per-request process managed by Cowboy.

### loom_format_openai

**Purpose:** Formats coordinator responses into OpenAI JSON structure.

- Parses incoming requests: extracts model, messages, stream flag, generation params (max_tokens, temperature, top_p, stop)
- Converts message array to a prompt string
- Formats responses: streaming chunks (`chat.completion.chunk`), final responses (`chat.completion`), error responses
- Produces OpenAI-standard fields: id (`chatcmpl-...`), object, created, model, choices, usage

**Restart:** Not a process -- a pure library module.

### loom_format_anthropic

**Purpose:** Formats coordinator responses into Anthropic JSON structure.

- Parses incoming requests: extracts model, max_tokens (required), messages, system prompt, stream flag, generation params
- Formats the full Anthropic SSE event sequence for streaming: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`
- Formats non-streaming responses with Anthropic structure: id (`msg_...`), type, role, content blocks, model, stop_reason, usage

**Restart:** Not a process -- a pure library module.

---

## 4. Message Flow

### Non-Streaming Request

```
Client POST /v1/chat/completions
  --> loom_handler_chat:init/2
    --> loom_format_openai:parse_request/1 (extract model, messages, params)
    --> loom_http_util:lookup_coordinator/1 (find coordinator pid)
    --> loom_engine_coordinator:generate/4 (gen_statem:call)
      --> loom_port:send/2 (encode via loom_protocol)
        --> Port --> Python adapter stdin (line-delimited JSON)
        <-- adapter stdout --> Port data messages
        <-- loom_protocol:feed/2 decodes lines
      <-- {loom_token, ...} messages sent to handler process
      <-- {loom_done, ...} signals completion
    --> tokens accumulated in handler #state.tokens
  <-- loom_format_openai:format_response/5
  <-- HTTP 200 JSON response (single body)
```

### Streaming (SSE) Request

```
Client POST /v1/chat/completions {stream: true}
  --> loom_handler_chat:init/2
    --> loom_format_openai:parse_request/1
    --> cowboy_req:stream_reply(200, SSE headers)
    --> loom_engine_coordinator:generate/4 (with caller pid)
      --> loom_port:send/2
        --> Port --> adapter stdin
        <-- token messages streamed back one at a time
      <-- {loom_token, ...} messages sent to handler pid
    --> loom_handler_chat:info/3 per token
      --> loom_format_openai:format_chunk/4
      --> cowboy_req:stream_body(SSE "data: ..." chunk)
    --> on {loom_done, ...}:
      --> loom_format_openai:format_final_chunk/3
      --> cowboy_req:stream_body("data: [DONE]\n\n")
  <-- SSE stream with data: lines, ends with [DONE]
```

### Crash Recovery

```
Python adapter crashes (SIGKILL, OOM, etc.)
  --> Port detects exit_status
  --> loom_port transitions to shutting_down, notifies owner
  --> loom_port sends {loom_port_exit, Reason} to coordinator
  --> coordinator notifies all in-flight callers: {error, engine_crashed}
  --> coordinator crashes (intentional -- lets supervisor handle it)
  --> loom_engine_sup (rest_for_one) restarts coordinator + all monitors
  --> new coordinator creates new loom_port in init/1
  --> new loom_port spawns new adapter subprocess
  --> adapter sends heartbeat messages during model loading
  --> adapter sends {ready, Model, Backend} when initialization complete
  --> coordinator transitions: starting --> ready
  --> engine accepting requests again
```

---

## 5. Communication Boundary

### BEAM Domain vs GPU Process Domain

```
BEAM's domain                    GPU process domain
----------------                 --------------------
Request lifecycle                Forward pass computation
Routing & scheduling             Tensor parallelism (NCCL)
Fault detection & recovery       KV cache memory management
Token streaming to clients       Batch assembly & execution
Cross-model coordination         GPU kernel scheduling
Multi-node membership            Pipeline parallelism
Health monitoring                Quantization / compilation
```

### Why stdio Port Now

The current Phase 0 implementation uses an Erlang Port with line-delimited JSON over stdio. This is the simplest possible communication channel:

- **Zero dependencies.** No gRPC libraries, no Protobuf compilation, no HTTP server in the adapter.
- **Sufficient for single-channel per engine.** Each engine has one coordinator, one port, one stdin/stdout pair. There is no multiplexing requirement in Phase 0.
- **Instant crash detection.** The Port mechanism gives OS-level process monitoring. When the adapter process dies, Erlang detects it in milliseconds via `exit_status` -- no health check polling needed.
- **Simple debugging.** JSON on stdio is human-readable. You can test adapters manually by piping JSON to stdin.

### Why gRPC Later (Phase 4+)

As Loom moves to production hardening, gRPC replaces stdio for the data channel while Port monitoring is retained for lifecycle:

- **Multiplexed.** Multiple concurrent requests over a single connection with HTTP/2 streams.
- **Typed.** Protobuf schemas enforce message contracts at compile time.
- **Production-grade.** Flow control, deadlines, cancellation, interceptors, TLS.
- **Port retained for lifecycle.** Even with gRPC, the Port mechanism continues to provide instant crash detection. gRPC handles data; Port handles life and death.

### The Clean Boundary Principle

BEAM should NOT try to manage individual GPUs within a tensor-parallel group. NCCL AllReduce runs at microsecond granularity in GPU kernel space. BEAM message passing would add orders of magnitude latency to GPU-to-GPU communication. Let NCCL do GPU synchronization; let BEAM do process lifecycle, routing, and fault management.

The Python adapter is intentionally thin -- a protocol bridge between Loom's stdio JSON protocol and the engine's native API (vLLM's `LLM` class, MLX's `mlx_lm.generate`, etc.). All complexity lives in either the BEAM supervision layer or the GPU engine internals. The adapter adds no logic of its own.

---

## 6. Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language | Erlang | Closer to OTP primitives, clearer supervision semantics |
| HTTP server | Cowboy | OTP-native, lightweight, excellent SSE/WebSocket support |
| Engine communication | stdio Port -> gRPC | Simplicity first, performance later |
| Engine lifecycle | Port monitor | Instant OS-level crash detection |
| Serialization | JSON -> Protobuf | JSON for early phases, Protobuf for production |
| GPU monitoring | nvidia-smi -> NVML NIF | CLI is zero-dependency; NIF for performance later |
| Cluster discovery | Static -> DNS-based | Simple start, cloud-native scaling |
| Metrics | Telemetry + Prometheus | Standard observability stack |
| Configuration | JSON file (loom.json) | User-facing config in JSON, not Erlang terms |
| API compatibility | OpenAI + Anthropic | Zero client-side changes, transparent to callers |

---

## 7. How Loom Compares

> Features marked **(expected)** are planned but not yet implemented. Phase 0 delivers fault tolerance and basic serving.

Current inference orchestration is typically assembled from independent tools -- Docker Compose for boot ordering, LiteLLM or Envoy for routing, Kubernetes for restarts, Prometheus for monitoring -- each solving one problem with no shared awareness. Loom replaces this fragmented stack with a single coherent supervision tree where every component (boot sequencing, routing, fault recovery, GPU monitoring, backpressure) shares state and reacts as one system.

### Boot & Startup Coordination

| Concern | Docker Compose + Health Checks | Kubernetes + vLLM | Ray Serve | Loom (expected) |
|---|---|---|---|---|
| Sequential model loading | `depends_on` + health check polling | Init containers, readiness probes | Manual startup ordering | Supervisor tree init -- deterministic, ordered, GPU-memory-aware |
| VRAM race conditions | Possible if health check passes before full VRAM claim | Possible across pods on same GPU | Not addressed | Engine coordinator confirms VRAM claimed before next engine starts |
| Boot failure recovery | Container restart (full reload) | Pod restart (full reload) | Actor restart (full reload) | Supervisor restarts failed engine only, others unaffected |

### Fault Tolerance & Recovery

| Concern | Docker Compose | Kubernetes + vLLM | Ray Serve | Loom (expected) |
|---|---|---|---|---|
| GPU fault detection | Docker health check polling (10-30s) | Liveness probe timeout (10-30s) | Actor health check | Port monitor -- instant (milliseconds) + GPU monitor (proactive) |
| Blast radius | Entire container (all requests on that engine) | Entire pod (all requests on that engine) | Actor tree (configurable) | Single engine supervisor -- other engines unaffected |
| In-flight request handling | Dropped silently | Dropped silently | Dropped or retried at application level | Per-request process notified, can retry on alternate engine |
| Recovery during model reload | No routing awareness -- requests fail until healthy | Readiness probe gates traffic, but no fallback | Manual fallback logic | Router auto-excludes engine, routes to available engines, re-includes on ready |
| Cascading failure prevention | None -- if one container OOMs, others may be affected | Resource limits help, but no cross-pod coordination | Limited | Supervisor isolation -- engine crash cannot propagate to other engines or router |

### Request Routing

| Concern | LiteLLM | Envoy / Nginx | Ray Serve | Loom (expected) |
|---|---|---|---|---|
| Routing strategy | Static config file (model -> endpoint mapping) | Header/path-based rules | Custom Python logic | Pluggable behaviour: model-match, capability-based, load-balanced, cascade, priority |
| GPU-aware routing | No | No | No | Yes -- KV accountant tracks memory, router avoids overloaded engines |
| Context-length-aware routing | No | No | No | Yes -- long-context requests routed to engines with memory headroom |
| Queue depth awareness | No (fire and forget to backend) | Limited (connection limits) | Basic (pending task count) | Per-engine bounded queues visible to router, global backpressure |
| Dynamic fallback | Retry on failure (reactive) | Retry on 5xx (reactive) | Custom (manual) | Proactive -- router reroutes before failure based on health signals |
| Hot routing rule updates | Config reload (restart proxy) | Config reload (graceful but limited) | Code redeploy | `sys:replace_state` or hot code load -- zero downtime, zero dropped requests |

### Capacity Management

| Concern | Docker Compose | Kubernetes | Ray Serve | Loom (expected) |
|---|---|---|---|---|
| Dynamic model swap | Stop container, change image, restart | Rolling deployment (new pod, drain old) | Redeploy actor | Admin API: drain -> swap model -> restart engine. No system restart, other engines unaffected |
| GPU reallocation between models | Manual: stop one container, start another | Manual: change deployment, apply | Manual: reconfigure actors | Planner observes load imbalance, recommends or auto-executes reallocation |
| Scaling response | HPA on CPU/memory (not GPU-aware) | HPA/KEDA (limited GPU awareness) | Autoscaler (task-queue-based) | Planner responds to queue depth, latency trends, GPU utilization -- application-aware |
| Cost of model update | All connections dropped on that container | Blue-green needs 2x GPU capacity, or rolling restart drops connections | Actor restart drops in-flight | Rolling per-engine: drain, swap, reload. System runs at reduced capacity, never fully offline |

### Runtime Stability

| Concern | Python-based stacks (LiteLLM, Ray, vLLM proxy) | Loom (expected) |
|---|---|---|
| Memory leaks | Common -- `MAX_REQUESTS_BEFORE_RESTART` is standard mitigation | BEAM processes are independently garbage collected. No memory creep, no periodic restarts |
| Long-running stability | Requires periodic worker restarts (hours to days) | Designed for continuous operation (months to years without restart) |
| Connection handling at scale | Async Python (uvicorn/gunicorn) -- practical ceiling, GIL-adjacent issues | Process per connection -- native to BEAM, proven at millions of concurrent connections |
| Hot code upgrades | Full process restart, all state lost | OTP code loading -- update logic without dropping connections or losing state |

### Multi-Node

| Concern | Kubernetes + Ingress | Ray Cluster | Loom (expected) |
|---|---|---|---|
| Node discovery | Kubernetes service discovery | Ray head node (single point of failure) | BEAM distribution -- `pg` process groups, no single coordinator |
| Cross-node routing | Ingress controller (L7, no application awareness) | Ray task scheduling | Native BEAM message passing with locality preference |
| Node failure detection | Kubelet heartbeat (10-40s default) | Raylet heartbeat | `net_kernel:monitor_nodes` -- seconds, with per-process `DOWN` signals |
| Split-brain handling | Kubernetes leader election | Ray GCS (eventually consistent) | Quorum-based, configurable partition strategy |
| Coordination overhead | etcd + API server + controller manager | Ray GCS + Redis | Zero external dependencies -- BEAM distribution is built into the runtime |

### Summary

```
                        Docker+LiteLLM  Kubernetes+vLLM  Ray Serve    Loom (expected)
                        --------------  ---------------  ---------    ---------------
Fault isolation         Container-level Pod-level        Actor-level  Engine-level with
                                                                      per-request granularity

Recovery time           30-90s          30-90s           10-30s       <5s (detection) +
                        (health check   (probe timeout   (actor       model reload time
                         + model reload) + model reload)  restart)    (only affected engine)

Routing intelligence    Static config   L7 rules         Custom code  Pluggable strategies
                                                                      with GPU/queue awareness

Dynamic rebalancing     Manual          Manual/HPA       Manual       Automated planner

Hot updates             Restart         Rolling restart   Redeploy    Zero-downtime code load

Runtime stability       Periodic        Periodic          Periodic    Continuous operation
                        restart needed  restart needed   restart      (no memory creep)

Multi-node              External LB     K8s services     Ray cluster  Native BEAM distribution
coordination            + manual        + etcd           + GCS        (no external dependencies)

Ecosystem maturity      High            High             High         Early (Loom is new)
GPU math optimization   N/A (delegates) N/A (delegates)  Integrated   N/A (delegates to
                                                                      vLLM / TensorRT)
```

> **Note:** Loom delegates all GPU-level computation to vLLM and TensorRT-LLM. It does not compete on matrix multiplication, KV cache management, or attention kernel optimization. Loom competes on everything *around* the GPU math: lifecycle management, routing, fault tolerance, and distributed coordination. The comparison above reflects orchestration-layer capabilities only.

---

## 8. Validation

### Benchmarks

Loom includes a benchmark suite that measures the overhead the orchestration layer adds to inference operations. All benchmarks use a mock adapter with zero artificial delays, isolating pure Erlang/Port communication cost.

#### Running Benchmarks

```bash
# Standard run (thresholds produce warnings only)
rebar3 ct --dir test/bench --suite loom_bench_SUITE

# Strict mode (threshold violations fail the suite)
BENCH_STRICT=true rebar3 ct --dir test/bench --suite loom_bench_SUITE
```

Results are written to `_build/bench/results.json` and printed as a console table.

#### Latest Results

Measured on Apple M3 Pro, OTP 28, 2026-03-29.

##### Protocol Encode/Decode

Pure Erlang JSON encoding and decoding -- no Port or process overhead.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| encode_decode_health | 1us | 5us | <100us | 100x |
| encode_decode_generate | 1us | 9us | <100us | 100x |
| encode_large_4k | 4us | 7us | -- | -- |
| encode_large_16k | 13us | 17us | -- | -- |
| encode_large_64k | 48us | 54us | -- | -- |

##### Port Roundtrips

Full Erlang -> Port -> Python -> Port -> Erlang cycle.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| health_roundtrip | 28us | 64us | <1ms | 35x |
| token_overhead | 3us | 16us | <500us | 166x |

##### Coordinator Operations

Full path through `loom_engine_coordinator` including ETS state management.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| coordinator_ets_read | 1us | 2us | <50us | 50x |
| coordinator_generate | 54us | 90us | <500us | 9x |

##### Concurrent Requests

Barrier-synced parallel workers measuring per-request latency under contention.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| concurrent_10 | 246us | 467us | <2ms | 8x |
| concurrent_50 | 1.2ms | 1.9ms | <5ms | 4x |
| concurrent_100 | 3.1ms | 4.3ms | <10ms | 3x |

##### Large Messages

Coordinator generate with large prompts -- measures serialization + Port overhead at scale.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| large_4k | 66us | 91us | <1ms | 15x |
| large_16k | 86us | 114us | <2ms | 23x |
| large_64k | 235us | 493us | <5ms | 21x |

All targets represent maximum acceptable orchestration overhead. The mock adapter isolates Loom's overhead from actual inference time -- in production, these costs are negligible relative to GPU computation (typically 10-100ms+ per token).

### Integration Tests (Real Hardware)

End-to-end tests that validate the full stack against a real MLX inference engine on Apple Silicon. These are **not** part of CI -- they require specific hardware and a downloaded model.

#### Setup

```bash
# 1. Install MLX dependencies (Apple Silicon Mac required)
pip3 install mlx-lm>=0.20.0 huggingface-hub psutil

# 2. Download test model (~400MB, cached for subsequent runs)
huggingface-cli download mlx-community/Qwen2.5-0.5B-Instruct-4bit

# 3. Run the suite
rebar3 ct --suite integration_test/loom_mlx_integration_SUITE
```

If prerequisites are missing, the suite **skips** (not fails) with setup instructions.

#### What's Tested

| Test | What It Validates |
|------|------------------|
| `health_endpoint_test` | GET /health returns 200 with engine status `ready` |
| `memory_metrics_test` | GPU monitor reports sensible memory values matching machine RAM |
| `chat_completion_openai_test` | POST /v1/chat/completions returns non-empty completion |
| `chat_completion_anthropic_test` | POST /v1/messages returns non-empty completion in Anthropic format |
| `sse_streaming_openai_test` | SSE streaming delivers token chunks ending with `[DONE]` |
| `sse_streaming_anthropic_test` | SSE streaming follows Anthropic event sequence |
| `gpu_metrics_sanity_test` | GPU metrics have valid types and sensible values |
| `crash_recovery_test` | SIGKILL adapter, auto-restart, successful post-recovery request |

#### Results

Measured on Apple M3 Pro (32GB), Qwen2.5-0.5B-Instruct-4bit, OTP 28, 2026-03-29. All tests use `max_tokens=128`.

| Test | Tokens | Latency | Throughput |
|------|--------|---------|------------|
| OpenAI non-streaming | 128 | 600ms | 213 tok/s |
| Anthropic non-streaming | 128 | 536ms | 239 tok/s |
| OpenAI streaming (SSE) | 128 | 544ms | 235 tok/s |
| Anthropic streaming (SSE) | 128 | 522ms | 245 tok/s |

| Lifecycle | Value |
|-----------|-------|
| Model load (cold) | ~1.6s |
| Crash recovery (SIGKILL -> ready) | ~1.5s |
| Memory usage (unified) | 19.0 / 32.0 GB |
| Full suite runtime | ~8s |
