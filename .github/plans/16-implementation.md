# Phase 0 Architecture Docs and Demo Script — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create developer-focused architecture and protocol documentation, trim README to a landing page, and build an interactive demo script that showcases Loom's fault-tolerance story.

**Architecture:** Five deliverables — `docs/README.md` (index), `docs/architecture.md` (deep reference), `docs/protocol.md` (wire protocol + adapter guide), trimmed `README.md` (landing page), and `priv/scripts/demo.sh` (interactive walkthrough). Content is extracted from existing README/KNOWLEDGE.md and verified against source code. Protocol doc is written fresh from `loom_protocol.erl` type specs and adapter source.

**Tech Stack:** Markdown, Bash (demo script), curl (demo HTTP calls)

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `docs/README.md` | Create | Documentation index with links to all docs |
| `docs/architecture.md` | Create | Supervision tree, components, message flow, comparisons, technical decisions, benchmarks, integration tests |
| `docs/protocol.md` | Create | Wire protocol reference, message catalog, shutdown protocol, error handling, "Writing a New Adapter" tutorial |
| `README.md` | Modify | Trim to landing page: pitch + quick start + benchmarks + doc links |
| `priv/scripts/demo.sh` | Create | Interactive fault-tolerance walkthrough using mock backend |

---

### Task 1: Create `docs/README.md` (Documentation Index)

**Files:**
- Create: `docs/README.md`

- [ ] **Step 1: Create the docs directory and index file**

```markdown
# Loom Documentation

For the project overview, quick start, and benchmarks, see the [main README](../README.md).

| Document | Description |
|----------|-------------|
| [Architecture](architecture.md) | Supervision tree, component responsibilities, message flow, technical decisions, comparisons with existing approaches |
| [Wire Protocol](protocol.md) | JSON protocol reference, message catalog, shutdown protocol, error handling, writing a new adapter |
| [Knowledge Base](../KNOWLEDGE.md) | Deep architectural context, design rationale, LLM inference fundamentals |
| [Roadmap](../ROADMAP.md) | Phase-wise progress tracking with GitHub issue links |
| [Contributing](../CONTRIBUTING.md) | PR workflow, branch naming, conventions |
```

- [ ] **Step 2: Verify all linked files exist**

Run:
```bash
for f in KNOWLEDGE.md ROADMAP.md CONTRIBUTING.md; do
  test -f "$f" && echo "OK: $f" || echo "MISSING: $f"
done
```

Expected: All files exist (architecture.md and protocol.md will be created in later tasks).

- [ ] **Step 3: Commit**

```bash
git add docs/README.md
git commit -m "docs: add docs/README.md index for #16"
```

---

### Task 2: Create `docs/architecture.md`

**Files:**
- Create: `docs/architecture.md`

**Source material to verify against:**
- `src/loom_sup.erl` — actual supervision tree structure
- `src/loom_engine_sup.erl` — rest_for_one semantics, child ordering
- `src/loom_engine_coordinator.erl` — states, ETS tables, request tracking
- `src/loom_gpu_monitor.erl` — polling, backends, thresholds
- `src/loom_port.erl` — state machine, Port lifecycle
- `src/loom_config.erl` — JSON config parsing
- `src/loom_http_server.erl` — Cowboy setup
- `src/loom_handler_chat.erl` — OpenAI handler
- `src/loom_handler_messages.erl` — Anthropic handler
- `src/loom_format_openai.erl` — OpenAI response formatting
- `src/loom_format_anthropic.erl` — Anthropic response formatting
- Current `README.md` — comparison tables, benchmarks, integration tests to extract

- [ ] **Step 1: Write the Overview and Supervision Tree sections**

The Overview section should include:
- The high-level ASCII diagram showing Clients → HTTP/SSE API → Router → Engine Pool → GPU engines
- One paragraph explaining the two-level supervision design and the BEAM-for-orchestration/GPU-for-math principle

