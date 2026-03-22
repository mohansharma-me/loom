# Loom

**Fault-tolerant inference orchestration, woven on BEAM.**

Loom is an Erlang/OTP application that manages multiple GPU-backed inference engines (vLLM, TensorRT-LLM) as supervised processes. It brings the fault tolerance, hot code upgrades, and distributed coordination of the BEAM runtime to LLM inference serving — a domain currently dominated by fragile Python infrastructure.

> **Status:** Early development. Reserving the seat for BEAM-native inference orchestration before the industry needs it.

> **AI-First Project.** Loom is built entirely by AI coding agents. Every line of Erlang, every Python adapter, every test, every configuration file — authored by agents, guided by a human architect. This is not a disclaimer; it's the thesis. If we're building orchestration infrastructure for AI inference, the infrastructure itself should demonstrate what AI-assisted engineering looks like at its best. The human provides the architectural vision, domain expertise, and quality judgment. The agents write the code. Contributions follow the same model — agent-authored PRs are welcome and expected.

---

## The Problem

LLM inference is entering a new era. GPT-5 shipped with a router that directs requests to different specialized models. The industry is moving from single monolithic models to multi-model systems with intelligent routing, dynamic capacity allocation, and heterogeneous backends.

The serving infrastructure hasn't kept up. Today's inference servers — vLLM, TGI, TensorRT-LLM — are excellent at GPU-level optimization (FlashAttention, PagedAttention, continuous batching), but the orchestration layer around them is fragile:

**Fault tolerance is an afterthought.** A GPU fault or CUDA OOM crashes the entire serving process. All in-flight requests across all GPUs are lost. The KV cache for every active session is gone. Kubernetes restarts the pod after a health check timeout, model reloads into GPU memory, and the system is back — 30 to 90 seconds later. Every connection dropped.

**Multi-model coordination is bolted on.** Serving multiple models means running separate instances behind a load balancer with header-based routing. Cross-model GPU reallocation requires manual intervention. There's no global view of GPU utilization across models, no dynamic rebalancing, no unified backpressure.

**Updates require downtime.** Changing the serving logic, routing rules, or swapping a model version means restarting the process. Restart means evicting all KV cache from GPU memory and dropping every in-flight request. Blue-green deployments work but require double the GPU capacity during transition — expensive at $2-3/hour per H100.

**Multi-node distribution is hard.** Large models (400B+ parameters) require tensor parallelism across multiple nodes. The GPU-to-GPU math (NCCL) is well-solved, but control plane coordination — health checks, request routing, node membership, failover — is hand-rolled and brittle.

These problems are manageable at small scale. At the scale where multi-model routing, five-nines uptime, and dynamic GPU reallocation matter, the current tools start to buckle.

---

## The Insight

Every one of these problems — process isolation, supervised restart, hot code loading, distributed coordination, backpressure, streaming to thousands of concurrent connections — was solved decades ago by the BEAM virtual machine and OTP framework. Erlang was built for telephone switches: systems that must never go down, must handle millions of concurrent connections, and must be upgraded without dropping a single call.

LLM inference serving is a telephone switch for AI. Requests are calls. Models are exchanges. GPUs are trunk lines. The router is the switchboard.

---

## The Solution

Loom doesn't replace the GPU math. vLLM and TensorRT-LLM are excellent at matrix multiplications, KV cache management, and continuous batching. Loom wraps them as supervised OTP processes and handles everything around them:

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

**Process per request.** Each inference request is an Erlang process with its own lifecycle. It can fail, retry, or stream tokens independently without affecting any other request.

**Supervised engine workers.** Each inference engine (a vLLM or TensorRT-LLM process) is managed by an OTP supervisor. GPU crash? The supervisor detects it in milliseconds, restarts the engine, and only the requests on that specific engine are affected. Every other engine continues serving.

**Intelligent routing.** A pluggable router directs requests to the right engine based on model, capability, load, priority, or custom classification. Fallback is automatic — if an engine dies, requests cascade to the next available engine.

**Dynamic rebalancing.** Add, remove, or swap models on GPUs at runtime via an admin API. The supervision tree reconfigures without restarting the system. No dropped connections, no lost KV cache on unaffected engines.

**Multi-node distribution.** BEAM's built-in distribution handles node discovery, cross-node routing, and failure detection natively. A node going down triggers automatic rerouting. No external coordination service required.

**Hot upgrades.** Update routing logic, backpressure thresholds, or queue policies without restarting. No model reload, no lost connections.

---

## Architecture

