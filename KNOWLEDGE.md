# Loom — Project Knowledge Base

> This document captures the complete architectural context, design decisions, and rationale
> for the Loom project. It is intended as project knowledge for Claude so that any new
> conversation can continue from where previous discussions left off.

---

## 1. What is Loom

Loom is a fault-tolerant inference orchestration layer built on Erlang/OTP. It manages
multiple GPU-backed inference engines (vLLM, TensorRT-LLM) as supervised OTP processes.
Loom does NOT replace GPU math — it wraps inference engines and handles everything around
them: request routing, fault recovery, GPU monitoring, capacity management, backpressure,
streaming, and multi-node coordination.

**Tagline:** "Fault-tolerant inference orchestration, woven on BEAM."

**AI-First Project:** The entirety of Loom is built by AI coding agents. The human provides
architectural vision, domain expertise, and quality judgment. The agents write the code.

**Language:** Erlang (not Elixir — closer to OTP primitives, clearer supervision semantics,
avoids Phoenix ecosystem expectations).

**Repository:** github.com/mohansharma-me/loom
**License:** Apache 2.0

---

## 2. The Problem Loom Solves

### 2.1 LLM Inference Fundamentals

LLM inference has two phases:

- **Prefill:** All input tokens processed in parallel through all M layers in ONE forward pass.
  This is compute-bound (large matrix-matrix multiplications). GPUs are efficiently utilized.
  This phase also populates the KV cache for all input tokens at every layer.

- **Decode:** Output tokens generated ONE at a time. Each token requires a full forward pass
  through all M layers. This is memory-bandwidth-bound — each token generation reads the
  full model weights (~140GB for a 70B FP16 model) but does minimal arithmetic per byte.

The autoregressive loop is the core cost driver:

```
Input prompt → ONE parallel prefill pass → populate KV cache + first token
                                                    │
                                    ┌───────────────┘
                                    ↓
                             token₁ → full pass → token₂
                             token₂ → full pass → token₃
                             ...
                             (each reading all weights + growing KV cache)
```

Each layer has two operations:
- Self-Attention: reads KV cache (grows linearly with sequence length)
- Feed-Forward Network (FFN): large matrix multiply with static weights

KV cache size = M layers × T tokens × vector_size × 2 (K and V). For 70B model at 128K
context, this can be 40+ GB.

This is why API pricing charges more for output tokens than input tokens — input is amortized
across parallel processing, output is sequential with full weight reads per token.

### 2.2 Why Inference Orchestration Matters

The industry is moving from single monolithic models to multi-model systems:

- GPT-5 shipped with a router that directs requests to different specialized models
  (gpt-5-main for fast responses, gpt-5-thinking for complex reasoning)
- The router is continuously trained on real signals (user model switches, preference rates)
- Multiple frontier models use Mixture-of-Experts (MoE) with routing at the architecture level

This trajectory means orchestration IS becoming the product:

```
2023: Single model, single endpoint     → Simple serving (vLLM sufficient)
2024: Model + reasoning model            → Basic routing needed
2025: Router + multiple specialized models → Orchestration is first-class
2026+: Dozens of specialists, agentic     → Orchestration IS the product
       coordination, dynamic allocation
```

### 2.3 Current Pain Points

**Fault tolerance is an afterthought.** GPU fault crashes entire serving process. All in-flight
requests across all GPUs lost. KV cache gone. Kubernetes restarts after health check timeout
(10-30s), model reloads (30-60s). Total disruption: 30-90 seconds, all connections dropped.

**Multi-model coordination is bolted on.** Separate instances behind load balancer. No global
GPU utilization view. No dynamic rebalancing. No unified backpressure. Real-world example:
practitioners use Docker Compose `depends_on` chains with health checks for boot ordering,
LiteLLM for routing proxy, `MAX_REQUESTS_BEFORE_RESTART` for Python memory leak
mitigation — each tool solving one problem with no shared awareness.

**Updates require downtime.** Changing serving logic or swapping model = process restart =
evict all KV cache + drop all requests. Blue-green needs 2× GPU capacity.