The Supervision Tree section should include:
- **Current Phase 0 tree** (verified against `loom_sup.erl`): `loom_sup` (one_for_one) with `loom_http_server` and N `loom_engine_sup` children directly. No `loom_engine_pool_sup`, `loom_router`, `loom_registry`, `loom_kv_accountant`, `loom_planner`, or `loom_metrics` yet.
- **Planned full tree** (Phase 1+): the KNOWLEDGE.md tree with `loom_engine_pool_sup` and all future components, labeled as planned.
- Explanation of why two levels: TP group = routing/failure unit, individual GPU = monitoring unit
- Why `rest_for_one` at engine supervisor level (from `loom_engine_sup.erl` module doc)

- [ ] **Step 2: Write the Components section**

For each implemented Phase 0 component, document:
- Purpose (1-2 sentences)
- Key responsibilities (bullet list)
- State it manages (records, ETS tables)
- Supervision/restart behavior

Components to document (verify each exists in `src/`):

1. **`loom_app`** — OTP application callback, starts `loom_sup`
2. **`loom_sup`** — Top-level supervisor (one_for_one), builds engine children from `loom_config`
3. **`loom_engine_sup`** — Per-engine rest_for_one supervisor, manages coordinator + GPU monitors
4. **`loom_engine_coordinator`** — gen_statem (starting→ready→draining→stopped), owns loom_port, tracks in-flight requests via ETS, handles crash recovery
5. **`loom_gpu_monitor`** — GenServer polling GPU health via pluggable backends (nvidia, apple, mock)
6. **`loom_port`** — gen_statem (spawning→loading→ready→shutting_down), manages OS Port to adapter subprocess
7. **`loom_config`** — Parses `config/loom.json`, provides engine configs
8. **`loom_http_server`** — Starts Cowboy with route dispatch
9. **`loom_handler_chat`** — Cowboy handler for `/v1/chat/completions` (OpenAI-compatible)
10. **`loom_handler_messages`** — Cowboy handler for `/v1/messages` (Anthropic-compatible)
11. **`loom_format_openai`** — Formats coordinator responses into OpenAI JSON
12. **`loom_format_anthropic`** — Formats coordinator responses into Anthropic JSON
13. **`loom_protocol`** — Encodes/decodes wire protocol messages, line buffer management

- [ ] **Step 3: Write the Message Flow section**

Document the full request lifecycle with ASCII diagrams:

**Non-streaming request flow:**
```
Client POST /v1/chat/completions
  → loom_handler_chat:init/2
    → loom_engine_coordinator:generate/3
      → loom_port:send/2 (encode via loom_protocol)
        → Port → Python adapter stdin
        ← adapter stdout → Port
      ← tokens accumulated in coordinator
    ← {ok, Tokens} to handler
  ← HTTP 200 JSON response
```

**Streaming (SSE) request flow:**
```
Client POST /v1/chat/completions (stream: true)
  → loom_handler_chat:init/2
    → cowboy_req:stream_reply(200, headers)
    → loom_engine_coordinator:generate/4 (with caller pid)
      → loom_port:send/2
        → Port → adapter
        ← token messages streamed back
      ← {loom_token, ...} messages to caller pid
    → loom_handler_chat:info/3 per token
      → cowboy_req:stream_body(SSE chunk)
  ← SSE stream with data: lines, ends with [DONE]
```

**Crash recovery flow:**
```
Python adapter crashes (SIGKILL, OOM, etc.)
  → Port detects exit_status
  → loom_port notifies owner (coordinator) via {loom_port_exit, ...}
  → coordinator notifies all in-flight callers: {error, engine_crashed}
  → coordinator crashes (intentional — lets supervisor handle it)
  → loom_engine_sup (rest_for_one) restarts coordinator
  → new coordinator starts new loom_port
  → new Port spawns new adapter process
  → adapter sends heartbeat → ready
  → coordinator transitions to ready state
  → engine accepting requests again
```

- [ ] **Step 4: Write the Communication Boundary section**