Loom uses a two-level supervision hierarchy that separates the unit of routing (an engine, which may span multiple GPUs in a tensor-parallel group) from the unit of hardware monitoring (individual GPUs):

```
loom_app
└── loom_sup
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

**Engine Coordinator** manages the lifecycle of one inference engine process via an OS Port (for crash detection) and gRPC (for data). It accepts generation requests, forwards them to the engine, and streams tokens back to the per-request process.

**GPU Monitor** polls individual GPU health (temperature, memory, ECC errors) and notifies the coordinator of impending hardware failures, enabling proactive draining before a crash.

**Router** implements a pluggable strategy interface for request classification and engine selection. Built-in strategies include model-match, capability-based, load-balanced, cascade, and priority routing.

**Planner** observes system metrics and recommends (or auto-executes) topology changes: reallocating GPUs between models based on shifting traffic patterns.

Loom communicates with inference engines via a simple line-delimited JSON protocol over stdio (Phase 0-1) or gRPC with Protobuf (Phase 4+). A thin Python adapter wraps vLLM's or TensorRT-LLM's engine API, keeping the BEAM boundary clean:

```
Erlang Process  ←──  JSON/Protobuf  ──→  Python Adapter  ──→  vLLM/TensorRT
(supervision,                             (thin wrapper,       (GPU math,
 routing,                                  protocol bridge)     KV cache,
 streaming)                                                     batching)