**Multi-node is hard.** Control plane coordination (health checks, routing, membership, failover)
is hand-rolled and brittle. Ray provides some coordination but adds complexity and has a
single point of failure (head node).

---

## 3. Why BEAM / Erlang

### 3.1 The Core Insight

LLM inference serving is structurally identical to telephone switching — the problem BEAM
was designed for. Requests are calls. Models are exchanges. GPUs are trunk lines. The router
is the switchboard.

### 3.2 What BEAM Provides Natively

- **Process per request:** Each inference request is an independent process with own lifecycle.
  Can fail, retry, stream tokens independently.

- **Supervision trees:** GPU workers supervised by OTP supervisors. Crash → detect in
  milliseconds → restart only affected engine → other engines unaffected.

- **Hot code upgrades:** Update routing logic, backpressure thresholds, queue policies
  without restart. No model reload, no dropped connections.

- **Distributed coordination:** Built-in node discovery, cross-node message passing,
  `monitor_nodes` for failure detection. No external coordination service needed.

- **Backpressure:** Process mailboxes + GenStage/Broadway patterns give natural
  demand-driven flow from GPU capacity back to request intake.

- **Connection handling:** Process per connection natively handles thousands of long-lived
  SSE/WebSocket streams. Proven at millions of concurrent connections (WhatsApp precedent).

- **Runtime stability:** No GIL, no memory creep, processes independently garbage collected.
  Designed to run months/years without restart. No `MAX_REQUESTS_BEFORE_RESTART` needed.

### 3.3 What BEAM Does NOT Do

- **GPU math.** Matrix multiplications, attention kernels, KV cache page management — all
  delegated to vLLM / TensorRT-LLM. BEAM cannot compete here; this is SIMD work.

- **Tensor parallelism communication.** NCCL AllReduce between GPUs operates at microsecond
  granularity in GPU kernel space. BEAM message passing would add orders of magnitude latency.

- **Model compilation/optimization.** Quantization, FlashAttention, speculative decoding —
  all engine-internal concerns.

### 3.4 Why Not Process-Per-Weight (Rejected Approach)

Early in design we considered creating BEAM processes per weight node in a neural network
layer. This was rejected because:

- A single FFN layer multiply requires all inputs before computing. Communication pattern
  would be 8192 × 8192 = 67 million messages PER LAYER PER TOKEN.
- BEAM message copy overhead vastly exceeds the multiply-add it enables.
- Neural network computation is SIMD-shaped (same operation on massive data in lockstep).
  BEAM is designed for actor-shaped workloads (independent agents doing different things
  asynchronously). Process-per-weight maps a SIMD problem onto an actor framework.

The correct granularity is: **BEAM as orchestration layer around GPU inference engines.**

### 3.5 Honest Cons of Using BEAM

- **NIF/Port overhead:** ~0.1-0.5ms per GPU dispatch. Not zero.
- **Ecosystem gap:** Entire ML stack is Python/C++. Wrapping via NIFs/Ports is engineering effort.
- **Talent pool:** People who understand both BEAM/OTP and GPU inference is essentially zero.
- **GPU memory management across boundary:** KV cache lives in GPU memory. BEAM's GC knows
  nothing about it. Need custom accounting layer.
- **Iteration speed:** New GPU optimizations published → vLLM integrates in weeks (same
  language). Erlang NIF integration takes longer.
- **No existing proof point:** vLLM, TGI, TensorRT-LLM are battle-tested in production.

---

## 4. Architecture

### 4.1 High-Level Structure

```
                          Loom (Erlang/OTP)
┌──────────────────────────────────────────────────────┐
│                                                      │
│  Clients ──→ HTTP/SSE API ──→ Router ──→ Engine Pool │
│                                          │   │  │    │
│              Metrics    Planner    Registry  │  │    │
│                                              │  │    │
└──────────────────────────────────────────────┼──┼────┘
                                               │  │
                        ┌──────────────────────┘  └──────────────────┐
                        ▼                                            ▼
              ┌──────────────────┐                         ┌──────────────────┐
              │ vLLM (GPU 0,1)   │                         │ TensorRT (GPU 2) │
              │ Llama 70B TP=2   │                         │ Llama 8B         │
              └──────────────────┘                         └──────────────────┘
```

