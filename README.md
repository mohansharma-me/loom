# Loom
[![CI](https://github.com/mohansharma-me/loom/actions/workflows/ci.yml/badge.svg)](https://github.com/mohansharma-me/loom/actions/workflows/ci.yml)

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

At the scale where multi-model routing, five-nines uptime, and dynamic GPU reallocation matter, the current tools start to buckle.

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

## Quick Start

### Prerequisites

**Erlang/OTP 27+**

```bash
# macOS
brew install erlang rebar3

# Ubuntu / Debian
sudo apt-get install erlang rebar3
```

**Python 3.9+** (included on macOS via Xcode Command Line Tools)

### 1. Clone and Compile

```bash
git clone https://github.com/mohansharma-me/loom.git
cd loom
rebar3 compile
```

### 2. Try It (Mock Backend — No GPU)

The default config uses a mock backend that works anywhere, no GPU or model download needed:

```bash
rebar3 shell
```

The supervision tree starts, the mock adapter loads, and the HTTP server is ready on port 8080. In another terminal:

```bash
# Health check
curl http://localhost:8080/health

# OpenAI-compatible chat completion
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "engine_0", "messages": [{"role": "user", "content": "Hello"}]}'

# Anthropic-compatible messages API
curl http://localhost:8080/v1/messages \
  -H "Content-Type: application/json" \
  -d '{"model": "engine_0", "max_tokens": 64, "messages": [{"role": "user", "content": "Hello"}]}'
```

### 3. Run with a Real Model

Choose your backend based on your hardware. Edit `config/loom.json`:

**MLX — Apple Silicon (macOS M1/M2/M3/M4)**

```bash
pip3 install mlx-lm>=0.20.0 huggingface-hub psutil
huggingface-cli download mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

```json
{
  "engines": [
    {
      "name": "qwen",
      "backend": "mlx",
      "model": "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
      "gpu_ids": [0]
    }
  ],
  "server": {
    "port": 8080
  }
}
```

**vLLM — Linux with NVIDIA/AMD/CPU**

```bash
pip install "vllm>=0.18.0"
huggingface-cli download Qwen/Qwen2.5-1.5B-Instruct
```

```json
{
  "engines": [
    {
      "name": "qwen",
      "backend": "vllm",
      "model": "Qwen/Qwen2.5-1.5B-Instruct",
      "gpu_ids": [0]
    }
  ],
  "server": {
    "port": 8080
  }
}
```

Then start Loom:

```bash
rebar3 shell
```

The model loads (1-2s on MLX, longer on vLLM depending on model size). Once you see `model loaded successfully` in the log output, the engine is ready:

```bash
# Streaming chat completion
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen",
    "messages": [{"role": "user", "content": "Explain the BEAM virtual machine in one paragraph."}],
    "stream": true
  }'
```

Tokens stream back as Server-Sent Events. Each inference request runs as its own Erlang process — independent lifecycle, independent failure.

### 4. Test Fault Tolerance

Kill the inference engine and watch the supervisor recover it:

```bash
# Kill the adapter process
kill -9 $(pgrep -f "loom_adapter")

# Loom detects the crash in milliseconds, restarts the engine,
# and reloads the model. Recovery takes ~1.5s on MLX.
# In-flight requests get {error, engine_crashed}.
# Send another request to verify recovery:
curl http://localhost:8080/health
```

Recovery is automatic. The supervisor detects the crash via Port monitoring, restarts the engine process, and the model reloads. No manual intervention, no system restart.

### 5. Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Engine status, load |
| `/v1/chat/completions` | POST | OpenAI-compatible chat (streaming and non-streaming) |
| `/v1/messages` | POST | Anthropic-compatible messages (streaming and non-streaming) |
| `/v1/models` | GET | List available models |

### 6. Supported Backends

| Backend | Platform | Install | Config `"backend"` |
|---------|----------|---------|-------------------|
| **MLX** | macOS Apple Silicon | `pip3 install mlx-lm>=0.20.0 psutil` | `"mlx"` |
| **vLLM** | Linux (NVIDIA/AMD/CPU) | `pip install "vllm>=0.18.0"` | `"vllm"` |
| **Mock** | Any (testing) | None | `"mock"` |

Loom communicates with all backends over the same stdio JSON protocol — the Erlang side is completely agnostic to which engine is running.

---

## Benchmarks

Loom includes a benchmark suite that measures the overhead the orchestration layer adds to inference operations. All benchmarks use a mock adapter with zero artificial delays, isolating pure Erlang/Port communication cost.

### Running Benchmarks

```bash
# Standard run (thresholds produce warnings only)
rebar3 ct --dir test/bench --suite loom_bench_SUITE

# Strict mode (threshold violations fail the suite)
BENCH_STRICT=true rebar3 ct --dir test/bench --suite loom_bench_SUITE
```

Results are written to `_build/bench/results.json` and printed as a console table.

### Latest Results

Measured on Apple M3 Pro, OTP 28, 2026-03-29.

#### Protocol Encode/Decode

Pure Erlang JSON encoding and decoding — no Port or process overhead.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| encode_decode_health | 1μs | 5μs | <100μs | 100x |
| encode_decode_generate | 1μs | 9μs | <100μs | 100x |
| encode_large_4k | 4μs | 7μs | — | — |
| encode_large_16k | 13μs | 17μs | — | — |
| encode_large_64k | 48μs | 54μs | — | — |

#### Port Roundtrips

Full Erlang → Port → Python → Port → Erlang cycle.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| health_roundtrip | 28μs | 64μs | <1ms | 35x |
| token_overhead | 3μs | 16μs | <500μs | 166x |

#### Coordinator Operations

Full path through `loom_engine_coordinator` including ETS state management.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| coordinator_ets_read | 1μs | 2μs | <50μs | 50x |
| coordinator_generate | 54μs | 90μs | <500μs | 9x |

#### Concurrent Requests

Barrier-synced parallel workers measuring per-request latency under contention.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| concurrent_10 | 246μs | 467μs | <2ms | 8x |
| concurrent_50 | 1.2ms | 1.9ms | <5ms | 4x |
| concurrent_100 | 3.1ms | 4.3ms | <10ms | 3x |

#### Large Messages

Coordinator generate with large prompts — measures serialization + Port overhead at scale.

| Benchmark | p50 | p99 | Target (p50) | Margin |
|-----------|-----|-----|--------------|--------|
| large_4k | 66μs | 91μs | <1ms | 15x |
| large_16k | 86μs | 114μs | <2ms | 23x |
| large_64k | 235μs | 493μs | <5ms | 21x |

All targets represent maximum acceptable orchestration overhead. The mock adapter isolates Loom's overhead from actual inference time — in production, these costs are negligible relative to GPU computation (typically 10-100ms+ per token).

---

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | Supervision tree, component responsibilities, message flow, technical decisions, comparisons |
| [Wire Protocol](docs/protocol.md) | JSON protocol reference, message catalog, writing a new adapter |
| [Knowledge Base](KNOWLEDGE.md) | Deep architectural context, design rationale, LLM inference fundamentals |
| [Roadmap](ROADMAP.md) | Phase-wise progress tracking with GitHub issue links |
| [Contributing](CONTRIBUTING.md) | PR workflow, branch naming, conventions |

---

## The Name

A loom beam is the roller in a weaving loom that holds the warp threads under tension. Loom holds inference engines under supervision, weaving multiple models, backends, and GPUs into a unified serving fabric — on BEAM.

---

## License

Apache 2.0
