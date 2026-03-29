# Design: P0-11 — Wire All Phase 0 Components Into Application Supervisor Tree

**Issue:** [#12](https://github.com/mohansharma-me/loom/issues/12)
**Date:** 2026-03-27
**Status:** Approved

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Config source | Unified on `loom.json` via `loom_config` ETS | Single source of truth; target users expect JSON; ETS reads are concurrent |
| Config reading | Direct ETS reads, no GenServer serialization | `ets:lookup` is lock-free for concurrent readers |
| Startup failure | Crash on required fields, warn + default on optional | Fail-fast for broken config, tolerant for omitted optional settings |
| Cowboy supervision | Thin `loom_http_server` gen_server wrapper | Lifecycle coupling with `loom_sup`; not in request path |
| Start ordering | HTTP before engines | Health endpoint available immediately for readiness probes; engines report status as they come up |
| HTTP config bridge | `loom_http_util:get_config/0` reads `loom_config` ETS directly | Consistent with rest of system; removes `application:get_env` dependency |

## Startup Sequence

```
loom_app:start/2
  ├─ loom_config:load()          % Synchronous, blocking.
  │                              % Crash on: missing file, invalid JSON,
  │                              %   missing required engine fields (name, backend, model),
  │                              %   adapter file not found.
  │                              % Warn + default on: missing server section,
  │                              %   missing gpu_ids, missing timeout overrides.
  │
  └─ loom_sup:start_link()       % one_for_one, intensity=5, period=10
       │
       ├─ [1] loom_http_server   % Thin gen_server lifecycle wrapper
       │      init/1 → cowboy:start_clear/3
       │      terminate/2 → cowboy:stop_listener/1
       │
       └─ [2..N] loom_engine_sup:<engine_id>
              (rest_for_one)
              ├─ coordinator (gen_statem → spawns port subprocess)
              └─ gpu_monitor(s) (one per GPU in gpu_ids)
```

- HTTP starts first: `/health` returns 503/starting until engine reaches `ready`.
- Engines start after HTTP. Coordinator launches port, transitions `starting → ready`.
- `one_for_one` at top level: engine crash does not affect HTTP; HTTP crash does not affect engines.

## Config Flow

```
config/loom.json
  │
  ▼
loom_config:load()  ──→  ETS table `loom_config`
                          ├─ {config, parsed}
                          ├─ {server, config}
                          ├─ {engine, names}
                          └─ {engine, <<"engine_0">>}
                                    │
          ┌───────────────┬─────────┴──────────┐
          ▼               ▼                    ▼
   loom_http_util    loom_sup:init/1    loom_engine_sup
   get_config/0      build child specs  start_link/1
   (direct ETS)      (direct ETS)       (config as arg)
```

### Engine config assembly (`loom_sup:init/1`)

For each name in `loom_config:engine_names()`:
1. `loom_config:get_engine(Name)` → raw engine map
2. `loom_config:resolve_adapter(EngineMap)` → adapter command path
3. Merge with `loom_config` defaults (coordinator, port, gpu_monitor)
4. Build child spec for `loom_engine_sup:start_link/1`

### HTTP config (`loom_http_util:get_config/0`)

- `loom_config:get_server()` for port, ip, max_connections
- Handler-specific defaults for timeouts, max_body_size
- `engine_id` defaults to first engine from `loom_config:engine_names()`

## New Module: `loom_http_server`

Thin lifecycle gen_server (~30 lines). Not in the request path.

```erlang
-module(loom_http_server).
-behaviour(gen_server).

init([]) ->
    case loom_http:start() of
        {ok, _Pid} -> {ok, #{}};
        {error, Reason} -> {stop, Reason}
    end.

terminate(_Reason, _State) ->
    loom_http:stop().
```

- No meaningful state, no handle_call/handle_cast/handle_info beyond defaults.
- Cowboy manages its own processes under `ranch_sup`.
- Crash in `cowboy:start_clear/3` → supervisor applies restart policy.

## Fail-Fast Behavior

### Crashes (required fields)

| Condition | Error |
|-----------|-------|
| Missing `loom.json` | `{error, {config_error, enoent}}` |
| Invalid JSON | `{error, {config_error, {invalid_json, ...}}}` |
| Engine missing `name`, `backend`, or `model` | Crash during config load |
| Adapter file not found | Crash during config load (already validated) |

### Warns + defaults (optional fields)

| Condition | Default |
|-----------|---------|
| Missing `server` section | port 8080, ip 0.0.0.0, max_connections 1024 |
| Missing `gpu_ids` | Empty list (no GPU monitors started) |
| Missing timeout/concurrency overrides | `loom_config` built-in defaults |

## File Changes

| File | Change |
|------|--------|
| `src/loom_app.erl` | Add `loom_config:load()` before `loom_sup:start_link()`, return `{error, {config_error, Reason}}` on failure |
| `src/loom_sup.erl` | Build child specs: `loom_http_server` first, then one `loom_engine_sup` per engine from config |
| `src/loom_http_server.erl` | **New.** Thin gen_server wrapping `loom_http:start/0` and `stop/0` |
| `src/loom_http_util.erl` | `get_config/0` reads from `loom_config` ETS instead of `application:get_env` |
| `src/loom_http.erl` | Remove NOTE comment about manual start. Update `start/0` to read config from `loom_http_util:get_config/0` (which now reads from `loom_config` ETS) — no direct `application:get_env` calls remain. |
| `config/sys.config` | Remove `{loom, [...]}` section, keep only SASL |

### No changes to

`loom_engine_sup`, `loom_engine_coordinator`, `loom_gpu_monitor`, `loom_port`, `loom_handler_*`, `loom_config`, `config/loom.json`.

## Testing

Common Test suite (`test/loom_app_SUITE.erl`) that:

1. Starts the full application with mock adapter config
2. Verifies all components appear in supervisor tree
3. `GET /health` returns 200 with `{"status": "ready"}`
4. `POST /v1/chat/completions` with mock adapter returns tokens
5. Config errors cause clean startup failure
6. Application stop cleans up all processes (no orphans)