### 4.2 Supervision Tree

Two-level hierarchy separating routing unit (engine/TP group) from hardware monitoring
unit (individual GPU):

```
loom_app
└── loom_sup (top-level, one_for_one)
    ├── loom_engine_pool_sup (one_for_one)
    │   ├── loom_engine_sup:engine_0 (rest_for_one)
    │   │   ├── loom_engine_coordinator  ← owns Port/gRPC to vLLM
    │   │   ├── loom_gpu_monitor:gpu_0   ← monitors GPU 0 health
    │   │   └── loom_gpu_monitor:gpu_1   ← monitors GPU 1 health
    │   │
    │   └── loom_engine_sup:engine_1 (rest_for_one)
    │       ├── loom_engine_coordinator  ← owns Port/gRPC to TensorRT
    │       └── loom_gpu_monitor:gpu_2   ← monitors GPU 2 health
    │
    ├── loom_router          ← request routing decisions
    ├── loom_registry        ← model → engine mapping (ETS)
    ├── loom_kv_accountant   ← GPU memory budget tracking
    ├── loom_planner         ← topology recommendations
    └── loom_metrics         ← telemetry collection
```

**Why two levels:** A tensor-parallel group (e.g., 4 GPUs running one 70B model) lives or dies
together — you can't do a forward pass with 3 out of 4 shards. So the Engine Coordinator
represents the routing/failure unit (the TP group). But hardware fails at individual GPU level
(thermal throttling, ECC errors), so GPU Monitors track individual GPUs and can signal
proactive draining before a crash.

**Supervision strategy:** `rest_for_one` at engine supervisor level. If coordinator crashes
(because vLLM died), restart monitors too (they need to re-register). If a monitor crashes,
only that monitor restarts.

### 4.3 Key Components

**loom_engine_coordinator (GenServer)**
- Owns the Port (OS process lifecycle) to vLLM/TensorRT subprocess
- Accepts generation requests, forwards to engine, routes token responses back
- Tracks in-flight requests (map of request_id → caller pid)
- On Port death: notifies all in-flight callers with {error, engine_crashed}
- Supervisor restarts coordinator → coordinator restarts engine Port
- Implements drain protocol (stop accepting, wait for in-flight, shutdown)

**loom_gpu_monitor (GenServer)**
- Polls individual GPU health via nvidia-smi CLI (later NVML NIF)
- Reports: temperature, memory utilization, GPU utilization, ECC errors
- Configurable polling interval (default 5s)
- Emits warnings to coordinator on threshold breach

**loom_router (GenServer)**
- Pluggable strategy behaviour:
  ```erlang
  -callback route(Request, EngineRegistry, Metrics) ->
      {ok, EngineId} | {error, no_capacity}.
  ```
- Built-in strategies: model-match, capability-based (fast/deep), load-balanced,
  cascade (try fast first, fallback to large), priority
- Queries loom_kv_accountant for memory-aware routing
- Automatic fallback when target engine is down

**loom_registry (ETS)**
- Maps model_name → [engine_id, ...] (multiple engines can serve same model)
- Engine metadata: backend type, GPU assignment, TP size, current load, status
- Dynamic registration/deregistration as engines start/stop

**loom_kv_accountant (GenServer)**
- Tracks GPU memory budget per engine (reported via periodic health checks)
- Available = total_gpu_mem - model_weights - current_kv
- Router queries before routing long-context requests
- Prevents OOM from routing 128K-context request to memory-starved engine

**loom_planner (GenServer)**
- Observes per-model queue depth, latency trends, GPU utilization
- Recommends topology changes: reallocate GPUs between models
- Execution modes: advisory (human confirms), semi-auto (delay + override), auto
- Triggers drain → swap → reload cycle via admin API

**loom_metrics**
- Queue depth per engine (gauge)
- Requests routed per engine per second (counter)
- Routing decisions by strategy (counter)
- Token generation rate per engine (counter)
- Time-to-first-token and end-to-end latency (histograms)
- Exposed via Prometheus endpoint