```

---

## Why Now

The window for BEAM-native inference orchestration is opening:

- **GPT-5 validated the multi-model router pattern.** The future of inference is not one model behind one endpoint. It's multiple specialized models, dynamically routed, with intelligent fallback. This is an actor-model problem.
- **Inference cost pressure is rising.** As LLMs become commoditized, serving efficiency becomes the competitive differentiator. Better orchestration — smarter batching, dynamic rebalancing, less downtime — directly reduces cost per token.
- **Agentic workloads are emerging.** Long-running AI agents making multiple inference calls across different models need stateful process management. BEAM's process model maps to this naturally.
- **Uptime expectations are increasing.** As LLMs become infrastructure powering customer-facing products, 60-second restart windows stop being acceptable.

The GPU math layer is mature. The orchestration layer is the next frontier. Loom is positioned for that transition.

---

## Roadmap

See **[ROADMAP.md](ROADMAP.md)** for detailed phase-wise progress with GitHub issue links and status tracking.

---

## How Loom Compares

Current inference orchestration is typically assembled from independent tools — Docker Compose for boot ordering, LiteLLM or Envoy for routing, Kubernetes for restarts, Prometheus for monitoring — each solving one problem with no shared awareness. Loom replaces this fragmented stack with a single coherent supervision tree where every component (boot sequencing, routing, fault recovery, GPU monitoring, backpressure) shares state and reacts as one system.

### Boot & Startup Coordination

| Concern | Docker Compose + Health Checks | Kubernetes + vLLM | Ray Serve | Loom (expected) |
|---|---|---|---|---|
| Sequential model loading | `depends_on` + health check polling | Init containers, readiness probes | Manual startup ordering | Supervisor tree init — deterministic, ordered, GPU-memory-aware |
| VRAM race conditions | Possible if health check passes before full VRAM claim | Possible across pods on same GPU | Not addressed | Engine coordinator confirms VRAM claimed before next engine starts |
| Boot failure recovery | Container restart (full reload) | Pod restart (full reload) | Actor restart (full reload) | Supervisor restarts failed engine only, others unaffected |

### Fault Tolerance & Recovery

| Concern | Docker Compose | Kubernetes + vLLM | Ray Serve | Loom (expected) |
|---|---|---|---|---|
| GPU fault detection | Docker health check polling (10-30s) | Liveness probe timeout (10-30s) | Actor health check | Port monitor — instant (milliseconds) + GPU monitor (proactive) |
| Blast radius | Entire container (all requests on that engine) | Entire pod (all requests on that engine) | Actor tree (configurable) | Single engine supervisor — other engines unaffected |
| In-flight request handling | Dropped silently | Dropped silently | Dropped or retried at application level | Per-request process notified, can retry on alternate engine |
| Recovery during model reload | No routing awareness — requests fail until healthy | Readiness probe gates traffic, but no fallback | Manual fallback logic | Router auto-excludes engine, routes to available engines, re-includes on ready |
| Cascading failure prevention | None — if one container OOMs, others may be affected | Resource limits help, but no cross-pod coordination | Limited | Supervisor isolation — engine crash cannot propagate to other engines or router |

### Request Routing

| Concern | LiteLLM | Envoy / Nginx | Ray Serve | Loom (expected) |
|---|---|---|---|---|
| Routing strategy | Static config file (model → endpoint mapping) | Header/path-based rules | Custom Python logic | Pluggable behaviour: model-match, capability-based, load-balanced, cascade, priority |
| GPU-aware routing | No | No | No | Yes — KV accountant tracks memory, router avoids overloaded engines |
| Context-length-aware routing | No | No | No | Yes — long-context requests routed to engines with memory headroom |
| Queue depth awareness | No (fire and forget to backend) | Limited (connection limits) | Basic (pending task count) | Per-engine bounded queues visible to router, global backpressure |
| Dynamic fallback | Retry on failure (reactive) | Retry on 5xx (reactive) | Custom (manual) | Proactive — router reroutes before failure based on health signals |
| Hot routing rule updates | Config reload (restart proxy) | Config reload (graceful but limited) | Code redeploy | `sys:replace_state` or hot code load — zero downtime, zero dropped requests |

### Capacity Management

| Concern | Docker Compose | Kubernetes | Ray Serve | Loom (expected) |
|---|---|---|---|---|
| Dynamic model swap | Stop container, change image, restart | Rolling deployment (new pod, drain old) | Redeploy actor | Admin API: drain → swap model → restart engine. No system restart, other engines unaffected |
| GPU reallocation between models | Manual: stop one container, start another | Manual: change deployment, apply | Manual: reconfigure actors | Planner observes load imbalance, recommends or auto-executes reallocation |
| Scaling response | HPA on CPU/memory (not GPU-aware) | HPA/KEDA (limited GPU awareness) | Autoscaler (task-queue-based) | Planner responds to queue depth, latency trends, GPU utilization — application-aware |
| Cost of model update | All connections dropped on that container | Blue-green needs 2× GPU capacity, or rolling restart drops connections | Actor restart drops in-flight | Rolling per-engine: drain, swap, reload. System runs at reduced capacity, never fully offline |

### Runtime Stability

| Concern | Python-based stacks (LiteLLM, Ray, vLLM proxy) | Loom (expected) |
|---|---|---|
| Memory leaks | Common — `MAX_REQUESTS_BEFORE_RESTART` is standard mitigation | BEAM processes are independently garbage collected. No memory creep, no periodic restarts |
| Long-running stability | Requires periodic worker restarts (hours to days) | Designed for continuous operation (months to years without restart) |
| Connection handling at scale | Async Python (uvicorn/gunicorn) — practical ceiling, GIL-adjacent issues | Process per connection — native to BEAM, proven at millions of concurrent connections |
| Hot code upgrades | Full process restart, all state lost | OTP code loading — update logic without dropping connections or losing state |

### Multi-Node

| Concern | Kubernetes + Ingress | Ray Cluster | Loom (expected) |
|---|---|---|---|
| Node discovery | Kubernetes service discovery | Ray head node (single point of failure) | BEAM distribution — `pg` process groups, no single coordinator |
| Cross-node routing | Ingress controller (L7, no application awareness) | Ray task scheduling | Native BEAM message passing with locality preference |
| Node failure detection | Kubelet heartbeat (10-40s default) | Raylet heartbeat | `net_kernel:monitor_nodes` — seconds, with per-process `DOWN` signals |
| Split-brain handling | Kubernetes leader election | Ray GCS (eventually consistent) | Quorum-based, configurable partition strategy |
| Coordination overhead | etcd + API server + controller manager | Ray GCS + Redis | Zero external dependencies — BEAM distribution is built into the runtime |

### Summary

```
                        Docker+LiteLLM  Kubernetes+vLLM  Ray Serve    Loom (expected)
                        ──────────────  ───────────────  ─────────    ───────────────
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

## Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Language | Erlang | Closer to OTP primitives, clearer supervision semantics |
| HTTP server | Cowboy | OTP-native, lightweight, excellent SSE/WebSocket support |
| Engine communication | stdio Port → gRPC | Simplicity first, performance later |
| Engine lifecycle | Port monitor | Instant OS-level crash detection |
| Serialization | JSON → Protobuf | JSON for early phases, Protobuf for production |
| GPU monitoring | nvidia-smi → NVML NIF | CLI is zero-dependency; NIF for performance later |
| Cluster discovery | Static → DNS-based | Simple start, cloud-native scaling |
| Metrics | Telemetry + Prometheus | Standard observability stack |

---

## The Name

A loom beam is the roller in a weaving loom that holds the warp threads under tension. Loom holds inference engines under supervision, weaving multiple models, backends, and GPUs into a unified serving fabric — on BEAM.

---

## License

Apache 2.0