Include:
- The BEAM domain vs GPU domain table (from KNOWLEDGE.md section 4.5)
- Why stdio Port now (simplest, sufficient for single-channel per engine)
- Why gRPC later (Phase 4: multiplexed, typed, production-grade)
- The clean boundary principle: BEAM for orchestration, GPU for math. Never cross.

- [ ] **Step 5: Write the Technical Decisions section**

Move the Technical Decisions table from README. Verify each decision still holds:

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
| Configuration | JSON file (loom.json) | User-facing config in JSON, not Erlang terms |
| API compatibility | OpenAI + Anthropic | Zero client-side changes, transparent to callers |

- [ ] **Step 6: Write the How Loom Compares section**

Move all comparison tables from the current README:
- Boot & Startup Coordination
- Fault Tolerance & Recovery
- Request Routing
- Capacity Management
- Runtime Stability
- Multi-Node
- Summary ASCII table

Add a note at the top: "Features marked **(expected)** are planned but not yet implemented. Phase 0 delivers fault tolerance and basic serving."

- [ ] **Step 7: Write the Validation section (Benchmarks + Integration Tests)**

**Benchmarks** subsection: Copy the benchmark tables from README. These are intentionally duplicated — README has them for the pitch, architecture doc has them for developer reference.

**Integration Tests** subsection: Move from README:
- Setup instructions (MLX dependencies, model download, run command)
- Test list table
- Results table (latency, throughput, lifecycle metrics)

- [ ] **Step 8: Verify the document**

Run a quick check:
```bash
# Verify all referenced source files exist
for f in src/loom_app.erl src/loom_sup.erl src/loom_engine_sup.erl \
         src/loom_engine_coordinator.erl src/loom_gpu_monitor.erl \
         src/loom_port.erl src/loom_config.erl src/loom_http_server.erl \
         src/loom_handler_chat.erl src/loom_handler_messages.erl \
         src/loom_format_openai.erl src/loom_format_anthropic.erl \
         src/loom_protocol.erl; do
  test -f "$f" && echo "OK: $f" || echo "MISSING: $f"
done
```

Review the doc for internal consistency: do the state names match the source? Do the flow diagrams match the actual call chain?

- [ ] **Step 9: Commit**

```bash
git add docs/architecture.md
git commit -m "docs: add architecture reference for #16

Covers supervision tree, component responsibilities, message flow,
communication boundary, technical decisions, comparisons, benchmarks,
and integration test results."
```

---

### Task 3: Create `docs/protocol.md`

**Files:**
- Create: `docs/protocol.md`

**Source material (write fresh from these):**
- `src/loom_protocol.erl` — type specs for all outbound/inbound messages, encode/decode functions
- `priv/python/loom_adapter_base.py` — base class showing protocol from Python side
- `priv/scripts/mock_adapter.py` — simplest adapter implementation
- `src/loom_port.erl` — state machine, shutdown escalation, timeout defaults

- [ ] **Step 1: Write Overview and Startup Sequence sections**

**Overview:**
- Line-delimited JSON over stdio
- One JSON object per line, terminated with `\n`
- UTF-8 encoding
- Direction: `→` = outbound (Erlang → adapter stdin), `←` = inbound (adapter stdout → Erlang)
- Stderr is for adapter logging only — never parsed by Erlang

**Startup Sequence:**
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

Document timeout behavior from `loom_port.erl`:
- `spawn_timeout_ms` (default 5000): time to receive first heartbeat after spawn
- `heartbeat_timeout_ms` (default 15000): max gap between heartbeats during loading
- If ready never arrives: port times out, stops with `{shutdown, heartbeat_timeout}`, supervisor restarts

- [ ] **Step 2: Write the Outbound Message Reference**

For each outbound message type, document: description, JSON example, field table.

Source: `loom_protocol:outbound_msg()` type spec and `encode/1` clauses.