### 4.4 Communication Boundary

Loom communicates with inference engines at two levels:

**Lifecycle (Port):** BEAM's `open_port` spawns and monitors the OS process. Instant crash
detection (milliseconds) when vLLM process dies. Used for start/stop/crash detect only.

**Data (stdio initially, gRPC later):** Request/response data flows over a structured protocol.

Phase 0-1 uses stdio Port with line-delimited JSON:
```
→ {"type": "generate", "id": "req-001", "prompt": "...", "params": {...}}
→ {"type": "health"}
→ {"type": "memory"}
← {"type": "token", "id": "req-001", "token_id": 1234, "text": "the", "finished": false}
← {"type": "done", "id": "req-001", "tokens_generated": 47, "time_ms": 1820}
← {"type": "health", "status": "ok", "gpu_util": 0.73, "mem_used_gb": 62.4}
```

Phase 4+ migrates to gRPC (multiplexed, Protobuf, production-grade) while retaining Port
for lifecycle monitoring.

**Python adapter:** Thin wrapper (`loom_adapter.py` for vLLM, `loom_adapter_trt.py` for
TensorRT-LLM) that reads from stdin, calls engine API, writes to stdout. Engines are
interchangeable from BEAM's perspective — same protocol, same behaviour interface.

### 4.5 Clean Boundary Principle

```
BEAM's domain                    GPU process domain
────────────────                 ────────────────────
Request lifecycle                Forward pass computation
Routing & scheduling             Tensor parallelism (NCCL)
Fault detection & recovery       KV cache memory management
Token streaming to clients       Batch assembly & execution
Cross-model coordination         GPU kernel scheduling
Multi-node membership            Pipeline parallelism
Health monitoring                Quantization / compilation
```

BEAM should NOT try to manage individual GPUs within a tensor-parallel group. NCCL
AllReduce runs at microsecond granularity in GPU kernel space. Let NCCL do GPU
synchronization; let BEAM do process lifecycle, routing, and fault management.

---

## 5. Tensor Parallelism and GPU Topology

### 5.1 When Models Don't Fit on One GPU

```
70B at FP16:  140GB weights → min 2 GPUs (H100 80GB each)
70B at INT4:   35GB weights → 1 GPU with 45GB for KV cache
405B at INT4: 203GB weights → min 3 GPUs

KV cache per token (Llama 70B): ~327KB
  4K context request:  ~1.3GB
  128K context request: ~42GB
```

### 5.2 Parallelism Types

**Tensor Parallelism (TP):** Split each layer's weight matrices across GPUs. Every layer
requires AllReduce (GPU-to-GPU via NCCL). Needs fast interconnect (NVLink 900 GB/s).
Must stay within single node.

**Pipeline Parallelism (PP):** Different layers on different GPUs. Less communication but
pipeline bubbles. Can span nodes (only one activation transfer between stages).

**In practice:** TP within node + PP across nodes for very large models:
```
Node 0: TP=8 GPUs → Layers 0-31    (NVLink AllReduce within node)
Node 1: TP=8 GPUs → Layers 32-63   (activation transfer between nodes)
...
```

### 5.3 How Loom Models This

From BEAM's perspective, a tensor-parallel group is ONE logical engine:

```
loom_engine_coordinator (one GenServer)
  Port → single vLLM process (rank 0, coordinator)
         ├── GPU 0 ←──NCCL──→ GPU 1
         ├── GPU 2 ←──NCCL──→ GPU 3
         └── manages all 4 GPUs internally
```

The internal GPU-to-GPU communication (NCCL) is invisible to BEAM. vLLM handles TP
coordination internally and presents a single API endpoint.

GPU Monitors still track individual GPUs within the group for health/thermal monitoring.

### 5.4 Topology Decision Framework

```
Step 1: Model weights (at precision) fit on 1 GPU?
  Yes → TP=1 (single GPU worker)
  No  → Step 2

Step 2: Fits on 1 node (8 GPUs)?
  Yes → TP=2,4,8 within node (NVLink)
  No  → TP within nodes + PP across nodes

Step 3: How many replicas?
  replicas = throughput_target / per_instance_throughput
  (also constrained by latency requirements — more replicas with smaller batches
   for lower p99 latency)

Step 4: Multi-model bin-packing
  Pack replicas onto available nodes respecting:
  - NVLink groups (TP must stay within node)
  - Memory budgets
  - Failover margin (spare capacity)
```

