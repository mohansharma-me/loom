# Design: loom_protocol — JSON Wire Protocol Codec

**Issue:** [#4 — P0-04](https://github.com/mohansharma-me/loom/issues/4)
**Date:** 2026-03-23
**Status:** Approved

---

## Overview

`loom_protocol` is a pure functional Erlang module that encodes and decodes the line-delimited JSON wire protocol between Erlang (BEAM) and Python inference adapters. It is the single codec boundary — all validation happens here, and all downstream consumers trust decoded messages.

The module produces **tagged tuples** as the canonical internal message representation. This is transport-agnostic: when Phase 4 migrates from stdio/JSON to gRPC/Protobuf, a `loom_grpc` module will produce the same tagged tuples. Zero business logic changes required.

## Architecture Context

```
Phase 0-3:  JSON/stdio  → loom_protocol:decode() → tagged tuples → coordinator, router, etc.
Phase 4+:   Protobuf/gRPC → loom_grpc:decode()   → tagged tuples → coordinator, router, etc.
```

`loom_protocol` uses `loom_json` (existing thin wrapper around Erlang's `json` module) for raw JSON encode/decode. It layers message semantics, validation, and line buffering on top.

---

## Message Types

### Outbound (Erlang → Python)

| Tuple | JSON `type` |
|-------|-------------|
| `{generate, Id, Prompt, Params}` | `"generate"` |
| `{health}` | `"health"` |
| `{memory}` | `"memory"` |
| `{cancel, Id}` | `"cancel"` |
| `{shutdown}` | `"shutdown"` |

- `Id :: binary()` — caller-generated request identifier (e.g., `<<"req-001">>`)
- `Prompt :: binary()` — the prompt text
- `Params :: generate_params()` — optional generation parameters as a map

### Inbound (Python → Erlang)

| Tuple | JSON `type` |
|-------|-------------|
| `{token, Id, TokenId, Text, Finished}` | `"token"` |
| `{done, Id, TokensGenerated, TimeMs}` | `"done"` |
| `{error, Id \| undefined, Code, Message}` | `"error"` |
| `{health_response, Status, GpuUtil, MemUsedGb, MemTotalGb}` | `"health"` |
| `{memory_response, MemoryInfo}` | `"memory"` |
| `{ready, Model, Backend}` | `"ready"` |

Note: inbound `health`/`memory` responses are suffixed `_response` to avoid collision with the outbound command tuples of the same name.

### Field Requirements per Inbound Type

| Type | Required Fields | Notes |
|------|----------------|-------|
| `token` | `id`, `token_id`, `text`, `finished` | |
| `done` | `id`, `tokens_generated`, `time_ms` | |
| `error` | `code`, `message` | `id` is optional (absent or null → `undefined`) |
| `health` | `status`, `gpu_util`, `mem_used_gb`, `mem_total_gb` | All four required |
| `memory` | `total_gb`, `used_gb`, `available_gb` | Additional backend-specific keys allowed |
| `ready` | `model`, `backend` | Sent once on adapter startup, before any commands |

**Error `id` semantics:** When the Python adapter emits an error not tied to a specific request (e.g., malformed JSON), the `id` field is absent from the JSON. On decode, both absent `id` and `null` `id` map to `undefined` in the tagged tuple. On encode (if ever needed), `undefined` omits the `id` key.

**Memory response:** Although `MemoryInfo` is typed as `map()`, decode validates the three required keys (`total_gb`, `used_gb`, `available_gb`) as floats. Extra keys are preserved in the map for backend-specific data.

### Mock Adapter Updates Required

The existing `mock_adapter.py` is incomplete relative to this protocol spec. The implementation plan must include these updates:

- **`health` response:** Add `mem_total_gb` field (currently missing)
- **`error` response:** Add `code` field and `id` field (currently missing)
- **`cancel` handler:** Add handler (no-op, return acknowledgment or ignore)
- **`shutdown` handler:** Add handler (clean exit)

### Outbound Commands Without Acknowledgment

`cancel` and `shutdown` are fire-and-forget in Phase 0. The coordinator detects completion through side effects: `cancel` is confirmed when the engine stops emitting tokens for that `id`; `shutdown` is confirmed by the Port exit status. Explicit acknowledgment messages may be added in later phases if needed.

### Generate Params

```erlang
#{max_tokens => pos_integer(),
  temperature => float(),    %% 0.0-2.0
  top_p => float(),          %% 0.0-1.0
  stop => [binary()]}        %% optional stop sequences
```

All fields are optional. Empty map is valid — Python side applies defaults.

---

## Public API

```erlang
-module(loom_protocol).

%% Encode outbound message to newline-terminated JSON binary
-spec encode(outbound_msg()) -> binary().

%% Decode a complete JSON line to a validated inbound message
-spec decode(binary()) -> {ok, inbound_msg()} | {error, decode_error()}.

%% Line buffer for partial Port reads
-spec new_buffer() -> buffer().
-spec feed(binary(), buffer()) -> {[binary()], buffer()}.
```

### encode/1

Takes a tagged tuple, returns a newline-terminated JSON binary ready to write to Port stdin. No error wrapping — crashes on malformed input (fail fast on programmer error).

### decode/1

Takes a single complete JSON line (no trailing newline), returns `{ok, Msg}` or `{error, Reason}`. Performs full validation: JSON parse, type field, required fields, field types.

### new_buffer/0 and feed/2

Functional line buffer for handling partial reads from Port. `feed/2` appends data to the buffer, splits on `\n`, returns `{CompleteLines, NewBuffer}`. Buffer is opaque (implemented as a binary accumulator).

Usage with Port `{line, MaxLen}` option:

```erlang
handle_info({Port, {data, {eol, Chunk}}}, #{buffer := Buf} = State) ->
    {[Line], NewBuf} = loom_protocol:feed(Chunk, Buf),
    case loom_protocol:decode(Line) of
        {ok, Msg} -> handle_message(Msg, State);
        {error, Reason} -> handle_decode_error(Reason, State)
    end,
    {noreply, State#{buffer := NewBuf}};

handle_info({Port, {data, {noeol, Chunk}}}, #{buffer := Buf} = State) ->
    {[], NewBuf} = loom_protocol:feed(Chunk, Buf),
    {noreply, State#{buffer := NewBuf}}.
```

---

## Validation Strategy

Validation happens **once at decode time** at the protocol boundary. All downstream consumers trust decoded messages.

### What is validated

1. **JSON parse** — malformed JSON → `{error, {invalid_json, Reason}}`
2. **Type field** — missing → `{error, missing_type}`, unknown → `{error, {unknown_type, Type}}`
3. **Required fields** — per message type → `{error, {missing_field, Field, Type}}`
4. **Field types** — e.g., `token_id` must be integer → `{error, {invalid_field, Field, Expected, Got}}`

### What is NOT validated

- **Value ranges** (e.g., `gpu_util` between 0.0-1.0) — business logic, not protocol
- **Optional fields** — absent is fine; present with wrong type is an error
- **Outbound `generate_params`** — trusted internal data, encode path doesn't validate

### Encode path

No validation. Crash on bad input. A malformed tuple from internal code is a bug that should surface immediately.

---

## Type Specs

```erlang
%% Outbound messages
-type generate_params() :: #{
    max_tokens => pos_integer(),
    temperature => float(),
    top_p => float(),
    stop => [binary()]
}.

-type outbound_msg() ::
    {generate, Id :: binary(), Prompt :: binary(), Params :: generate_params()}
  | {health}
  | {memory}
  | {cancel, Id :: binary()}
  | {shutdown}.

%% Inbound messages
-type inbound_msg() ::
    {token, Id :: binary(), TokenId :: non_neg_integer(), Text :: binary(), Finished :: boolean()}
  | {done, Id :: binary(), TokensGenerated :: non_neg_integer(), TimeMs :: non_neg_integer()}
  | {error, Id :: binary() | undefined, Code :: binary(), Message :: binary()}
  | {health_response, Status :: binary(), GpuUtil :: float(), MemUsedGb :: float(), MemTotalGb :: float()}
  | {memory_response, MemoryInfo :: #{binary() => float() | term()}}
  | {ready, Model :: binary(), Backend :: binary()}.

%% Buffer (opaque)
-opaque buffer() :: binary().

%% Decode errors
-type decode_error() ::
    {invalid_json, term()}
  | missing_type
  | {unknown_type, binary()}
  | {missing_field, binary(), binary()}
  | {invalid_field, binary(), atom(), term()}.
```

All types exported via `-export_type` for use in `loom_port`, `loom_engine_coordinator`, and other downstream modules.

---

## Module Structure

Three logical sections in one module (~300-400 lines estimated):

1. **Encode** — `encode/1` with clauses per outbound message type. Pattern match → build map → `loom_json:encode/1` → append `\n`.

2. **Decode** — `decode/1` wraps `loom_json:decode/1` in a try/catch (since `json:decode/1` raises on invalid input) to convert exceptions into `{error, {invalid_json, Reason}}`. On success, extracts `<<"type">>` field, dispatches to `decode_<type>/1` internal helpers. Each helper validates required fields and types, constructs the tagged tuple.

3. **Buffer** — `new_buffer/0` returns `<<>>`. `feed/2` appends new data, splits on `\n` via `binary:split/3` with `[global]`, last segment becomes the new buffer.

---

## Test Plan (EUnit)

| Category | Tests |
|----------|-------|
| Encode round-trip | Encode each outbound type, decode the JSON, verify fields |
| Decode happy path | Each inbound message type with all fields present (including `ready` — unique as the startup-only message) |
| Decode validation | Missing type, unknown type, missing required field per message type, wrong field type |
| Invalid JSON | Truncated, empty, not-an-object |
| Buffer: complete lines | Single line, multiple lines in one chunk |
| Buffer: partial reads | Message split across 2-3 chunks, reassembled correctly |
| Buffer: edge cases | Empty feed, newline only, data with no newline |
| Generate params | Empty params map, partial params, all params |
| Error id handling | Error with id present, id absent, id null — all map to correct tuple |
| Memory response | Required fields validated, extra keys preserved |

No Common Test needed — pure functional module with no side effects.

---

## Assumptions

- `Id` is always a binary string, caller-generated.
- `error` messages may have `undefined` id for protocol-level errors not tied to a request.
- `generate_params` is a map (flexible, maps cleanly to/from JSON).
- `memory_response` validates three required keys (`total_gb`, `used_gb`, `available_gb`) but preserves extra backend-specific keys.
- Buffer as opaque binary is sufficient; can switch to iolist if P0-13 benchmarks reveal issues.
- `loom_json:decode/1` raises on invalid JSON (OTP `json:decode/1` behavior); `loom_protocol:decode/1` wraps this in try/catch.
- `loom_json` stays as the low-level JSON codec; `loom_protocol` layers message semantics on top.