**generate:**
```json
→ {"type": "generate", "id": "req-abc123", "prompt": "Hello, how are you?", "params": {"max_tokens": 128, "temperature": 0.7}}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"generate"` |
| id | string | yes | Unique request identifier |
| prompt | string | yes | The text prompt to complete |
| params | object | yes | Generation parameters |
| params.max_tokens | integer | no | Maximum tokens to generate |
| params.temperature | float | no | Sampling temperature |
| params.top_p | float | no | Nucleus sampling threshold |
| params.stop | string[] | no | Stop sequences |

**health:**
```json
→ {"type": "health"}
```
No additional fields. Requests current GPU health metrics.

**memory:**
```json
→ {"type": "memory"}
```
No additional fields. Requests GPU memory breakdown.

**cancel:**
```json
→ {"type": "cancel", "id": "req-abc123"}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"cancel"` |
| id | string | yes | Request ID to cancel |

Fire-and-forget — no response expected.

**shutdown:**
```json
→ {"type": "shutdown"}
```
No additional fields. Requests graceful adapter shutdown. See Shutdown Protocol section.

**crash (test-only):**
```json
→ {"type": "crash", "exit_code": 1}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"crash"` |
| exit_code | integer | yes | Exit code 0-255 |

Test-only. Triggers immediate `os._exit(exit_code)` in the adapter. Used by crash recovery tests. Production code must never send this.

- [ ] **Step 3: Write the Inbound Message Reference**

Source: `loom_protocol:inbound_msg()` type spec and `decode_by_type/2` clauses.

**token:**
```json
← {"type": "token", "id": "req-abc123", "token_id": 1, "text": "Hello", "finished": false}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"token"` |
| id | string | yes | Request ID this token belongs to |
| token_id | integer | yes | Sequential token index (0-based) |
| text | string | yes | The generated token text |
| finished | boolean | yes | Always `false` for token messages |

**done:**
```json
← {"type": "done", "id": "req-abc123", "tokens_generated": 47, "time_ms": 1820}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"done"` |
| id | string | yes | Request ID |
| tokens_generated | integer | yes | Total tokens generated |
| time_ms | integer | yes | Generation time in milliseconds |

**error:**
```json
← {"type": "error", "id": "req-abc123", "code": "model_error", "message": "CUDA OOM"}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"error"` |
| id | string/null | no | Request ID (null for non-request errors) |
| code | string | yes | Error code (e.g., `missing_field`, `invalid_json`, `model_error`) |
| message | string | yes | Human-readable error description |

**health_response:**
```json
← {"type": "health", "status": "ok", "gpu_util": 0.73, "mem_used_gb": 62.4, "mem_total_gb": 80.0}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"health"` |
| status | string | yes | Engine status (`"ok"`, `"degraded"`, `"error"`) |
| gpu_util | float | yes | GPU utilization 0.0-1.0 |
| mem_used_gb | float | yes | GPU memory used in GB |
| mem_total_gb | float | yes | GPU memory total in GB |

**memory_response:**
```json
← {"type": "memory", "total_gb": 80.0, "used_gb": 62.4, "available_gb": 17.6}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"memory"` |
| total_gb | float | yes | Total GPU memory in GB |
| used_gb | float | yes | Used GPU memory in GB |
| available_gb | float | yes | Available GPU memory in GB |

Additional fields may be present and are preserved in the decoded `memory_response` map.

**ready:**
```json
← {"type": "ready", "model": "Qwen/Qwen2.5-1.5B-Instruct", "backend": "vllm"}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"ready"` |
| model | string | yes | Loaded model name |
| backend | string | yes | Backend type (`"vllm"`, `"mlx"`, `"mock"`, etc.) |

**heartbeat:**
```json
← {"type": "heartbeat", "status": "loading", "detail": "downloading model weights"}
```
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| type | string | yes | Always `"heartbeat"` |
| status | string | yes | Current status (typically `"loading"`) |
| detail | string | no | Human-readable progress info (defaults to `""`) |

- [ ] **Step 4: Write the Shutdown Protocol section**