This topology drives the BEAM supervision tree. Each entry becomes an Engine Supervisor
with Coordinator + GPU Monitors.

---

## 6. vLLM vs TensorRT-LLM

Both are supported as backends behind the same Erlang behaviour interface:

```
vLLM                                TensorRT-LLM
──────────────────────────          ──────────────────────────
Python runtime                      C++ runtime (faster startup)
PyTorch backend                     TensorRT compiled graphs
Dynamic batching (flexible)         Static batching (optimized)
PagedAttention (memory flexible)    Pre-allocated memory pools
Many model architectures            Needs per-model compilation
Easier to debug/modify              Harder to modify, faster execution
Startup: 30-60 seconds              Startup: 60-120 seconds (compilation)
Latency: Good                       Latency: Best (20-40% faster)
```

Routing implication: experimental or variable-length requests → vLLM (more flexible).
Steady-state production traffic → TensorRT (lower latency). Same model, different backends,
unified routing through loom_router.

---

## 7. GPT-5 Router Validation

GPT-5 (launched August 2025) confirmed the multi-model routing pattern:

- Unified system with a fast model for general tasks and a deeper reasoning model for
  complex problems
- Real-time router decides based on conversation type, complexity, tool needs, user intent
- Router continuously trained on real signals (user model switches, preference rates)
- When usage limits reached, mini version handles remaining queries (graceful degradation)

This is exactly the orchestration pattern Loom is built for:
- Route request to correct model → process per request, pattern match on metadata
- Model-A overloaded, fallback to model-B → backpressure + rerouting
- Model crash during request → supervisor detects, retries on alternate
- Rolling update of one model while keeping other live → drain + restart
- Dynamic capacity rebalancing → supervisor tree reconfiguration at runtime

---

## 8. Comparison with Current Approaches

Loom's value increases with operational complexity:

```
Single GPU, single model      → BEAM adds overhead, little benefit
Multi-GPU, single model       → Fault isolation helps
Multi-GPU, multi-model        → Routing and reallocation are significant wins
Multi-node                    → Coordination and fault tolerance are major wins
Multi-node, multi-model,
  heterogeneous hardware,
  mixed priority traffic       → BEAM's value is highest; Python/Ray buckles
```

Current stacks are assembled from independent tools (Docker Compose for boot, LiteLLM for
routing, Kubernetes for restarts, Prometheus for monitoring) with no shared awareness.
Loom is a single coherent supervision tree where every component shares state.

Key advantages over current approaches:
- Fault detection: milliseconds (Port monitor) vs 10-30s (health check polling)
- Blast radius: single engine vs entire pod/container
- In-flight requests: per-request process notified, can retry vs dropped silently
- Memory creep: none (BEAM GC) vs periodic restart needed (Python)
- Hot updates: zero-downtime code load vs rolling restart
- Multi-node: native BEAM distribution vs external coordination (etcd, Ray GCS)

Key disadvantage: ecosystem maturity. Loom is new. vLLM/Kubernetes/Ray are battle-tested.

---

## 9. Roadmap

See **[ROADMAP.md](ROADMAP.md)** for detailed phase-wise progress with GitHub issue links and status tracking.

Phases at a glance: Phase 0 (Foundation & PoC) → Phase 1 (Multi-Engine & Routing) → Phase 2 (Dynamic Capacity) → Phase 3 (Multi-Node) → Phase 4 (Production Hardening) → Phase 5 (Ecosystem & Community).

---

