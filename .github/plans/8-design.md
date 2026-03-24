# P0-07: `loom_gpu_monitor` GenServer — Design Spec

> GitHub Issue: [#8](https://github.com/mohansharma-me/loom/issues/8)

## Summary

A platform-aware GPU health monitoring GenServer that polls hardware metrics at configurable intervals. Uses a behaviour + backend pattern to support NVIDIA GPUs (Linux/Windows), Apple Silicon unified memory (macOS ARM64), and a mock backend for development/CI.

## Architecture

### `loom_gpu_backend` Behaviour

Defines the contract all platform backends implement:

```erlang
-callback detect() -> boolean().
-callback init(Opts :: map()) -> {ok, State :: term()} | {error, term()}.
-callback poll(State :: term()) -> {ok, metrics(), NewState :: term()} | {error, term()}.
-callback terminate(State :: term()) -> ok.
```

`terminate/1` allows backends to clean up resources (e.g., a future NIF-based NVML backend could close handles).

Normalized metrics map returned by all backends:

```erlang
-type metrics() :: #{
    gpu_util       := float(),            %% 0.0-100.0, or -1.0 if unavailable
    mem_used_gb    := float(),
    mem_total_gb   := float(),
    temperature_c  := float(),            %% or -1.0 if unavailable
    power_w        := float(),            %% or -1.0 if unavailable
    ecc_errors     := integer()            %% 0+ or -1 if unavailable
}.
```

All keys use `:=` (required) so Dialyzer enforces that every backend returns the full map shape.

Fields use `-1.0` / `-1` for unavailable values so downstream code can always pattern match on the full map shape without guarding for `undefined`.

### Backend Implementations

#### `loom_gpu_backend_nvidia`

- **Platforms:** Linux, Windows (also macOS if NVIDIA eGPU present)
- **Detection:** `detect/0` runs `which nvidia-smi` (Unix) or `where nvidia-smi` (Windows) via `os:cmd/1`. Users with non-standard `nvidia-smi` paths can bypass detection by setting `backend => nvidia` explicitly and passing `nvidia_smi_path` in init options
- **Init:** Takes `#{gpu_index => N}`, validates GPU exists via a test query
- **Poll:** Runs `nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,ecc.errors.corrected.aggregate.total --id=N --format=csv,noheader,nounits`
- **Parsing:** `parse_nvidia_csv/1` — pure function, independently testable with hardcoded strings
- **Metrics:** All fields populated

#### `loom_gpu_backend_apple`

- **Platforms:** macOS ARM64 (Apple Silicon)
- **Detection:** `detect/0` confirms all three:
  1. `os:type() =:= {unix, darwin}`
  2. `os:cmd("sysctl -n hw.optional.arm64")` returns `"1"` (confirms ARM64)
  3. `sysctl` and `vm_stat` commands available
- **Init:** No GPU index concept (unified memory). Validates commands are accessible
- **Poll:** Runs `sysctl hw.memsize` (total) and `vm_stat` (page statistics). Computes used/total from page stats and page size
- **Parsing:** `parse_sysctl/1` and `parse_vm_stat/1` — pure functions, independently testable
- **Metrics:** `mem_used_gb` and `mem_total_gb` populated. `gpu_util`, `temperature_c`, `power_w` = `-1.0`, `ecc_errors` = `-1` (no public Metal API for these)

#### `loom_gpu_backend_mock`

- **Platforms:** Any (fallback, gated by feature flag)
- **Detection:** Always returns `true`
- **Init:** Accepts optional `#{metrics => MetricsMap}` to configure static return values. Defaults to healthy readings
- **Poll:** Returns configured static metrics unchanged
- **Feature flag:** Only selected if `allow_mock_backend => true` in options. In production (`allow_mock_backend => false`), if no real backend is detected, `loom_gpu_monitor` refuses to start with `{error, no_gpu_backend_detected}`
- **No thresholds:** Mock backend has no default thresholds

### Auto-Detection

Detection cascade in `loom_gpu_monitor`:

```
1. nvidia:  nvidia-smi found? (Linux/Windows/macOS)
2. apple:   macOS + ARM64 + sysctl/vm_stat available?
3. mock:    allow_mock_backend == true? -> use mock
4. error:   {error, no_gpu_backend_detected}
```

When backend is set explicitly (not `auto`), detection is skipped — the specified module is used directly.

**Logging during detection:** Each step in the cascade logs its outcome at INFO level so operators can trace exactly why a backend was selected:

```
[info] loom_gpu_monitor: auto-detecting backend for gpu_id=0
[info] loom_gpu_monitor: trying nvidia backend — nvidia-smi not found on PATH
[info] loom_gpu_monitor: trying apple backend — os=darwin, arm64=true, sysctl=ok, vm_stat=ok
[info] loom_gpu_monitor: selected backend=loom_gpu_backend_apple for gpu_id=0
```

When a backend is set explicitly:

```
[info] loom_gpu_monitor: using explicitly configured backend=nvidia for gpu_id=0
```

### `loom_gpu_monitor` GenServer

Backend-agnostic GenServer that owns the poll loop, caches metrics, checks thresholds, and emits alerts.

#### State

```erlang
-record(data, {
    gpu_id             :: term(),
    backend_mod        :: module(),
    backend_state      :: term(),
    poll_interval_ms   :: pos_integer(),       %% default 5000
    timer_ref          :: reference() | undefined,
    latest_metrics     :: loom_gpu_backend:metrics() | undefined,
    thresholds         :: #{atom() => number()},
    breached           :: #{atom() => boolean()},
    consecutive_errors :: non_neg_integer(),
    poll_timeout_ms    :: pos_integer(),       %% default 3000, must be < poll_interval_ms
    coordinator_pid    :: pid() | undefined
}).
```

#### API

```erlang
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
-spec get_status(pid()) -> {ok, loom_gpu_backend:metrics()} | {error, no_reading}.
-spec force_poll(pid()) -> {ok, loom_gpu_backend:metrics()} | {error, term()}.
-spec stop(pid()) -> ok.
```

`force_poll/1` triggers an immediate synchronous poll outside the timer cycle — useful for tests (deterministic timing) and operational use (fresh reading on demand).

Options map for `start_link/1`:

```erlang
#{
    gpu_id             => 0,                                        %% required
    backend            => auto | nvidia | apple | mock,             %% default: auto
    poll_interval_ms   => 5000,                                     %% default
    thresholds         => #{temperature_c => 85.0, mem_percent => 95.0},
    coordinator        => CoordinatorPid,                           %% optional
    allow_mock_backend => true                                      %% default: true (dev)
}
```

#### Lifecycle

1. **init/1** — Resolve backend (auto-detect or explicit), call `BackendMod:init(Opts)`, start first poll timer via `erlang:send_after/3`
2. **handle_info(poll, Data)** — Call `BackendMod:poll(BackendState)`, store metrics, check thresholds, log metrics, schedule next timer
3. **handle_call(get_status, ...)** — Return `latest_metrics` from state
4. **terminate/2** — Cancel timer, call `BackendMod:terminate(BackendState)`, clean up

**Lifecycle logging:**

```
[info] loom_gpu_monitor: starting gpu_id=0 backend=loom_gpu_backend_apple poll_interval=5000ms poll_timeout=3000ms
[info] loom_gpu_monitor: backend init succeeded for gpu_id=0, scheduling first poll
[info] loom_gpu_monitor: gpu_id=0 stopping, reason=shutdown
```

On init failure:

```
[error] loom_gpu_monitor: backend init failed for gpu_id=0 backend=loom_gpu_backend_nvidia reason={error, gpu_index_not_found}
```

#### Threshold Checking

After each poll, compare metrics against thresholds. Alert only on **transitions** (healthy -> breached), not every poll — prevents flooding the coordinator. Track breach state in `breached` map.

Alert message to coordinator:

```erlang
{gpu_alert, GpuId, AlertType, Value, Threshold}
%% AlertType :: temperature | memory
```

`mem_percent` is not stored in the `metrics()` map — it is computed during threshold checking as `(mem_used_gb / mem_total_gb) * 100.0`.

Default thresholds by backend:
- **NVIDIA:** `#{temperature_c => 85.0, mem_percent => 95.0}`
- **Apple:** `#{mem_percent => 90.0}` (lower because unified memory pressure affects whole system)
- **Mock:** no thresholds (empty map)

All overridable via the options map.

**Threshold logging:** Every transition is logged at INFO with before/after state:

```
[info] loom_gpu_monitor: gpu_id=0 threshold BREACHED — memory=96.2% (threshold=95.0%), alerting coordinator
[info] loom_gpu_monitor: gpu_id=0 threshold CLEARED — memory=83.1% (threshold=95.0%)
[info] loom_gpu_monitor: gpu_id=0 threshold BREACHED — temperature=87.3C (threshold=85.0C), alerting coordinator
```

When coordinator is not configured:

```
[warning] loom_gpu_monitor: gpu_id=0 threshold breached but no coordinator configured, alert not sent
```

#### Error Handling

**Poll failure:**
- Log warning with reason
- Keep `latest_metrics` unchanged (stale is better than nothing)
- Increment `consecutive_errors` counter
- After 3 consecutive failures, alert coordinator: `{gpu_alert, GpuId, poll_failure, ConsecutiveErrors, 3}`
- Reset counter on next successful poll

**Poll failure logging:**

```
[warning] loom_gpu_monitor: gpu_id=0 poll failed — reason=timeout, consecutive_errors=1, serving stale metrics
[warning] loom_gpu_monitor: gpu_id=0 poll failed — reason={parse_error, "unexpected output"}, consecutive_errors=2, serving stale metrics
[error] loom_gpu_monitor: gpu_id=0 poll failed 3 consecutive times — reason=timeout, alerting coordinator
[info] loom_gpu_monitor: gpu_id=0 poll recovered after 3 consecutive failures, resetting error counter
```

**Command timeout:**
Each backend's `poll/1` uses `open_port({spawn_executable, Path}, ...)` with a timer instead of `os:cmd/1`. This gives proper OS process lifecycle control — if the timer fires, `port_close/1` kills the OS subprocess cleanly. `os:cmd/1` would orphan the subprocess on Erlang process kill.

Configuration: `poll_timeout_ms` (default 3000ms) in the options map, also stored in `#data{}`. Must be less than `poll_interval_ms` to prevent overlapping polls — validated in `init/1`.

**Timeout logging:**

```
[warning] loom_gpu_monitor: gpu_id=0 poll command timed out after 3000ms, killing subprocess
```

#### Telemetry

Log structured metrics via `logger:info` on each successful poll with all available fields. Full `telemetry` / Prometheus integration is tracked separately in P1-09 (#25). Data is always available via `get_status/1`.

```
[info] loom_gpu_monitor: gpu_id=0 poll ok — gpu_util=73.0% mem=62.4/80.0GB(78.0%) temp=71.0C power=245.3W ecc=0
[info] loom_gpu_monitor: gpu_id=0 poll ok — gpu_util=n/a mem=12.1/16.0GB(75.6%) temp=n/a power=n/a ecc=n/a
```

Fields with value `-1.0` / `-1` are rendered as `n/a` in logs for readability.

## Supervision

Per KNOWLEDGE.md, `loom_gpu_monitor` sits under `loom_engine_sup` (rest_for_one):

```
loom_engine_sup (rest_for_one)
├── loom_engine_coordinator
├── loom_gpu_monitor:gpu_0
└── loom_gpu_monitor:gpu_1
```

For Phase 0, the monitor can be started standalone or added to `loom_sup` directly until `loom_engine_sup` is implemented in P0-09.

**Coordinator PID resolution:** In the final supervision tree (`rest_for_one`), when the coordinator crashes and restarts with a new PID, monitors are also restarted (children after the crashed child). The supervisor passes the coordinator PID to monitor child specs dynamically. The exact wiring is deferred to P0-09 (`loom_engine_sup`). For Phase 0, `coordinator_pid` is optional and set at init time.

## Testing Strategy

| Layer | Test Type | What It Tests |
|-------|-----------|---------------|
| `loom_gpu_backend_nvidia` | EUnit | `parse_nvidia_csv/1` with hardcoded CSV — normal, missing fields, malformed input |
| `loom_gpu_backend_apple` | EUnit | `parse_sysctl/1` and `parse_vm_stat/1` with sample output strings |
| `loom_gpu_backend_mock` | EUnit | Returns configured/default metrics, handles missing options |
| `loom_gpu_monitor` | CT | Full lifecycle with mock backend — poll cycle, `get_status/1`, `force_poll/1`, threshold transitions, coordinator alerts, consecutive error handling |

Parse functions are the critical unit-test surface. GenServer integration tests use mock backend so they run on any platform including CI.

## Files

| File | Purpose |
|------|---------|
| `src/loom_gpu_backend.erl` | Behaviour definition + `metrics()` type export |
| `src/loom_gpu_backend_nvidia.erl` | NVIDIA backend (nvidia-smi) |
| `src/loom_gpu_backend_apple.erl` | Apple Silicon backend (sysctl/vm_stat) |
| `src/loom_gpu_backend_mock.erl` | Mock backend for dev/CI |
| `src/loom_gpu_monitor.erl` | GenServer — poll loop, thresholds, alerts |
| `test/loom_gpu_backend_nvidia_tests.erl` | EUnit — nvidia CSV parsing |
| `test/loom_gpu_backend_apple_tests.erl` | EUnit — sysctl/vm_stat parsing |
| `test/loom_gpu_backend_mock_tests.erl` | EUnit — returns configured/default metrics |
| `test/loom_gpu_monitor_SUITE.erl` | CT — full lifecycle with mock backend |

## Coding Standards

- All exported and internal functions in source modules require `-spec` annotations (`rebar.config` enforces `warn_missing_spec` + `warnings_as_errors`). Test modules use `nowarn_missing_spec` per the test profile.
- All modules follow the `loom_` prefix convention with `%%%---` bordered headers matching `loom_port.erl` style.
- Design decisions and contracts documented with `%% ASSUMPTION:` comments.

## Assumptions

- `nvidia-smi` CSV output format is stable across driver versions (NVIDIA documents this as a supported interface)
- `vm_stat` output format on macOS is stable (has been consistent since macOS 10.x)
- `sysctl hw.optional.arm64` reliably distinguishes Apple Silicon from Intel Macs
- Poll interval of 5s is frequent enough for health monitoring without adding meaningful system load
- Unified memory on Apple Silicon warrants a lower memory threshold (90%) than discrete VRAM (95%) due to system-wide impact
- The `allow_mock_backend` feature flag defaults to `true` during development and will be flipped to `false` before production release
