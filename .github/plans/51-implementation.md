# CC-03: Type Specs & Dialyzer Compliance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `-spec` annotations to all public functions, define formal domain types in owning modules, and re-enable the `underspecs` Dialyzer warning with zero warnings.

**Architecture:** Define domain types (engine_id, engine_status, etc.) in the modules that own them with `-export_type`. Add `-spec` to all exported functions in the 12 under-specced modules. Re-enable `underspecs` in Dialyzer and fix any resulting warnings. All changes are additive annotations — no behavioral changes.

**Tech Stack:** Erlang/OTP 27+ type system, Dialyzer

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `src/loom_engine_coordinator.erl` | Add engine_id/0, engine_status/0, engine_request_id/0 types |
| Modify | `src/loom_port.erl` | Add port_state/0, port_opts/0 types |
| Modify | `src/loom_http_util.erl` | Add request_id/0 type |
| Modify | `src/loom_gpu_monitor.erl` | Add threshold_config/0 type |
| Modify | `src/loom_handler_health.erl` | Verify/add specs |
| Modify | `src/loom_handler_models.erl` | Verify/add specs |
| Modify | `src/loom_handler_chat.erl` | Add specs to internal functions |
| Modify | `src/loom_handler_messages.erl` | Add specs to internal functions |
| Modify | `src/loom_os.erl` | Verify/add specs |
| Modify | `src/loom_http.erl` | Verify/add specs |
| Modify | `src/loom_http_middleware.erl` | Verify/add specs |
| Modify | `src/loom_http_server.erl` | Verify/add specs |
| Modify | `src/loom_sup.erl` | Verify/add specs |
| Modify | `src/loom_gpu_backend_mock.erl` | Verify/add specs |
| Modify | `src/loom_json.erl` | Verify completeness |
| Modify | `src/loom_cmd.erl` | Add specs to internal functions |
| Modify | `rebar.config:47-63` | Re-enable underspecs |

---

### Task 1: Add domain types to loom_engine_coordinator

**Files:**
- Modify: `src/loom_engine_coordinator.erl`

- [ ] **Step 1: Add type definitions after the module declaration and before exports**

After `-behaviour(gen_statem).` and before the `%% Public API` export block, add:

```erlang
%% Domain types
-type engine_id() :: binary().
-type engine_status() :: starting | ready | draining | stopped.
-type engine_request_id() :: binary().
-export_type([engine_id/0, engine_status/0, engine_request_id/0]).
```

- [ ] **Step 2: Update existing specs to use domain types**

Where specs currently use `binary()` for engine_id parameters, update to `engine_id()`. For example in `get_status/1`, `get_load/1`, `get_info/1`:

```erlang
-spec get_status(engine_id()) -> engine_status().
-spec get_load(engine_id()) -> non_neg_integer().
-spec get_info(engine_id()) -> map().
```

Update `generate_request_id/0`:

```erlang
-spec generate_request_id() -> engine_request_id().
```

- [ ] **Step 3: Verify compilation**

Run: `rebar3 compile`

Expected: No errors.

- [ ] **Step 4: Run Dialyzer**

Run: `rebar3 dialyzer`