Document the 3-level escalation from `loom_port.erl` `shutting_down` state:

```
Level 1: Send {"type": "shutdown"} via stdin
  ↓ adapter should flush, cleanup, exit(0)
  ↓ wait shutdown_timeout_ms (default 10000)

Level 2: port_close() — closes stdin, triggers EOF
  ↓ adapter's stdin watchdog detects EOF, calls os._exit(1)
  ↓ wait post_close_timeout_ms (default 5000)

Level 3: OS force-kill (loom_os:force_kill/1)
  ↓ SIGKILL on Unix, taskkill /F on Windows
  ↓ process is dead
```

Explain why each level exists:
- Level 1: graceful — adapter can save state, flush buffers
- Level 2: stdin EOF — cross-platform force-exit via the watchdog thread pattern. Needed because Python's signal handling is unreliable in threaded programs.
- Level 3: OS kill — last resort if process is truly stuck (e.g., GPU driver hang)

- [ ] **Step 5: Write the Error Handling Contract section**

Document error codes returned by adapters:
- `invalid_json` — malformed JSON on stdin
- `missing_type` — JSON object missing `"type"` field
- `unknown_type` — unrecognized message type
- `missing_field` — required field absent
- `invalid_exit_code` — crash command with out-of-range exit code
- `internal_error` — unhandled exception in adapter
- `model_error` — engine-specific error during generation

Document what the coordinator does:
- Protocol errors (invalid_json, missing_type, etc.): logged, request fails
- Adapter crash (exit_status): coordinator notifies all in-flight callers with `{error, engine_crashed}`, then crashes itself so the supervisor can restart it
- Generation error: forwarded to the specific request caller

- [ ] **Step 6: Write the "Writing a New Adapter" tutorial**

Step-by-step guide referencing `priv/scripts/mock_adapter.py` as the canonical minimal example and `priv/python/loom_adapter_base.py` as the production base class.

**Option A: Subclass `LoomAdapterBase` (recommended for real engines)**

1. Create `priv/python/loom_adapter_<name>.py`
2. Subclass `LoomAdapterBase`
3. Implement 5 abstract methods: `load_model()`, `handle_generate()`, `handle_health()`, `handle_memory()`, `unload_model()`
4. The base class handles: stdin watchdog, heartbeat loop, command dispatch, protocol I/O
5. Register in `loom_config` by setting backend name in config

**Option B: Standalone script (simpler, for testing/prototyping)**

Walk through `mock_adapter.py` structure:
1. **Read stdin, write stdout** — all protocol messages are line-delimited JSON. Use stderr for logs.
2. **Startup sequence** — send at least one `heartbeat` (status=loading), then `ready` with model/backend.
3. **Command loop** — parse each line, dispatch by `type` field, return response messages.
4. **Stdin watchdog** — daemon thread reading stdin; on EOF, call `os._exit(1)`. This is critical — without it, the adapter process may orphan when the Erlang port closes.
5. **Token streaming** — for `generate`, send `token` messages one at a time, then a final `done`.
6. **Shutdown handler** — on `{"type": "shutdown"}`, flush and exit cleanly.

**Testing your adapter:**

```bash
# Test the protocol directly (no Erlang needed):
echo '{"type": "health"}' | python3 priv/scripts/mock_adapter.py

# Test via loom_port in an Erlang shell:
rebar3 shell
{ok, Pid} = loom_port:start_link(#{
    command => os:find_executable("python3"),
    args => ["priv/scripts/mock_adapter.py"]
}).
loom_port:send(Pid, {health}).
% Expect to receive: {loom_port_msg, _, {health_response, ...}}
```

**Registering in configuration:**

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

For known backends (`vllm`, `mlx`, `tensorrt`, `mock`), Loom automatically wraps with `python3`. For custom backends, `adapter_cmd` is executed directly as a binary.

- [ ] **Step 7: Verify the document**

