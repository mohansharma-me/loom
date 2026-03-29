# Design: P0-10 / P0-16 — HTTP API Layer (OpenAI + Anthropic)

> Covers #11 (`/v1/chat/completions`) and #64 (`/v1/messages`)

## Overview

HTTP API layer using Cowboy that exposes OpenAI- and Anthropic-compatible inference endpoints with SSE streaming support. Clients can point any OpenAI or Anthropic SDK at Loom without changes.

## Module Structure

| Module | Type | Purpose |
|--------|------|---------|
| `loom_http` | Application setup | Starts Cowboy listener, configures routes |
| `loom_http_middleware` | Cowboy middleware | Request ID, content-type validation, request logging |
| `loom_handler_chat` | `cowboy_loop` | `POST /v1/chat/completions` — OpenAI format |
| `loom_handler_messages` | `cowboy_loop` | `POST /v1/messages` — Anthropic format |
| `loom_handler_health` | `cowboy_handler` | `GET /health` — engine status |
| `loom_handler_models` | `cowboy_handler` | `GET /v1/models` — loaded models |
| `loom_http_util` | Pure functions | Request ID generation, common helpers |
| `loom_format_openai` | Pure functions | OpenAI request parsing, response/SSE/error formatting |
| `loom_format_anthropic` | Pure functions | Anthropic request parsing, response/SSE/error formatting |

## Routing

```
POST /v1/chat/completions  →  loom_handler_chat
POST /v1/messages          →  loom_handler_messages
GET  /health               →  loom_handler_health
GET  /v1/models            →  loom_handler_models
```

Cowboy middleware pipeline (order matters):
```erlang
middlewares => [cowboy_router, loom_http_middleware, cowboy_handler]
```

## Request Flow

```
Client HTTP Request
  → Cowboy accepts connection
  → loom_http_middleware (request ID, content-type check, logging)
  → Handler init/2 (parse request via format module)
  → ETS lookup for coordinator pid (loom_coord_meta_<engine_id> table)
  → loom_engine_coordinator:generate(Pid, Prompt, Params)
      (synchronous gen_statem:call — blocks until coordinator registers
       the request and replies with {ok, RequestId}; call timeout: 5s)
  → Handler returns {cowboy_loop, Req, State, InactivityTimeout}
  → Cowboy loop receives messages:
    → {loom_token, RequestId, Text, Finished}
        → Streaming: format via format module, write SSE chunk
        → Non-streaming: accumulate tokens in list
        → Return {ok, Req, State, InactivityTimeout} to reset timer
    → {loom_done, RequestId, Meta}
        → Streaming: send final event, close connection
        → Non-streaming: concatenate tokens, format full response, send, close
    → {loom_error, RequestId, Code, Msg}
        → Format as API-specific error, send, close
    → timeout (atom, from Cowboy when inactivity timer expires)
        → Stop handler process (triggers coordinator DOWN monitor cleanup)
        → Return 504 Gateway Timeout
```

## Engine Discovery

The coordinator stores its pid as a separate row `{coordinator_pid, self()}` in the `loom_coord_meta_<engine_id>` ETS table during init. HTTP handlers discover the coordinator pid via `ets:lookup(loom_coord_meta_<engine_id>, coordinator_pid)` — no GenServer serialization on the hot path. This is a separate row from the existing `{meta, ...}` tuple to avoid breaking existing `ets:update_element` calls.

**ASSUMPTION:** The coordinator's ETS meta table will be extended with a `{coordinator_pid, Pid}` row. This requires a small change to `loom_engine_coordinator:init/1`.

For Phase 0, the `engine_id` is configured in `sys.config` (default `<<"engine_0">>`). Replaced by registry-based lookup in Phase 1.

The `generate/3` call must be wrapped in `try/catch` for `exit:{noproc, _}` to handle the race where the coordinator dies between ETS lookup and the call. This maps to 503.

## Middleware

`loom_http_middleware` implements `cowboy_middleware` behaviour (`execute/2`). Runs after `cowboy_router`, before `cowboy_handler`.