Expected: Zero warnings (still using current config without underspecs).

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_coordinator.erl
git commit -m "feat(types): add engine_id, engine_status, engine_request_id domain types (#51)"
```

---

### Task 2: Add domain types to loom_port

**Files:**
- Modify: `src/loom_port.erl`

- [ ] **Step 1: Add type definitions after -behaviour(gen_statem)**

```erlang
%% Domain types
-type port_state() :: spawning | loading | ready | shutting_down.
-type port_opts() :: #{
    command := string(),
    args => [string()],
    env => [{string(), string()}],
    owner => pid(),
    engine_id => binary(),
    max_line_length => pos_integer(),
    spawn_timeout_ms => pos_integer(),
    heartbeat_timeout_ms => pos_integer(),
    shutdown_timeout_ms => pos_integer(),
    post_close_timeout_ms => pos_integer()
}.
-export_type([port_state/0, port_opts/0]).
```

- [ ] **Step 2: Update get_state/1 spec to use port_state()**

```erlang
-spec get_state(pid()) -> port_state().
```

- [ ] **Step 3: Verify and commit**

Run: `rebar3 compile && rebar3 dialyzer`

Expected: No errors, zero warnings.

```bash
git add src/loom_port.erl
git commit -m "feat(types): add port_state, port_opts domain types (#51)"
```

---

### Task 3: Add domain types to loom_http_util and loom_gpu_monitor

**Files:**
- Modify: `src/loom_http_util.erl`
- Modify: `src/loom_gpu_monitor.erl`

- [ ] **Step 1: Add request_id type to loom_http_util**

After the module declaration and before exports, add:

```erlang
-type request_id() :: binary().
-export_type([request_id/0]).
```

Update `generate_request_id/0` spec:

```erlang
-spec generate_request_id() -> request_id().
```

- [ ] **Step 2: Add threshold_config type to loom_gpu_monitor**

After the behaviour declaration and before exports, add:

```erlang
-type threshold_config() :: #{
    temperature_c => float(),
    mem_percent => float()
}.
-export_type([threshold_config/0]).
```

- [ ] **Step 3: Verify and commit**

Run: `rebar3 compile && rebar3 dialyzer`

```bash
git add src/loom_http_util.erl src/loom_gpu_monitor.erl
git commit -m "feat(types): add request_id and threshold_config domain types (#51)"
```

---

### Task 4: Add specs to small modules — handlers and utilities

**Files:**
- Modify: `src/loom_handler_health.erl`
- Modify: `src/loom_handler_models.erl`
- Modify: `src/loom_os.erl`
- Modify: `src/loom_http.erl`

- [ ] **Step 1: Verify loom_handler_health specs**

Current file already has:
```erlang
-spec init(cowboy_req:req(), any()) -> {ok, cowboy_req:req(), any()}.
```

This is the only exported function. Already complete. No changes needed.

- [ ] **Step 2: Verify loom_handler_models specs**

Current file already has:
```erlang
-spec init(cowboy_req:req(), any()) -> {ok, cowboy_req:req(), any()}.
```

Only exported function. Already complete. No changes needed.

- [ ] **Step 3: Verify loom_os specs**

Current file has:
```erlang
-spec force_kill(pos_integer() | undefined) -> ok.
```

Only exported function. Already complete. No changes needed.

- [ ] **Step 4: Verify loom_http specs**

Current file has:
```erlang
-spec start() -> {ok, pid()} | {error, term()}.
-spec stop() -> ok.
```

Both exported functions specced. Already complete. No changes needed.

- [ ] **Step 5: Verify compilation**

Run: `rebar3 compile`

Expected: No errors. If `warn_missing_spec` was already enforced, these would have failed before.

- [ ] **Step 6: Commit (skip if no changes)**

These modules are already fully specced. No commit needed.

---

### Task 5: Add specs to medium modules — HTTP handlers

**Files:**
- Modify: `src/loom_handler_chat.erl`
- Modify: `src/loom_handler_messages.erl`

- [ ] **Step 1: Verify loom_handler_chat specs**

Current specs:
```erlang
-spec init(cowboy_req:req(), any()) ->
    {cowboy_loop, cowboy_req:req(), #state{}, non_neg_integer()} |
    {ok, cowboy_req:req(), #state{}}.

-spec info(any(), cowboy_req:req(), #state{}) ->
    {ok, cowboy_req:req(), #state{}, non_neg_integer()} |
    {stop, cowboy_req:req(), #state{}}.

-spec terminate(any(), cowboy_req:req(), #state{}) -> ok.

-spec read_and_parse(cowboy_req:req(), non_neg_integer()) ->
    {ok, map(), cowboy_req:req()} | {error, binary(), cowboy_req:req()}.
```

All exported functions (`init/2`, `info/3`, `terminate/3`) and the internal `read_and_parse/2` are already specced. No changes needed.

- [ ] **Step 2: Verify loom_handler_messages specs**

Current specs:
```erlang
-spec init(cowboy_req:req(), any()) ->
    {cowboy_loop, cowboy_req:req(), #state{}, non_neg_integer()} |
    {ok, cowboy_req:req(), #state{}}.

-spec info(any(), cowboy_req:req(), #state{}) ->
    {ok, cowboy_req:req(), #state{}, non_neg_integer()} |
    {stop, cowboy_req:req(), #state{}}.

-spec terminate(any(), cowboy_req:req(), #state{}) -> ok.

-spec read_and_parse(cowboy_req:req(), non_neg_integer()) ->
    {ok, map(), cowboy_req:req()} | {error, binary(), cowboy_req:req()}.
```

All specced. No changes needed.

- [ ] **Step 3: Commit (skip if no changes)**

Both handler modules are already fully specced. No commit needed.

---

### Task 6: Add specs to medium modules — infrastructure

**Files:**
- Modify: `src/loom_http_middleware.erl`
- Modify: `src/loom_http_server.erl`
- Modify: `src/loom_sup.erl`

- [ ] **Step 1: Verify loom_http_middleware specs**

Current specs:
```erlang
-spec execute(cowboy_req:req(), cowboy_middleware:env()) ->
    {ok, cowboy_req:req(), cowboy_middleware:env()} | {stop, cowboy_req:req()}.

-spec validate_content_type(binary(), cowboy_req:req()) -> ok | {error, cowboy_req:req()}.
```

Both exported and internal function specced. Complete.

- [ ] **Step 2: Verify loom_http_server specs**

Current specs:
```erlang
-spec start_link() -> {ok, pid()} | {error, term()}.
-spec init([]) -> {ok, map()} | {stop, term()}.
-spec handle_call(term(), gen_server:from(), map()) -> {reply, {error, not_implemented}, map()}.
-spec handle_cast(term(), map()) -> {noreply, map()}.
-spec handle_info(term(), map()) -> {noreply, map()}.
-spec terminate(term(), map()) -> ok.
```

All gen_server callbacks specced. Complete.

- [ ] **Step 3: Verify loom_sup specs**

Current specs:
```erlang
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
-spec build_engine_children() -> [supervisor:child_spec()].
-spec flatten_engine_config(map()) -> map().
-spec adapter_cmd_and_args(string(), binary()) -> {string(), [string()]}.
```

All exported and internal functions specced. Complete.

- [ ] **Step 4: Commit (skip if no changes)**

All infrastructure modules are already fully specced. No commit needed.

---

### Task 7: Add specs to loom_gpu_backend_mock and loom_cmd

**Files:**
- Modify: `src/loom_gpu_backend_mock.erl`
- Modify: `src/loom_cmd.erl`

- [ ] **Step 1: Verify loom_gpu_backend_mock specs**

Current specs:
```erlang
-spec detect() -> boolean().
-spec init(map()) -> {ok, map()}.
-spec poll(map()) -> {ok, loom_gpu_backend:metrics(), map()} | {error, term()}.
-spec terminate(map()) -> ok.
-spec default_thresholds() -> #{atom() => number()}.
-spec default_metrics() -> loom_gpu_backend:metrics().
```

All functions specced. Complete.

- [ ] **Step 2: Verify loom_cmd specs**

Current specs:
```erlang
-spec run_with_timeout(string(), pos_integer()) -> {ok, string()} | {error, term()}.
-spec wait_result(reference(), reference(), pid(), pos_integer() | undefined, string(), pos_integer(), non_neg_integer()) -> {ok, string()} | {error, term()}.
-spec flush_ref(reference()) -> ok.
-spec collect_port_output(port(), binary(), pid(), reference()) -> ok.
```

All functions specced. Complete.

- [ ] **Step 3: Commit (skip if no changes)**

Both modules already fully specced. No commit needed.

---

### Task 8: Verify loom_json completeness

**Files:**
- Modify: `src/loom_json.erl` (if needed)

- [ ] **Step 1: Verify loom_json specs**

Current:
```erlang
-spec encode(json_encodable()) -> binary().
-spec decode(binary()) -> json_value().
```

Both exported functions specced. Types already exported. Complete. No changes needed.

---

### Task 9: Re-enable underspecs in Dialyzer

**Files:**
- Modify: `rebar.config:47-63`

- [ ] **Step 1: Re-enable underspecs warning**

In `rebar.config`, replace the dialyzer warnings block:

```erlang
{dialyzer, [
    {warnings, [
        error_handling,
        %% ASSUMPTION: underspecs removed because generic validation helpers
        %% (with_fields, require) use broad specs (map(), binary()) that
        %% Dialyzer narrows — these are not real type safety issues.
        unmatched_returns
    ]},
```

with:

```erlang
{dialyzer, [
    {warnings, [
        error_handling,
        underspecs,
        unmatched_returns
    ]},
```

- [ ] **Step 2: Run Dialyzer with underspecs enabled**

Run: `rebar3 dialyzer`

Expected: Zero warnings. If any underspecs warnings appear, they need to be fixed by narrowing the specs (using domain types) or adding module-specific suppressions.

- [ ] **Step 3: Fix any underspecs warnings**

If Dialyzer reports underspecs warnings:
1. Read the warning to understand which spec is broader than the implementation
2. Narrow the spec to match what Dialyzer infers
3. If the broad spec is intentional (e.g., a validation function that accepts any map), add a per-module filter in `warnings_filter`

- [ ] **Step 4: Verify all tests still pass**

Run: `rebar3 eunit && rebar3 ct --verbose`

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add rebar.config
git commit -m "feat(dialyzer): re-enable underspecs warning — zero warnings (#51)"
```

---

### Task 10: Final verification

- [ ] **Step 1: Verify warn_missing_spec passes on all modules**

Run: `rebar3 compile`

Expected: No warnings (warn_missing_spec is in default erl_opts). If any module is missing a spec on an exported function, the compile will fail with `warnings_as_errors`.

- [ ] **Step 2: Run Dialyzer with full warnings**

Run: `rebar3 dialyzer`

Expected: Zero warnings with error_handling + underspecs + unmatched_returns all enabled.

- [ ] **Step 3: Run full test suite**

Run: `rebar3 eunit && rebar3 ct --verbose`

Expected: All tests pass.

- [ ] **Step 4: Verify domain types are exported**

Run: `grep -rn 'export_type' src/ --include='*.erl'`

Expected: Types exported from:
- `loom_engine_coordinator` — engine_id/0, engine_status/0, engine_request_id/0
- `loom_port` — port_state/0, port_opts/0
- `loom_http_util` — request_id/0
- `loom_gpu_monitor` — threshold_config/0
- `loom_protocol` — outbound_msg/0, inbound_msg/0, generate_params/0, buffer/0, decode_error/0
- `loom_gpu_backend` — metrics/0, gpu_id/0
- `loom_config` — config_path/0, validation_error/0
- `loom_json` — json_value/0, json_encodable/0