Check that:
- All message field tables match `loom_protocol.erl` type specs exactly
- Timeout defaults match `loom_port.erl` source code
- The shutdown escalation matches `shutting_down/3` clauses
- The adapter tutorial commands actually work:
```bash
echo '{"type": "health"}' | python3 priv/scripts/mock_adapter.py 2>/dev/null | head -3
```

- [ ] **Step 8: Commit**

```bash
git add docs/protocol.md
git commit -m "docs: add wire protocol reference for #16

Complete message catalog with JSON examples and field tables,
startup sequence, 3-level shutdown protocol, error handling
contract, and Writing a New Adapter tutorial."
```

---

### Task 4: Trim `README.md` to Landing Page

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Restructure the README**

The new README structure (in order):

1. **Title + badges + tagline** — keep as-is
2. **AI-first blurb** — keep the 2-sentence version
3. **The Problem** — keep, condense slightly (cut the "These problems are manageable..." closing paragraph or tighten to 1 sentence)
4. **The Insight** — keep as-is (already tight)
5. **The Solution** — keep the ASCII diagram + 6 bullet point descriptions. Remove the supervision tree, Cowboy/gRPC detail, protocol explanation — all moved to docs/architecture.md
6. **Quick Start** — keep entirely (clone, mock, real backend, fault tolerance, endpoints table, backends table)
7. **Benchmarks** — keep entirely (full tables stay as pitch proof)
8. **Documentation** — NEW section:

```markdown
## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | Supervision tree, component responsibilities, message flow, comparisons |
| [Wire Protocol](docs/protocol.md) | JSON protocol reference, message catalog, writing a new adapter |
| [Knowledge Base](KNOWLEDGE.md) | Deep architectural context, design rationale, LLM fundamentals |
| [Roadmap](ROADMAP.md) | Phase-wise progress tracking with GitHub issue links |
| [Contributing](CONTRIBUTING.md) | PR workflow, branch naming, conventions |
```

9. **The Name** — keep as-is
10. **License** — keep as-is

**Remove these sections entirely:**
- "Architecture" (the supervision tree + component descriptions block) → moved to docs/architecture.md
- "How Loom Compares" (all comparison tables) → moved to docs/architecture.md
- "Technical Decisions" table → moved to docs/architecture.md
- "Integration Tests" section → moved to docs/architecture.md
- "Why Now" → cut (The Problem + The Insight cover the motivation)

- [ ] **Step 2: Verify the trimmed README**

Check:
- All links in the Documentation table resolve to existing files
- Quick Start curl commands are unchanged
- Benchmark tables are intact
- No orphaned section references

```bash
# Check doc links exist
for f in docs/architecture.md docs/protocol.md KNOWLEDGE.md ROADMAP.md CONTRIBUTING.md; do
  test -f "$f" && echo "OK: $f" || echo "MISSING: $f"
done
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: trim README to landing page for #16

Move architecture details, comparison tables, technical decisions,
and integration tests to docs/. README now focuses on pitch,
quick start, benchmarks, and documentation links."
```

---

### Task 5: Create `priv/scripts/demo.sh`

**Files:**
- Create: `priv/scripts/demo.sh`

- [ ] **Step 1: Write the demo script**

The script must:

1. **Check prerequisites:**
   - `erl` is on PATH
   - `rebar3` is on PATH
   - `_build/` directory exists (project compiled)
   - Port 8080 is not in use

2. **Use colored output:**
   - Green for success messages
   - Yellow for status/info
   - Red for the crash/kill step
   - Bold for step headers
   - `NO_COLOR` env var support (disable colors if set)

3. **Implement `press_enter()` pause function:**
   ```bash
   press_enter() {
     printf "\n${CYAN}Press Enter to continue...${RESET}"
     read -r
   }
   ```

4. **Start Loom in background:**
   ```bash
   rebar3 shell --sname loom_demo --setcookie loom_demo < /dev/null &
   LOOM_PID=$!
   ```
   Then poll `curl -s http://localhost:8080/health` until it returns 200 or timeout after 30s.