**Responsibilities:**
1. **Request ID** — Generate `req-<uuid>`, attach as `x-request-id` response header, store in `Req` metadata for handler access.
2. **Content-Type validation** — POST requests must include `application/json`. Reject with 415 and generic JSON error body: `{"error": {"message": "Content-Type must be application/json", "type": "invalid_request_error"}}`. (Generic format because middleware runs before routing and cannot know the target API format.) GET requests pass through.
3. **Request logging** — Log method, path, request ID at request start.

Error formatting is NOT in the middleware — Cowboy middleware runs pre-handler only. Error formatting lives in handlers via `loom_format_openai:format_error/2` and `loom_format_anthropic:format_error/2`.

## Streaming (SSE)

Both streaming handlers use `cowboy_loop` to receive `{loom_token, ...}` messages asynchronously.

### SSE Format — OpenAI

Token event:
```
data: {"id":"chatcmpl-<req_id>","object":"chat.completion.chunk","created":<unix_ts>,"model":"<model>","choices":[{"index":0,"delta":{"content":"<token>"},"finish_reason":null}]}

```

Done event:
```
data: [DONE]

```

### SSE Format — Anthropic

Start event:
```
event: message_start
data: {"type":"message_start","message":{"id":"msg_<req_id>","type":"message","role":"assistant","content":[],"model":"<model>","usage":{"input_tokens":0}}}

```

Content block start:
```
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

```

Token event:
```
event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"<token>"}}

```

Content block stop:
```
event: content_block_stop
data: {"type":"content_block_stop","index":0}

```

Message delta (before stop):
```
event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":<count>}}

```

Done event:
```
event: message_stop
data: {"type":"message_stop"}

```

### SSE Event Sequence — Anthropic

`message_start` → `content_block_start` → N × `content_block_delta` → `content_block_stop` → `message_delta` → `message_stop`

## Non-Streaming

Same receive loop as streaming, but tokens accumulate in a list. On `{loom_done, ...}`, concatenate all tokens and return a single JSON response in the appropriate API format.

Both OpenAI and Anthropic non-streaming responses include a `usage` object. The coordinator provides `completion_tokens` (from `{loom_done, _, #{tokens := Count}}`). `prompt_tokens` is set to 0 in Phase 0 — accurate prompt token counting requires tokenizer integration which is out of scope.

## Timeouts

### Inactivity Timeout (Cowboy-native)

Uses Cowboy's built-in `cowboy_loop` timeout mechanism:
1. `init/2` returns `{cowboy_loop, Req, State, Timeout}` to set initial timeout.
2. Each `info/3` handling a `{loom_token, ...}` returns `{ok, Req, NewState, Timeout}` (4-tuple) to reset the timer.
3. When the timer expires, Cowboy calls `info/3` with the atom `timeout`.
4. The timeout handler stops the process (returns `{stop, Req, State}`), which triggers the coordinator's `DOWN` monitor for cleanup.
5. Before stopping, send 504 response (if headers not yet sent) or close the stream.

Default: 60s, configurable via `sys.config`.

### Generate Call Timeout

`loom_engine_coordinator:generate/3` is a synchronous `gen_statem:call`. The existing `generate/3` wrapper does not accept a timeout parameter, so either:
- Add `generate/4` with an explicit timeout to the coordinator API, or
- The handler calls `gen_statem:call(Pid, {generate, Prompt, Params}, Timeout)` directly.

Preferred: add `generate/4` to keep the coordinator API as the single entry point. Default 5s, configurable via `sys.config` `generate_timeout`. On timeout, return 504.

## Client Disconnect & Cancellation

Cowboy terminates the handler process when the client disconnects. The coordinator monitors the calling process — handler process death triggers the coordinator's `DOWN` monitor, which automatically cancels the in-flight request and frees engine resources. No explicit cancel message needed.

Same mechanism handles inactivity timeout: handler process stops → coordinator `DOWN` fires → cleanup.

## Error Handling

### Pre-stream errors (HTTP status code available)

