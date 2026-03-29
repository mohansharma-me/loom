# Design Plan: JSON Configuration Parsing Module (`loom_config`)

**Issue:** [#65](https://github.com/mohansharma-me/loom/issues/65) — CC-04 (pulled to Phase 0)
**Status:** Approved
**Date:** 2026-03-27

---

## Summary

`loom_config` is a standalone Erlang module that loads, validates, merges, and serves configuration from a single JSON file (`config/loom.json`). It replaces `sys.config` as the source of all Loom-specific settings, providing a user-friendly config surface for both simple and advanced use cases.

Config is loaded once at application startup (before the supervisor tree), stored in a named ETS table with read concurrency, and accessed via a typed API. Merge precedence: **per-engine overrides > `defaults` section > hardcoded defaults in code**.

---

## JSON Config Schema

### Full Schema

```json
{
  "engines": [
    {
      "name": "qwen2.5-1.5b",
      "backend": "vllm",
      "model": "Qwen/Qwen2.5-1.5B-Instruct",
      "gpu_ids": [0],
      "tp_size": 1,
      "adapter_cmd": "/custom/path/adapter.py",
      "port": {},
      "gpu_monitor": {},
      "coordinator": {}
    }
  ],
  "defaults": {
    "port": {
      "max_line_length": 1048576,
      "spawn_timeout_ms": 5000,
      "heartbeat_timeout_ms": 15000,
      "shutdown_timeout_ms": 10000,
      "post_close_timeout_ms": 5000
    },
    "gpu_monitor": {
      "poll_interval_ms": 5000,
      "poll_timeout_ms": 3000,
      "backend": "auto",
      "thresholds": {
        "temperature_c": 85.0,
        "mem_percent": 95.0
      }
    },
    "coordinator": {
      "startup_timeout_ms": 120000,
      "drain_timeout_ms": 30000,
      "max_concurrent": 64
    },
    "engine_sup": {
      "max_restarts": 5,
      "max_period": 60
    }
  },
  "server": {
    "port": 8080,
    "ip": "0.0.0.0",
    "max_connections": 1024,
    "max_body_size": 10485760,
    "inactivity_timeout": 60000,
    "generate_timeout": 5000
  }
}
```

### Engine Fields

| Field | Required | Type | Default | Description |
|-------|----------|------|---------|-------------|
| `name` | yes | string | — | Engine identifier. Must match `^[a-zA-Z0-9_-]+$`, max 64 chars. Maps to `engine_id`. |
| `backend` | yes | string | — | `"vllm"`, `"mlx"`, `"tensorrt"`. Determines adapter auto-resolution. |
| `model` | yes | string | — | Model identifier (e.g., HuggingFace model name). |
| `gpu_ids` | no | list of int | `[]` | GPU indices to monitor. |
| `tp_size` | no | int | `1` | Tensor parallelism degree. |
| `adapter_cmd` | no | string | auto-resolved | Override adapter executable path. Takes precedence over `backend` auto-resolution. |
| `port` | no | object | `{}` | Per-engine port timeout overrides. |
| `gpu_monitor` | no | object | `{}` | Per-engine GPU monitor overrides. |
| `coordinator` | no | object | `{}` | Per-engine coordinator overrides. |

### Defaults Section

Global defaults for all engines. Each sub-section corresponds to a component:

- **`port`** — Port subprocess timeouts and buffer sizes.
- **`gpu_monitor`** — GPU polling intervals, timeouts, backend selection, alert thresholds.
- **`coordinator`** — Engine coordinator startup, drain, and concurrency settings.
- **`engine_sup`** — Supervisor restart intensity/period.

### Server Section

HTTP server configuration. All fields optional with hardcoded defaults.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | int | `8080` | HTTP listening port. |
| `ip` | string | `"0.0.0.0"` | Bind IP address. |
| `max_connections` | int | `1024` | Cowboy max concurrent connections. |
| `max_body_size` | int | `10485760` | Max request body (bytes). |
| `inactivity_timeout` | int | `60000` | Stream inactivity timeout (ms). |
| `generate_timeout` | int | `5000` | Engine generate call timeout (ms). |

### Minimal Valid Config

```json
{
  "engines": [
    { "name": "my-model", "backend": "vllm", "model": "Qwen/Qwen2.5-1.5B-Instruct", "gpu_ids": [0] }
  ]
}
```

Everything else uses hardcoded defaults.

---

## Module API

### Public Functions

```erlang
%% Load and validate config from JSON file. Creates/replaces ETS table.
%% Called once from loom_app:start/2 before supervisor tree.
-spec load(file:filename()) -> ok | {error, term()}.

%% Load with default path (config/loom.json).
-spec load() -> ok | {error, term()}.

%% Get nested config value with default.
%% Example: loom_config:get([server, port], 8080).
-spec get(list(atom()), term()) -> term().

%% Get fully merged engine config map.
%% Returns map ready to pass to loom_engine_sup:start_link/1.
-spec get_engine(binary()) -> {ok, map()} | {error, not_found}.

%% Get list of all engine names.
-spec engine_names() -> [binary()].

%% Get server config map (merged with hardcoded defaults).
-spec get_server() -> map().
```

### ETS Storage

Named table `loom_config`, `set`, `{read_concurrency, true}`, `public`:

| Key | Value | Purpose |
|-----|-------|---------|
| `{config, parsed}` | Full parsed map | For `get/2` nested path access |
| `{engine, Name}` | Pre-merged engine map | For `get_engine/1` — no merge on read |
| `{server, config}` | Pre-merged server map | For `get_server/0` |

Pre-merging at load time means every read is a single `ets:lookup` — no merge logic on the hot path.

### Adapter Resolution

Adapter command is auto-resolved from `backend` unless `adapter_cmd` is explicitly provided:

| Backend | Resolved Path |
|---------|--------------|
| `"vllm"` | `<priv_dir>/python/loom_adapter.py` |
| `"mlx"` | `<priv_dir>/python/loom_adapter_mlx.py` |
| `"tensorrt"` | `<priv_dir>/python/loom_adapter_trt.py` |

If both `backend` and `adapter_cmd` are present, `adapter_cmd` wins.

### Merge Precedence

```
per-engine section  >  defaults section  >  hardcoded defaults in code
```

Merge is deep for nested maps (e.g., `thresholds`), shallow for scalar values.

---

## Startup Flow (covers #12 integration)

```
1. loom_app:start/2
   │
   ├── loom_config:load()              ← Read & validate JSON, populate ETS
   │   └── Fail fast if invalid        ← Application refuses to start
   │
   └── loom_sup:start_link()           ← Root supervisor starts
       │
       ├── loom_engine_sup (child 1)   ← For each engine in loom_config:engine_names()
       │   ├── loom_engine_coordinator
       │   └── loom_gpu_monitor × N
       │
       └── loom_http (child 2)         ← Cowboy listener, reads loom_config:get_server()
```

### Key Decisions

1. **Config loads before supervisor tree.** `loom_config:load()` runs in `loom_app:start/2`, before `loom_sup:start_link()`. Invalid config → application refuses to start. No half-started state.

2. **Engine start order.** Engines start sequentially in JSON list order. First engine claims VRAM before second starts, preventing GPU memory race conditions.

3. **HTTP starts after engines.** Cowboy listener is the last child. Endpoints only become available once engines are initializing.

4. **`sys.config` reduced.** Only holds OTP-level settings (SASL, node config). All Loom-specific config in `loom.json`. Optionally `{loom, [{config_path, "path/to/loom.json"}]}` to override default path.

5. **`loom_sup` stays `one_for_one`.** Engine crash → only that engine's subtree restarts, HTTP stays up. HTTP crash → Cowboy restarts, engines unaffected.

---

## Validation

On `load/1`, fail fast with structured errors:

| Condition | Error |
|-----------|-------|
| File not found | `{error, {config_file, enoent, Path}}` |
| Invalid JSON | `{error, {json_parse, Reason}}` |
| Missing required field | `{error, {validation, {missing_field, engines, name}}}` |
| Duplicate engine name | `{error, {validation, {duplicate_engine, Name}}}` |
| Invalid engine name | `{error, {validation, {invalid_engine_name, Name}}}` |
| Bad type | `{error, {validation, {invalid_type, Path, ExpectedType}}}` |
| Unknown backend (no adapter_cmd) | `{error, {validation, {unknown_backend, Backend, engine, Name}}}` |
| Adapter not found on disk | `{error, {validation, {adapter_not_found, Path, engine, Name}}}` |

Adapter existence is verified at load time, not at engine startup. Fail fast.

---

## Error Handling

- **Config file missing:** `{error, {config_file, enoent, Path}}`. Application refuses to start. No silent fallback.
- **Invalid JSON:** `{error, {json_parse, Reason}}`.
- **Validation errors:** Structured, pattern-matchable tuples. First error stops loading.
- **Adapter not found:** Checked at config load time. Prevents engines from starting with a bad adapter path.

---

## Testing Strategy

### EUnit (pure function logic)

- JSON parsing: valid, malformed, empty
- Merge logic: hardcoded < defaults < per-engine, partial overrides, missing sections
- Validation: missing required fields, bad types, duplicate names, invalid engine name patterns
- Adapter resolution: each backend, custom adapter_cmd, override precedence, unknown backend
- `get/2`: nested path access, missing keys with defaults, deep nesting
- `get_engine/1`: existing engine, missing engine, correct merge result
- `get_server/0`: with and without server section

### Common Test (ETS integration)

- Full load → get cycle: load file, read back all values
- Multiple engines: each gets correct merged config
- ETS table lifecycle: created on load, survives across calls
- Concurrent reads: multiple processes reading simultaneously
- Reload: calling `load/1` again replaces config cleanly

---

## Out of Scope

- Hot config reload (Phase 2, #32)
- Environment variable interpolation in JSON
- YAML support (deferred, JSON sufficient)
- Config file watching / inotify (Phase 2+)

---

## Assumptions

- **ASSUMPTION:** OTP 27's `json:decode/1` is sufficient for parsing. No external JSON library needed.
- **ASSUMPTION:** Config is immutable after load. No runtime mutation until Phase 2.
- **ASSUMPTION:** Adapter Python files exist under `priv/python/` in the release. Build/packaging ensures this.
- **ASSUMPTION:** Engine names in JSON use hyphens and dots (`qwen2.5-1.5b`) but are valid as binary `engine_id` values. The existing `^[a-zA-Z0-9_]+$` regex in `loom_engine_sup` and `loom_engine_coordinator` needs updating to `^[a-zA-Z0-9._-]+$` to allow hyphens and dots, matching the README examples.