5. **Step through the demo:**

   **Step 1 — Health Check:**
   ```bash
   curl -s http://localhost:8080/health | python3 -m json.tool
   ```

   **Step 2 — Chat Completion (non-streaming):**
   ```bash
   curl -s http://localhost:8080/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model": "engine_0", "messages": [{"role": "user", "content": "Hello from the demo!"}]}'
   ```

   **Step 3 — Streaming (SSE):**
   ```bash
   curl -sN http://localhost:8080/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model": "engine_0", "messages": [{"role": "user", "content": "Tell me about BEAM"}], "stream": true}'
   ```

   **Step 4 — Kill the engine (the dramatic part):**
   ```bash
   ADAPTER_PID=$(pgrep -f "mock_adapter")
   kill -9 $ADAPTER_PID
   ```
   Show the PID that was killed.

   **Step 5 — Watch recovery:**
   Poll `/health` with timestamps, show each attempt until the engine reports ready. Display elapsed recovery time.

   **Step 6 — Post-recovery request:**
   Same as Step 2, proving the system recovered.

6. **Cleanup:**
   Trap EXIT/INT/TERM to kill the background rebar3 shell. Always run cleanup even if the script is interrupted.
   ```bash
   cleanup() {
     echo "Stopping Loom..."
     kill $LOOM_PID 2>/dev/null
     wait $LOOM_PID 2>/dev/null
   }
   trap cleanup EXIT
   ```

- [ ] **Step 2: Make executable and test**

```bash
chmod +x priv/scripts/demo.sh

# Quick smoke test — just verify prerequisites check works
# (Don't run the full demo in CI)
bash priv/scripts/demo.sh --help 2>&1 || true
```

The `--help` flag should print usage. If not implemented, at least verify the script is syntactically valid:
```bash
bash -n priv/scripts/demo.sh
```

- [ ] **Step 3: Commit**

```bash
git add priv/scripts/demo.sh
git commit -m "feat: add interactive demo script for #16

Guided walkthrough: start Loom, send requests, kill engine,
watch supervisor recovery, verify post-recovery. Uses mock
backend, no GPU required."
```

---

### Task 6: Final Verification and Cross-Link Check

**Files:**
- Possibly modify: `docs/README.md`, `docs/architecture.md`, `docs/protocol.md`, `README.md`

- [ ] **Step 1: Verify all cross-references**

```bash
# Check all internal doc links resolve
echo "=== README.md links ==="
grep -oP '\[.*?\]\(((?!http)[^)]+)\)' README.md | grep -oP '\(([^)]+)\)' | tr -d '()' | while read f; do
  test -f "$f" && echo "  OK: $f" || echo "  BROKEN: $f"
done

echo "=== docs/README.md links ==="
cd docs && grep -oP '\[.*?\]\(((?!http)[^)]+)\)' README.md | grep -oP '\(([^)]+)\)' | tr -d '()' | while read f; do
  test -f "$f" && echo "  OK: $f" || echo "  BROKEN: $f"
done && cd ..
```

- [ ] **Step 2: Verify demo script runs (manual)**

Run the demo interactively:
```bash
./priv/scripts/demo.sh
```

Walk through all steps. Verify:
- Prerequisites check passes
- Loom starts and health endpoint responds
- Chat completion returns mock tokens
- Streaming shows SSE events
- Kill + recovery works
- Post-recovery request succeeds
- Cleanup stops the background process

- [ ] **Step 3: Fix any issues found, commit if needed**

```bash
git add -A
git commit -m "docs: fix cross-references and polish for #16"
```

Only commit if there are actual fixes. Skip if everything is clean.

---

### Task 7: Update docs/README.md with final links

**Files:**
- Modify: `docs/README.md`

- [ ] **Step 1: Verify index is complete**

Ensure `docs/README.md` links to both `architecture.md` and `protocol.md` (which now exist).

- [ ] **Step 2: Commit if changed**

```bash
git add docs/README.md
git commit -m "docs: finalize docs index for #16"
```
