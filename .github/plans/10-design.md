# Design Plan: P0-09 loom_engine_sup rest_for_one Supervisor

**Parent Issue:** [#10](https://github.com/mohansharma-me/loom/issues/10)
**Date:** 2026-03-25

## Overview

`loom_engine_sup` is a `rest_for_one` supervisor managing a single engine's coordinator and its associated GPU monitors. It is the per-engine supervision unit in Loom's supervision tree.

## Architecture

### Supervision Strategy: `rest_for_one`

Child ordering:
1. `coordinator` — `loom_engine_coordinator` (gen_statem)
2. `{gpu_monitor, GpuId}` — one `loom_gpu_monitor` per GPU in the `gpus` list

Restart semantics:
- Coordinator crash: all children restart (coordinator + all monitors)
- Monitor crash: only that monitor restarts
- This matches the domain: if the engine process dies, GPU monitors need fresh coordinator pids. If a single GPU monitor dies, nothing else is affected.

### Coordinator PID Discovery (Key Design Decision)

**Problem:** GPU monitors need the coordinator's pid to send alerts, but the pid changes on every restart.

**Solution:** The supervisor module exports a `start_monitor/2` helper used as the MFA in monitor child specs. This function looks up the coordinator pid by reading the owner of its named ETS meta table (`ets:info(MetaTable, owner)`).

**Implementation note (deviation from original design):** The original design used `supervisor:which_children/1` to find the coordinator. This was discovered to deadlock during implementation because `start_monitor` is called during the supervisor's own child startup sequence — a synchronous call to the supervisor process that is itself blocked starting children (calling_self). The ETS-based lookup avoids this: the coordinator creates its named ETS tables in `init/1` (synchronous, before the supervisor moves to the next child), so by the time any monitor starts, the table exists and its owner is the coordinator pid.

```erlang
start_monitor(EngineId, GpuOpts) ->
    MetaTable = loom_engine_coordinator:meta_table_name(EngineId),
    try ets:info(MetaTable, owner) of
        Pid when is_pid(Pid) ->
            loom_gpu_monitor:start_link(GpuOpts#{coordinator => Pid});
        undefined ->
            {error, coordinator_not_found}
    catch
        error:badarg ->
            {error, coordinator_not_found}
    end.
```

**Why this is safe:** OTP supervisors start children sequentially in spec-list order. The coordinator is first, so its ETS tables exist before any monitor starts. On restart under `rest_for_one`, the coordinator is restarted first, creating fresh ETS tables before monitors are restarted.

**Failure mode:** If the coordinator somehow fails to start, `start_monitor` returns `{error, coordinator_not_found}`, which triggers the supervisor's restart logic. If this persists, the supervisor exhausts its restart intensity and terminates — fail-fast, no silent degradation.

**Alternatives considered:**
- Register coordinator by name: invasive change to completed P0-08 module
- Dynamic child adds from external caller: broken under `rest_for_one` restart (stale pids)

### Supervisor Registration

The supervisor registers as `{local, loom_engine_sup_<engine_id>}` so that `start_monitor` can find the supervisor by name.

ASSUMPTION: `sup_name/1` relies on `engine_id` already being validated as `[a-zA-Z0-9_]+` (max 64 bytes) by `loom_engine_coordinator:validate_config/1`. The derived atom is safe.

### Config Mapping

Input config (from issue #10):
```erlang
#{
    engine_id => <<"engine_0">>,
    model => <<"meta-llama/Llama-3-8B">>,
    backend => vllm,
    adapter_cmd => "/path/to/loom_adapter.py",
    adapter_args => ["--model", "meta-llama/Llama-3-8B"],
    gpus => [0, 1],
    gpu_poll_interval => 5000
}
```

**Coordinator option passthrough:** The supervisor maps top-level config keys to the coordinator's expected format. Coordinator-specific options (`startup_timeout_ms`, `drain_timeout_ms`, `max_concurrent`, `port_opts`) are forwarded as-is if present; otherwise the coordinator's own defaults apply (120s, 30s, 64, `#{}`). No nesting — all keys are top-level.

Coordinator child receives:
```erlang
#{
    engine_id => <<"engine_0">>,
    command => "/path/to/loom_adapter.py",
    args => ["--model", "meta-llama/Llama-3-8B"],
    model => <<"meta-llama/Llama-3-8B">>,
    backend => vllm,
    %% Plus any optional keys passed through:
    %% startup_timeout_ms, drain_timeout_ms, max_concurrent, port_opts
}
```

**GPU monitor option passthrough:** Monitor-specific options (`poll_timeout_ms`, `thresholds`) are forwarded if present; otherwise monitor defaults apply. `allow_mock_backend` is forwarded from the top-level config. Note: the top-level `backend` key is NOT forwarded because the engine config stores it as a binary (e.g., `<<"mock">>`) while `loom_gpu_monitor` expects an atom (e.g., `mock`). The monitor uses auto-detection by default.

Each GPU monitor child receives (via `start_monitor`):
```erlang
#{
    gpu_id => 0,
    poll_interval_ms => 5000,
    allow_mock_backend => true/false,
    coordinator => <coordinator_pid>
    %% Plus any optional keys passed through:
    %% poll_timeout_ms, thresholds
}
```

### Child Specs

Coordinator child spec:
```erlang
#{
    id => coordinator,
    start => {loom_engine_coordinator, start_link, [CoordConfig]},
    restart => permanent,
    shutdown => 35000,  %% drain_timeout_ms (30s) + 5s margin
    type => worker
}
```

ASSUMPTION: The `shutdown` value (35000ms) accommodates the coordinator's default `drain_timeout_ms` of 30000ms plus a 5-second margin. If the user overrides `drain_timeout_ms` in config, the supervisor computes `shutdown` as `drain_timeout_ms + 5000`.

GPU monitor child spec (one per GPU):
```erlang
#{
    id => {gpu_monitor, GpuId},
    start => {loom_engine_sup, start_monitor, [EngineId, GpuOpts]},
    restart => permanent,
    shutdown => 5000,
    type => worker
}
```

The monitor's MFA is `{loom_engine_sup, start_monitor, [EngineId, GpuOpts]}` — NOT `{loom_gpu_monitor, start_link, [...]}`. This indirection is what enables dynamic coordinator PID discovery on every restart.

### Restart Intensity

Configurable via `max_restarts` (default 5) and `max_period` (default 60), matching the acceptance criteria default of 5 restarts in 60 seconds.

### Logging

As a core supervision piece, `loom_engine_sup` must log at every key decision point using `?LOG_INFO` / `?LOG_WARNING` / `?LOG_ERROR` via `kernel/include/logger.hrl`. All log lines include `engine_id` for correlation.

| Event | Level | What to log |
|-------|-------|-------------|
| Supervisor starting | INFO | engine_id, number of GPUs, restart intensity config |
| Coordinator child spec built | INFO | engine_id, command, model, backend, shutdown timeout |
| `start_monitor` called | INFO | engine_id, gpu_id, resolved coordinator pid |
| `start_monitor` coordinator not found | ERROR | engine_id, gpu_id, children list state |
| Config validation failure | ERROR | engine_id, specific validation error |
| Config key mapping | INFO | engine_id, mapped adapter_cmd->command, adapter_args->args, gpu_poll_interval->poll_interval_ms |

This ensures that supervisor startup, every monitor-to-coordinator binding, and every failure path are visible in logs without needing to enable debug tracing.

## Module API

```erlang
-module(loom_engine_sup).
-behaviour(supervisor).

%% API
-export([start_link/1, start_monitor/2]).

%% supervisor callback
-export([init/1]).

%% Start the supervisor with engine config
-spec start_link(map()) -> {ok, pid()} | {error, term()}.

%% Called by supervisor to start a GPU monitor child (not called directly)
-spec start_monitor(binary(), map()) -> {ok, pid()} | {error, term()}.
```

## Testing Strategy

Common Test suite: `test/loom_engine_sup_SUITE.erl`

| Test Case | What It Validates |
|-----------|-------------------|
| `start_with_config` | Starts supervisor with 2 GPUs, verifies coordinator + 2 monitors alive in correct order |
| `start_with_no_gpus` | Starts supervisor with empty `gpus` list, verifies coordinator-only operation |
| `different_configs` | Starts two supervisors with different engine configs, verifies independent operation |
| `coordinator_crash_restarts_all` | Kill coordinator, verify all monitors terminated and restarted with new coordinator pid |
| `monitor_crash_restarts_only_monitor` | Kill one monitor, verify coordinator and other monitor unaffected |
| `max_restart_intensity` | Crash coordinator past limit, verify supervisor terminates |
| `monitor_alerts_after_restart` | After coordinator crash + restart, verify monitors can send alerts to new coordinator |

All tests use mock GPU backend and mock adapter script. No GPU required.

## Files Changed

| File | Change |
|------|--------|
| `src/loom_engine_sup.erl` | New — supervisor module |
| `test/loom_engine_sup_SUITE.erl` | New — common test suite |
| `src/loom.app.src` | Add `loom_engine_sup` to modules list (if not auto-discovered) |

## Assumptions

- ASSUMPTION: `engine_id` uniqueness is enforced by the caller (future `loom_engine_pool_sup` in P1-01). Two supervisors with the same engine_id would clash on registered names.
- ASSUMPTION: The `gpus` list in config can be empty (no GPU monitors started). The coordinator still functions without monitors.
- ASSUMPTION: No changes to `loom_engine_coordinator` or `loom_gpu_monitor` are needed. Both modules' existing APIs are sufficient.
