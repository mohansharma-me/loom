# Design Plan: CC-03 — Type Specs & Dialyzer Compliance (#51)

## Overview

Add `-spec` annotations to all public functions across all 25 production modules, define formal domain types in the modules that own them, re-enable the `underspecs` Dialyzer warning, and achieve zero warnings with stricter checking.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Scope | Foundation + Retrofit all modules | Existing code must exemplify type conventions for future AI agent work |
| Type location | Module-scoped with `-export_type` | OTP-idiomatic, avoids central header coupling, follows existing pattern |
| Dialyzer strictness | Re-enable `underspecs` | New domain types should narrow broad specs enough to eliminate false positives |

## New Domain Types

Types defined in the module that owns the concept, exported via `-export_type`:

### `loom_engine_coordinator`

```erlang
-type engine_id() :: binary().
-type engine_status() :: starting | ready | draining | stopped.
-type engine_request_id() :: binary().
-export_type([engine_id/0, engine_status/0, engine_request_id/0]).
%% NOTE: generate params reuse loom_protocol:generate_params() — no duplicate type needed.
```

### `loom_port`

```erlang
-type port_state() :: spawning | loading | ready | shutting_down.
-type port_opts() :: #{
    command := string(),
    args => [string()],
    env => [{string(), string()}]
}.
-export_type([port_state/0, port_opts/0]).
```

### `loom_http_util`

```erlang
-type request_id() :: binary().
-export_type([request_id/0]).
```

### `loom_gpu_monitor`

```erlang
-type threshold_config() :: #{
    gpu_util => float(),
    mem_util => float(),
    temperature => float()
}.
-export_type([threshold_config/0]).
```

### Existing Types (unchanged)

- `loom_protocol` — `generate_params()`, `outbound_msg()`, `inbound_msg()`, `buffer()` (opaque), `decode_error()`
- `loom_gpu_backend` — `gpu_id()`, `metrics()`
- `loom_config` — `config_path()`, `validation_error()`
- `loom_json` — `json_value()`, `json_encodable()`

## Spec Coverage Plan

### Small (1-3 public functions)

| Module | Functions to Spec |
|--------|------------------|
| `loom_handler_health` | `init/2` |
| `loom_handler_models` | `init/2` |
| `loom_os` | `kill/1`, `is_alive/1` |
| `loom_http` | wrapper functions |

### Medium (4-8 public functions)

| Module | Functions to Spec |
|--------|------------------|
| `loom_handler_chat` | `init/2`, `info/3`, streaming helpers |
| `loom_handler_messages` | `init/2`, `info/3`, streaming helpers |
| `loom_http_middleware` | `execute/2`, helpers |
| `loom_http_server` | `start/1`, `stop/0`, lifecycle |
| `loom_sup` | `start_link/1`, `init/1` |
| `loom_gpu_backend_mock` | callback implementations |

### Verify + Fill Gaps

| Module | Status |
|--------|--------|
| `loom_json` | 2 specs exist, verify completeness |
| `loom_gpu_backend` | Behaviour-only module, callback specs correct |

## Dialyzer Configuration Changes

### Re-enable `underspecs`

```erlang
{dialyzer, [
    {warnings, [
        error_handling,
        underspecs,       %% Re-enabled: domain types narrow broad specs
        unmatched_returns
    ]},
    {plt_extra_apps, [ranch]},
    {warnings_filter, [
        {cowboy_req, unknown_type}
    ]}
]}.
```

If specific modules still trigger false positives after narrowing, use per-module suppression via `warnings_filter` rather than global disable.

## Approach Per Module

1. Add domain type definitions and `-export_type` where the module owns the concept
2. Add `-spec` to all exported functions
3. Add `-spec` to non-trivial internal functions where it aids readability
4. Run Dialyzer, fix any new warnings
5. Verify `warn_missing_spec` passes (already enforced in prod erl_opts)

## Files to Modify

- `rebar.config` — re-enable `underspecs` in Dialyzer warnings
- `src/loom_engine_coordinator.erl` — add 4 domain types + fill spec gaps
- `src/loom_port.erl` — add 2 domain types + fill spec gaps
- `src/loom_http_util.erl` — add `request_id()` type
- `src/loom_gpu_monitor.erl` — add `threshold_config()` type
- All 12 under-specced modules — add `-spec` annotations to all public functions