## 10. Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language | Erlang (not Elixir) | Closer to OTP primitives, clearer supervision semantics |
| HTTP server | Cowboy | OTP-native, lightweight, excellent SSE/WebSocket support |
| Engine comm (Phase 0-1) | stdio Port | Simplest, sufficient for single-channel per engine |
| Engine comm (Phase 4+) | gRPC via gun/grpc_client | Multiplexed, typed, production-grade |
| Engine lifecycle | Port monitor | Instant OS-level crash detection |
| Serialization | JSON → Protobuf | JSON for simplicity early, Protobuf for production |
| GPU monitoring | nvidia-smi → NVML NIF | CLI is zero-dependency; NIF for performance later |
| Cluster discovery | Static → DNS-based | Simple start, cloud-native scaling |
| Metrics | Telemetry + Prometheus | Standard observability stack |

---

## 11. Key Design Principles

1. **BEAM for orchestration, GPU for math.** Never cross this boundary.
2. **Supervision tree = deployment topology.** The tree structure mirrors hardware reality.
3. **Engine-agnostic protocol.** vLLM and TensorRT are interchangeable behind same behaviour.
4. **Failure boundaries = process boundaries.** One engine crash ≠ system crash.
5. **Observable by default.** Every process inspectable, every metric exposed.
6. **Progressive complexity.** Phase 0 works on one GPU. Each phase adds capability without
   requiring previous phases to change.
7. **OpenAI-compatible API.** Zero client-side changes. Loom is transparent to callers.
8. **AI-first development.** All code authored by AI coding agents, guided by human architect.

---

## 12. Risk Register

| Risk | Mitigation |
|---|---|
| Port overhead too high | Measured <1ms in similar systems; gRPC migration in Phase 4 |
| vLLM API changes break adapter | Pin version, abstract via adapter layer, test matrix |
| BEAM distribution unsuitable for streaming volume | Batch tokens, benchmark in Phase 3 |
| No adoption (ecosystem unfamiliarity) | OpenAI-compatible API, Docker packaging |
| GPU driver / CUDA conflicts | Docker with pinned CUDA version |
| Model reload time after crash (30-60s) | Router auto-excludes crashed engine, serves via others |

---

## 13. Success Metrics

**Technical:**
- Recovery time after engine crash: <90s (model reload dominated)
- Port/gRPC overhead per token: <1ms
- Routing decision latency: <0.1ms
- Zero dropped connections during rolling update
- Linear throughput scaling with added engines

**Project:**
- Phase 0: "Kill vLLM, watch it recover" — compelling 2-minute screencast
- Phase 1: "Multi-model routing with automatic fallback" — conference talk material
- Phase 3: "Multi-node fault tolerance" — production-readiness proof point

---

## 14. Glossary

| Term | Meaning in Loom context |
|---|---|
| Engine | A single inference engine process (vLLM or TensorRT-LLM) managing one or more GPUs |
| TP group | Tensor-parallel group — multiple GPUs acting as one engine for a large model |
| Coordinator | The Erlang GenServer that owns the Port/gRPC connection to an engine |
| GPU Monitor | A lightweight Erlang process polling one physical GPU's health metrics |
| KV cache | Per-request, per-layer key-value state stored in GPU memory during generation |
| Port | Erlang mechanism for managing an external OS process (lifecycle + communication) |
| Drain | Gracefully stopping an engine: stop routing new requests → wait for in-flight → shutdown |
| Prefill | Processing input tokens in parallel (compute-bound, fast per token) |
| Decode | Generating output tokens one at a time (memory-bandwidth-bound, slow per token) |
| Planner | Component that observes metrics and recommends topology changes |
| Accountant | Component tracking GPU memory budgets for routing decisions |

---

## 15. Conversation Context for Future Sessions

Useful analogies when discussing Loom with future agents or humans:
- GPU workers ≈ database instances behind a connection pool
- KV cache ≈ per-session state (like a shopping cart in ATP)
- Memory bandwidth bottleneck ≈ disk I/O bottleneck in a DB
- Tensor parallelism ≈ sharding a hot partition
- Pipeline parallelism ≈ staged event processing pipeline
- KV cache paging ≈ buffer pool management / virtual memory
- Engine coordinator ≈ MongoDB replica set coordinator
- GPU monitor ≈ individual mongod health check
- Request routing ≈ ATP fulfillment channel selection
- Dynamic rebalancing ≈ multi-channel inventory reallocation
