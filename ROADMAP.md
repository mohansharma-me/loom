# Loom Roadmap

> Single source of truth for project progress across all phases.
> Each item links to its GitHub issue for detailed scope, acceptance criteria, and dependencies.

**Legend:** ` ` Pending · `~` In Progress · `x` Done

---

## Cross-Cutting Concerns

Standards and practices that apply across all phases.

- [ ] **Testing strategy and infrastructure** — [#49](https://github.com/mohansharma-me/loom/issues/49) `CC-01`
- [ ] **Structured logging and observability conventions** — [#50](https://github.com/mohansharma-me/loom/issues/50) `CC-02`
- [ ] **Type specs and Dialyzer compliance** — [#51](https://github.com/mohansharma-me/loom/issues/51) `CC-03`
- [ ] **JSON configuration parsing module (`loom_config`)** — [#65](https://github.com/mohansharma-me/loom/issues/65) `CC-04`

---

## Phase 0 — Foundation & Proof of Concept

> Validate the core thesis: BEAM can manage a vLLM process via Port with zero-downtime crash recovery.

### Project Bootstrapping
- [x] Initialize rebar3 project with OTP application layout — [#1](https://github.com/mohansharma-me/loom/issues/1) `P0-01`
- [x] Set up GitHub Actions CI (build, test, Dialyzer) — [#2](https://github.com/mohansharma-me/loom/issues/2) `P0-02`
- [x] Dev environment with Docker Compose and docs — [#3](https://github.com/mohansharma-me/loom/issues/3) `P0-03`

### Core Communication
- [x] Erlang-Python JSON wire protocol with encoder/decoder — [#4](https://github.com/mohansharma-me/loom/issues/4) `P0-04`
- [x] `loom_port` gen_statem for Port-based subprocess management — [#5](https://github.com/mohansharma-me/loom/issues/5) `P0-05`
- [x] `loom_adapter.py` wrapping vLLM AsyncLLMEngine — [#6](https://github.com/mohansharma-me/loom/issues/6) `P0-06`
- [x] `loom_adapter_mlx.py` for MLX (Apple Silicon) — [#63](https://github.com/mohansharma-me/loom/issues/63) `P1-12` *(pulled to P0 for local testability)*

### Supervision & Monitoring
- [x] `loom_gpu_monitor` GenServer for GPU health polling — [#8](https://github.com/mohansharma-me/loom/issues/8) `P0-07`
- [x] `loom_engine_coordinator` GenServer for engine lifecycle — [#9](https://github.com/mohansharma-me/loom/issues/9) `P0-08`
- [x] `loom_engine_sup` rest_for_one supervisor — [#10](https://github.com/mohansharma-me/loom/issues/10) `P0-09`
- [x] `/v1/chat/completions` endpoint with SSE streaming (Cowboy) — [#11](https://github.com/mohansharma-me/loom/issues/11) `P0-10`
- [ ] Wire all components into application supervisor tree — [#12](https://github.com/mohansharma-me/loom/issues/12) `P0-11`

### API Endpoints
- [x] `/v1/messages` endpoint — Anthropic Messages API compatibility — [#64](https://github.com/mohansharma-me/loom/issues/64) `P0-16`

### Validation
- [ ] Crash recovery test: kill engine → auto-restart → system recovers — [#13](https://github.com/mohansharma-me/loom/issues/13) `P0-12`
- [ ] Port overhead benchmark (target: <1ms per message) — [#14](https://github.com/mohansharma-me/loom/issues/14) `P0-13`
- [ ] Integration test suite for real vLLM on GPU hardware — [#15](https://github.com/mohansharma-me/loom/issues/15) `P0-14`
- [ ] Phase 0 architecture docs and demo script — [#16](https://github.com/mohansharma-me/loom/issues/16) `P0-15`

---

## Phase 1 — Multi-Engine & Routing

> Multiple inference engines with intelligent request routing — the GPT-5 router pattern.

### Pool & Registry
- [ ] `loom_engine_pool_sup` for N engine supervisors — [#17](https://github.com/mohansharma-me/loom/issues/17) `P1-01`
- [ ] `loom_registry` ETS-backed model→engine mapping — [#18](https://github.com/mohansharma-me/loom/issues/18) `P1-02`

### Routing Engine
- [ ] `loom_router` GenServer with pluggable strategy behaviour + model-match — [#19](https://github.com/mohansharma-me/loom/issues/19) `P1-03`
- [ ] Least-loaded, round-robin, and cascade strategies — [#20](https://github.com/mohansharma-me/loom/issues/20) `P1-04`
- [ ] Capability-based and priority strategies — [#21](https://github.com/mohansharma-me/loom/issues/21) `P1-05`
- [ ] Automatic request retry and fallback on engine failure — [#22](https://github.com/mohansharma-me/loom/issues/22) `P1-06`

### Flow Control
- [ ] Bounded request queues per engine + global backpressure — [#23](https://github.com/mohansharma-me/loom/issues/23) `P1-07`

### Additional Backends
- [ ] `loom_adapter_trt.py` for TensorRT-LLM — [#24](https://github.com/mohansharma-me/loom/issues/24) `P1-08`
- [~] `loom_adapter_mlx.py` for MLX (Apple Silicon) — [#63](https://github.com/mohansharma-me/loom/issues/63) `P1-12` *(moved to P0)*

### Observability & API
- [ ] `loom_metrics` with telemetry events and Prometheus endpoint — [#25](https://github.com/mohansharma-me/loom/issues/25) `P1-09`
- [ ] HTTP API updates: model selection, `/v1/models`, enhanced errors — [#26](https://github.com/mohansharma-me/loom/issues/26) `P1-10`

### End-to-End Validation
- [ ] Multi-engine demo: routing, fallback, backpressure — [#27](https://github.com/mohansharma-me/loom/issues/27) `P1-11`

---

## Phase 2 — Dynamic Capacity Management

> Runtime topology changes — load/unload models, reallocate GPUs, hot configuration updates.

- [ ] Admin HTTP API for engine lifecycle (start, drain, stop, swap, status) — [#28](https://github.com/mohansharma-me/loom/issues/28) `P2-01`
- [ ] Coordinated drain protocol for graceful engine shutdown — [#29](https://github.com/mohansharma-me/loom/issues/29) `P2-02`
- [ ] `loom_kv_accountant` for GPU memory budget tracking — [#30](https://github.com/mohansharma-me/loom/issues/30) `P2-03`
- [ ] `loom_planner` for load-based topology recommendations — [#31](https://github.com/mohansharma-me/loom/issues/31) `P2-04`
- [ ] Runtime configuration updates without restart — [#32](https://github.com/mohansharma-me/loom/issues/32) `P2-05`

---

## Phase 3 — Multi-Node Distribution

> Loom cluster spanning multiple physical nodes with coordinated routing and fault tolerance.

- [ ] Cluster formation with static config and DNS-based discovery — [#33](https://github.com/mohansharma-me/loom/issues/33) `P3-01`
- [ ] Cluster-wide engine registration via `pg` process groups — [#34](https://github.com/mohansharma-me/loom/issues/34) `P3-02`
- [ ] Cross-node request routing with local-first preference — [#35](https://github.com/mohansharma-me/loom/issues/35) `P3-03`
- [ ] Automatic rerouting on node failure + in-flight request handling — [#36](https://github.com/mohansharma-me/loom/issues/36) `P3-04`
- [ ] Quorum-based split-brain protection — [#37](https://github.com/mohansharma-me/loom/issues/37) `P3-05`

---

## Phase 4 — Production Hardening

> Make Loom production-ready for real workloads.

- [ ] gRPC migration for engine data path (Port retained for lifecycle) — [#38](https://github.com/mohansharma-me/loom/issues/38) `P4-01`
- [ ] Prefix-cache-aware routing for KV cache hits — [#39](https://github.com/mohansharma-me/loom/issues/39) `P4-02`
- [ ] Weighted traffic splitting for A/B and canary deployments — [#40](https://github.com/mohansharma-me/loom/issues/40) `P4-03`
- [ ] API key authentication and per-tenant rate limiting — [#41](https://github.com/mohansharma-me/loom/issues/41) `P4-04`
- [ ] Topology and routing config persistence (survive cluster restart) — [#42](https://github.com/mohansharma-me/loom/issues/42) `P4-05`
- [ ] Load test: 10K concurrent connections, p99 within 10% of direct vLLM — [#43](https://github.com/mohansharma-me/loom/issues/43) `P4-06`

---

## Phase 5 — Ecosystem & Community

> Open-source release, documentation, community building.

- [ ] Production Docker images (BEAM + Python adapters + GPU drivers) and native macOS/Apple Silicon packaging — [#44](https://github.com/mohansharma-me/loom/issues/44) `P5-01`
- [ ] Helm chart for Kubernetes deployment with GPU scheduling — [#45](https://github.com/mohansharma-me/loom/issues/45) `P5-02`
- [ ] Integrations: LiteLLM, LangChain, LlamaIndex — [#46](https://github.com/mohansharma-me/loom/issues/46) `P5-03`
- [ ] Prometheus alerting rules and Grafana dashboards — [#47](https://github.com/mohansharma-me/loom/issues/47) `P5-04`
- [ ] Comprehensive documentation, contribution guide, release prep — [#48](https://github.com/mohansharma-me/loom/issues/48) `P5-05`

---

## Progress Summary

| Phase | Total | Done | In Progress | Pending |
|-------|-------|------|-------------|---------|
| Cross-Cutting | 4 | 0 | 0 | 4 |
| Phase 0 | 17 | 12 | 0 | 5 |
| Phase 1 | 11 | 0 | 0 | 11 |
| Phase 2 | 5 | 0 | 0 | 5 |
| Phase 3 | 5 | 0 | 0 | 5 |
| Phase 4 | 6 | 0 | 0 | 6 |
| Phase 5 | 5 | 0 | 0 | 5 |
| **Total** | **53** | **12** | **0** | **41** |

## What's Next

Phase 0 bootstrapping is the immediate priority. The recommended start sequence:

1. ~~**#1 — P0-01:** Initialize rebar3 project (unblocks everything)~~ ✓
2. ~~**#2 — P0-02:** CI pipeline (enables quality gates early)~~ ✓
3. ~~**#3 — P0-03:** Dev environment (enables local iteration)~~ ✓
4. ~~**#4 — P0-04:** JSON wire protocol (defines the BEAM↔Python contract)~~ ✓
5. ~~**#5 — P0-05:** Port GenServer (loom_port gen_statem)~~ ✓
6. ~~**#6 — P0-06:** Python adapter wrapping vLLM AsyncLLMEngine~~ ✓
7. ~~**#8 — P0-07:** GPU health monitoring (loom_gpu_monitor)~~ ✓
8. ~~**#9 — P0-08:** Engine lifecycle management (loom_engine_coordinator)~~ ✓
9. ~~**#10 — P0-09:** Engine supervisor (loom_engine_sup rest_for_one)~~ ✓
10. ~~**#11 — P0-10:** HTTP API with SSE streaming (Cowboy)~~ ✓
11. **#12 — P0-11:** Wire all components into application supervisor tree
