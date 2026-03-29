# Design Plan: P0-15 Phase 0 Architecture Docs and Demo Script

**Parent issue:** [#16](https://github.com/mohansharma-me/loom/issues/16)
**Approach:** Hybrid — extract from existing README/KNOWLEDGE.md content, verify against source code, write protocol doc fresh from type specs.

---

## 1. README Restructure (Landing Page)

Trim the current ~540-line README to a focused landing page. Keep:

1. **Title, badges, tagline, AI-first blurb** (2 sentences)
2. **The Problem** (~15 lines, condensed from current ~20)
3. **The Insight** (~5 lines, unchanged)
4. **The Solution** (~20 lines — ASCII diagram + 6 bullet points, NO supervision tree, NO comparison tables)
5. **Quick Start** (unchanged — clone, mock, real backend, fault tolerance, endpoints, backends)
6. **Benchmarks** (unchanged — full tables stay as pitch proof)
7. **Documentation** (NEW — links to docs/architecture.md, docs/protocol.md, KNOWLEDGE.md, ROADMAP.md, CONTRIBUTING.md)
8. **The Name + License** (unchanged)

### What moves out of README:
- "Architecture" section (supervision tree detail) -> `docs/architecture.md`
- "How Loom Compares" tables -> `docs/architecture.md`
- "Technical Decisions" table -> `docs/architecture.md`
- "Integration Tests" section -> `docs/architecture.md` (under Validation)
- "Why Now" section -> cut entirely (covered by The Problem + The Insight)

---

## 2. `docs/architecture.md`

Developer-focused reference doc covering internals. Structure:

### Overview
- High-level ASCII diagram (existing)
- One paragraph: two-level supervision, BEAM for orchestration, GPU for math

### Supervision Tree
- Full tree diagram
- Why two levels (TP group = routing unit, GPU = monitoring unit)
- Why rest_for_one at engine supervisor level
- Current Phase 0 tree vs full planned tree (Phase 1+), clearly labeled

### Components
For each implemented component: purpose, key responsibilities, state managed, supervision/restart behavior.

Components: `loom_app`, `loom_sup`, `loom_engine_sup`, `loom_engine_coordinator`, `loom_gpu_monitor`, `loom_port`, `loom_config`, `loom_http_server`, `loom_handler_chat`, `loom_handler_messages`, `loom_format_openai`, `loom_format_anthropic`

### Message Flow
- Request lifecycle: HTTP -> handler -> coordinator -> port -> adapter -> tokens back
- Two diagrams: non-streaming and streaming (SSE)
- Error/crash flow: port death -> coordinator notifies callers -> supervisor restarts

### Communication Boundary
- BEAM domain vs GPU domain table (from KNOWLEDGE.md)
- Why stdio Port now, gRPC later
- Clean boundary principle

### Technical Decisions
- Table (moved from README)

### How Loom Compares
- All comparison tables (moved from README)
- Summary ASCII table

### Validation
- **Benchmarks** — benchmark tables (duplicated intentionally: README for pitch, architecture for reference)
- **Integration Tests** — setup, test list, results (moved from README)

---

## 3. `docs/protocol.md`

Complete wire protocol reference, written fresh from `loom_protocol.erl` type specs and adapter source.

### Overview
- Line-delimited JSON over stdio, one message per line, newline-terminated, UTF-8
- Direction convention: -> outbound (Erlang -> adapter), <- inbound (adapter -> Erlang)

### Startup Sequence
- Timeline: heartbeat(loading) -> periodic heartbeats -> ready -> command loop
- Timeout behavior from loom_port when ready never arrives

### Message Reference
**Outbound (Erlang -> Adapter):** generate, health, memory, cancel, shutdown, crash (test-only)
**Inbound (Adapter -> Erlang):** token, done, error, health_response, memory_response, ready, heartbeat

Each message: type name, JSON example, field table (name, type, required, description)

### Shutdown Protocol
- 3-level escalation from loom_port: shutdown message -> close stdin (EOF watchdog) -> OS kill
- Rationale (Python cleanup issues, daemon threads)

### Error Handling Contract
- Error codes and when returned
- Coordinator behavior for each error type
- Adapter crash vs protocol error distinction

### Writing a New Adapter
Step-by-step tutorial:
1. Script structure (read stdin, write stdout, stderr for logs)
2. Implement startup sequence (heartbeat -> ready)
3. Implement command handlers (generate, health, memory, cancel, shutdown)
4. Stdin watchdog pattern (why and how)
5. Token streaming (send tokens inline, then done)
6. Testing with loom_port directly
7. Registering in loom_config (backend name -> adapter path)

Reference implementation: `mock_adapter.py`

---

## 4. `docs/README.md` (Index)

One-liner back to root README, then a table:

| Document | Description |
|----------|-------------|
| Architecture | Supervision tree, components, message flow, comparisons |
| Wire Protocol | JSON protocol reference, message catalog, adapter guide |
| Knowledge Base | Deep architectural context, design rationale |
| Roadmap | Phase-wise progress tracking |
| Contributing | PR workflow, branch naming |

---

## 5. Demo Script (`priv/scripts/demo.sh`)

Interactive walkthrough with pauses between steps. User presses Enter to continue.

### Prerequisites Check
- Erlang installed
- rebar3 installed
- Project compiled (`_build/` exists)

### Steps
1. Start Loom with mock backend (rebar3 shell in background, wait for HTTP ready)
2. Health check (curl /health)
3. Chat completion — non-streaming (curl /v1/chat/completions)
4. Chat completion — streaming SSE (curl /v1/chat/completions with stream:true)
5. Kill the engine process (pkill mock adapter)
6. Show supervisor recovery (poll /health until ready, display recovery time)
7. Post-recovery request (curl again)
8. Cleanup (stop background rebar3 shell)

### UX
- Colored output: green (success), yellow (status/info), red (kill step)
- Each step: print description, wait for Enter, execute, show output
- Mock backend only — no GPU required

---

## Assumptions

- Benchmarks duplicated in README (pitch) and docs/architecture.md (reference) — intentional, different audiences.
- Integration test results move to docs/architecture.md only.
- "Why Now" section cut from README — motivation covered by The Problem + The Insight.
- KNOWLEDGE.md unchanged — it's Claude context, not developer docs.
- Demo script uses mock backend only, starts rebar3 shell in background.
- Protocol doc uses mock_adapter.py as reference implementation for the tutorial.
- Architecture doc shows both current P0 tree and planned full tree, clearly labeled.