| Coordinator Response | HTTP Status | When |
|---------------------|-------------|------|
| `{error, not_ready}` | 503 Service Unavailable | Engine still loading |
| `{error, overloaded}` | 429 Too Many Requests | At max concurrent |
| `{error, draining}` | 503 Service Unavailable | Engine shutting down |
| `{error, stopped}` | 503 Service Unavailable | Engine dead |
| `exit:{noproc, _}` | 503 Service Unavailable | Coordinator died between lookup and call |
| `gen_statem:call` timeout | 504 Gateway Timeout | Coordinator unresponsive |
| Bad request body | 400 Bad Request | Missing/invalid fields |
| Coordinator not in ETS | 503 Service Unavailable | No engine available |

### Mid-stream errors (SSE headers already sent)

Cannot change HTTP status. Send error as SSE event:
- OpenAI: `data: {"error": {"message": "...", "type": "server_error"}}` then close
- Anthropic: `event: error` with `{"type": "error", "error": {...}}` then close

### Error format — OpenAI
```json
{"error": {"message": "Engine unavailable", "type": "server_error", "code": "engine_unavailable"}}
```

### Error format — Anthropic
```json
{"type": "error", "error": {"type": "overloaded_error", "message": "Engine at max capacity"}}
```

## Configuration

All HTTP config in `sys.config` under `{loom, [{http, #{...}}]}`:

```erlang
#{
    port => 8080,                %% listen port (default 8080)
    ip => {0, 0, 0, 0},         %% bind address (default all interfaces)
    max_connections => 1024,     %% cowboy connection limit (default 1024)
    max_body_size => 10485760,   %% max request body in bytes (default 10MB)
    inactivity_timeout => 60000, %% ms, token inactivity before 504 (default 60000)
    generate_timeout => 5000,    %% ms, gen_statem:call timeout for generate (default 5000)
    engine_id => <<"engine_0">>  %% coordinator to look up in ETS (default <<"engine_0">>)
}
```

All keys optional — `loom_http` merges with defaults on startup.

## Testing Strategy

### EUnit (pure functions)
- `loom_format_openai` — request parsing, response formatting, SSE encoding, error formatting
- `loom_format_anthropic` — same coverage for Anthropic format (including full event sequence)
- `loom_http_util` — request ID generation, helpers

### Common Test (full HTTP round-trips)

**Mock coordinator:** A `gen_statem` that registers its pid in ETS and sends predetermined token sequences to callers. Configurable for errors, delays, overload simulation. Reusable across all handler suites.

- `loom_handler_chat_SUITE`:
  - Non-streaming: POST → collect response → verify OpenAI format
  - Streaming: POST with `stream: true` → receive SSE → verify format/ordering
  - Errors: 400 (bad body), 429 (overloaded), 503 (engine down), 504 (inactivity timeout)
  - Client disconnect: start stream, close connection, verify coordinator DOWN fires

- `loom_handler_messages_SUITE`:
  - Non-streaming: POST → verify Anthropic response format
  - Streaming: verify full event sequence (`message_start` → `content_block_start` → deltas → `content_block_stop` → `message_delta` → `message_stop`)
  - Errors: mapped to Anthropic error types
  - Client disconnect

- `loom_handler_health_SUITE`: returns engine status from ETS
- `loom_handler_models_SUITE`: returns loaded model list from ETS
- `loom_http_middleware_SUITE`: request ID attached, content-type rejection (415), request logging

## Assumptions

- **Single engine (Phase 0):** No router — ETS lookup for a single configured `engine_id`.
- **No authentication:** Added in Phase 4 (P4-04).
- **No rate limiting beyond coordinator's `overloaded`:** Per-tenant limits in Phase 4.
- **`loom_config` module does not exist yet (CC-04):** Config read directly from `application:get_env`.
- **Cowboy 2.14.2** already in `rebar.config`.
- **`prompt_tokens` is 0 in Phase 0:** Accurate prompt tokenization requires tokenizer integration, out of scope.
- **No CORS headers:** Browser-based clients are out of scope for Phase 0.
- **Coordinator ETS change required:** `loom_engine_coordinator` must store its pid in the meta ETS table. Small init change.
