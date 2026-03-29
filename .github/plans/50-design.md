# Design Plan: CC-02 — Structured Logging & Observability (#50)

## Overview

Establish logging standards, add JSON log formatting for production, propagate request IDs end-to-end, set process-level metadata on all long-lived processes, retrofit all 84 existing log statements to consistent structured format, and instrument existing modules with telemetry events.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Scope | Foundation + Retrofit all modules | AI agents pattern-match on existing code; all logs must follow new conventions |
| Telemetry | Add dependency + instrument existing modules | Events should be emitting before #25 (Prometheus) lands |
| Log format | Map-only structured metadata | Consistent, machine-parseable, works with both dev and JSON formatters |
| Process metadata | `logger:set_process_metadata/1` on init | Automatic context injection, no need to pass engine_id/request_id per call |
| Request ID | HTTP request_id flows through to coordinator | End-to-end tracing across process boundaries |

## Logger Configuration

### Dev Mode (`config/sys.config`)

OTP default handler with single-line template format, human-readable. No custom formatter needed.

### Prod Mode (`config/sys.config.src`)

Custom JSON formatter module (`loom_log_formatter`) configured as the default handler's formatter:

```erlang
{kernel, [
    {logger, [
        {handler, default, logger_std_h, #{
            formatter => {loom_log_formatter, #{}}
        }}
    ]}
]}
```

## Process-Level Metadata Convention

Every long-lived process sets metadata in `init`:

| Process | Metadata |
|---------|----------|
| `loom_engine_coordinator` | `#{engine_id => Id}` |
| `loom_gpu_monitor` | `#{engine_id => Id, gpu_id => GpuId}` |
| HTTP handlers (per-request) | `#{request_id => ReqId}` (set in middleware) |

All `?LOG_*` calls in these processes automatically include the metadata without explicit passing.

## Request ID Propagation

Current: HTTP middleware generates `request_id`, passes in cowboy_req map. Engine coordinator generates a separate internal request ID.

New flow:
```
HTTP middleware → handler → coordinator → port → adapter
     req-abc123    req-abc123   req-abc123 + engine-req-456
```

- HTTP `request_id` passed as part of the generation request to coordinator
- Coordinator logs both `request_id` (external, for end-to-end tracing) and `engine_request_id` (internal, for port protocol correlation)
- Both IDs appear in structured log metadata

## Log Statement Standards

All log statements use map-only format:

```erlang
%% BEFORE (mixed formats):
?LOG_WARNING("Engine ~s port error during startup: ~p", [EngineId, Error], #{engine_id => EngineId})

%% AFTER (map-only):
?LOG_WARNING(#{msg => port_error_during_startup, engine_id => EngineId, error => Error})
```

Required metadata fields by context:

| Context | Required Fields |
|---------|----------------|
| Engine processes | `msg`, `engine_id` |
| HTTP handlers | `msg`, `request_id`, `method`, `path` |
| GPU monitors | `msg`, `engine_id`, `gpu_id` |
| Application lifecycle | `msg` |

## `loom_log_formatter` Module

New module implementing `logger:formatter()` behaviour (`format/2` + `check_config/1`):

- Outputs one JSON object per line: `{"time":"ISO8601","level":"info","msg":"engine_started","engine_id":"e1",...}`
- Merges process metadata + per-call metadata
- Flattens nested maps using underscore-joined keys (e.g., `#{error => #{reason => timeout}}` becomes `error_reason => timeout`) for log aggregator compatibility
- Handles all OTP log event formats (string, report, format+args)

## Telemetry Integration

### Dependency

Add `telemetry` to main deps in `rebar.config` (runtime concern, not test-only).

### Event Catalog

Naming convention: `[loom, component, metric]`

| Event | Measurements | Metadata | Instrumented In |
|-------|-------------|----------|-----------------|
| `[loom, http, request_start]` | `system_time` | `method, path, request_id` | `loom_http_middleware` |
| `[loom, http, request_stop]` | `duration` | `method, path, request_id, status` | `loom_http_middleware` |
| `[loom, engine, generate_start]` | `system_time` | `engine_id, request_id` | `loom_engine_coordinator` |
| `[loom, engine, generate_stop]` | `duration, tokens_generated` | `engine_id, request_id` | `loom_engine_coordinator` |
| `[loom, engine, token]` | `count` (always 1) | `engine_id, request_id` | `loom_engine_coordinator` |
| `[loom, engine, state_change]` | `system_time` | `engine_id, old_state, new_state` | `loom_engine_coordinator` |
| `[loom, gpu, poll]` | `gpu_util, mem_used_gb, mem_total_gb, temperature_c` | `engine_id, gpu_id` | `loom_gpu_monitor` |
| `[loom, port, message_in]` | `byte_size` | `engine_id` | `loom_port` |
| `[loom, port, message_out]` | `byte_size` | `engine_id` | `loom_port` |

When #25 (`loom_metrics` + Prometheus) lands, it attaches handlers to these already-emitting events.

## Files to Create

- `src/loom_log_formatter.erl` — JSON log formatter for production

## Files to Modify

- `rebar.config` — add `telemetry` dependency
- `src/loom.app.src` — add `telemetry` to applications list
- `config/sys.config` — add explicit logger handler config (dev)
- `config/sys.config.src` — add logger config with JSON formatter (prod)
- All 13 source files with existing log statements — retrofit to map-only format
- ~8 modules — add `telemetry:execute/3` instrumentation
- `loom_engine_coordinator` — accept and log external `request_id`
- `loom_http_middleware` — set process metadata, pass request_id downstream
