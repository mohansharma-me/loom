# Design Plan: Integration Test Suite for Real Inference Engines (Issue #15)

## Overview

End-to-end integration test suite that validates the full Loom stack — from HTTP API
through OTP supervision tree to a real MLX inference engine on Apple Silicon. Tests
run against `mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit` with actual model inference,
not mocks.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Model | TinyLlama-1.1B-Chat-v1.0-4bit (fixed) | Smallest viable chat model for MLX (~700MB), proven in existing adapter tests |
| Framework | Erlang Common Test | Direct access to OTP internals for crash recovery, consistent with codebase |
| Structure | Single suite, sequential, one app lifecycle | 8 tests don't warrant groups/multi-suite complexity; one model load (~30-60s) |
| Crash method | SIGKILL (kill -9) the adapter OS process | Most realistic production crash simulation |
| GPU metrics | Structural + sanity bounds | Catches real bugs without being brittle to background memory fluctuation |
| Model download | Skip suite with setup instructions if not cached | No surprise downloads or failures |
| API coverage | Both OpenAI (`/v1/chat/completions`) and Anthropic (`/v1/messages`) | Both endpoints are shipped in P0 |
| HTTP client | Erlang `httpc` (inets) | Built-in, no extra deps, supports async streaming |

## Deliverables

- `test/integration/loom_mlx_integration_SUITE.erl` — the test suite
- `test/integration/README.md` — setup and run instructions

## Suite Structure & Lifecycle

### init_per_suite

Runs a prerequisite check chain. Each check returns `{skip, Reason}` with full setup
instructions if it fails. Checks are ordered most-likely-to-fail first:

1. **Platform** — `os:type()` is `{unix, darwin}` and `sysctl -n hw.optional.arm64` returns `"1"`.
   Skip: `"Requires Apple Silicon Mac (ARM64 macOS)"`

2. **Python** — `os:find_executable("python3")` succeeds.
   Skip: `"python3 not found. Install via: brew install python@3.11"`

3. **MLX** — `python3 -c "import mlx_lm"` exits 0.
   Skip: `"MLX dependencies not installed. Run:\n  pip install mlx-lm>=0.20.0 huggingface-hub psutil"`

4. **Model cache** — `python3 -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit', local_files_only=True)"` exits 0.
   Skip: `"Model not cached locally. Run:\n  huggingface-cli download mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit\nFirst download is ~700MB. Subsequent test runs use the cache."`

After all checks pass:

5. Write temporary `loom.json` config:
   - Backend: `mlx`
   - Model: `mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit`
   - HTTP port: 18080 (try 18081-18089 if busy)
   - Engine name: `integration_engine`

6. Start `inets` application (for httpc)

7. Start `loom` application via `application:ensure_all_started(loom)`

8. Wait for engine ready — poll coordinator ETS meta table until status is `ready`,
   timeout 120s (covers model load + Metal shader compilation)

9. Store `base_url`, `engine_id`, `http_port` in CT config

### end_per_suite

1. Stop `loom` application
2. Stop `inets`
3. Clean up temporary config file

### all/0 — Test Execution Order

Returns an ordered list (not a set — order matters):

```erlang
all() ->
    [health_endpoint_test,
     memory_metrics_test,
     chat_completion_openai_test,
     chat_completion_anthropic_test,
     sse_streaming_openai_test,
     sse_streaming_anthropic_test,
     gpu_metrics_sanity_test,
     crash_recovery_test].
```

Crash recovery is last because it mutates engine state. All other tests run against
a stable, ready engine.

## Test Cases

### 1. health_endpoint_test

- `GET /health`
- Assert HTTP 200
- Assert JSON body has `"status": "ready"`
- Assert body has `"engine_id"` matching configured engine name
- Assert body has `"load"` as a non-negative integer

### 2. memory_metrics_test

- No HTTP memory endpoint exists — call `loom_gpu_monitor:get_metrics/1` directly
  via Erlang API (this is an integration test with OTP access, not a black-box HTTP test)
- Assert response contains `mem_total_gb`, `mem_used_gb`
- Sanity: `mem_total_gb` matches machine RAM (query `sysctl -n hw.memsize`, compare within 0.5 GB)
- Sanity: `mem_used_gb > 0` and `mem_used_gb < mem_total_gb`

### 3. chat_completion_openai_test

- `POST /v1/chat/completions`
- Body: `{model: "mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit", messages: [{role: "user", content: "Say hello"}], stream: false}`
- Assert HTTP 200
- Assert `choices[0].message.content` is a non-empty binary
- Assert `usage.prompt_tokens > 0` and `usage.completion_tokens > 0`
- Timeout: 60s (first inference includes Metal compilation)

### 4. chat_completion_anthropic_test

- `POST /v1/messages`
- Body: `{model: "mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit", messages: [{role: "user", content: "Say hello"}], max_tokens: 64, stream: false}`
- Assert HTTP 200
- Assert `content[0].text` is a non-empty binary
- Assert `usage.input_tokens > 0` and `usage.output_tokens > 0`
- Assert `stop_reason` is `"end_turn"`
- Timeout: 60s

### 5. sse_streaming_openai_test

- `POST /v1/chat/completions` with `stream: true`
- Assert HTTP 200 with `content-type: text/event-stream`
- Collect SSE chunks via async httpc
- Assert at least 2 `data:` events received before `[DONE]`
- Parse each chunk — valid JSON with `choices[0].delta.content`
- Assert final chunk has `finish_reason: "stop"`
- Concatenated tokens form a non-empty string
- Timeout: 60s

### 6. sse_streaming_anthropic_test

- `POST /v1/messages` with `stream: true`
- Assert HTTP 200 with `content-type: text/event-stream`
- Assert SSE events follow Anthropic format:
  - `message_start` event
  - `content_block_start` event
  - At least 2 `content_block_delta` events (with `delta.text`)
  - `content_block_stop` event
  - `message_delta` event
  - `message_stop` event
- Concatenated delta text is non-empty
- Timeout: 60s

### 7. gpu_metrics_sanity_test

- Call `loom_gpu_monitor:get_metrics/1` directly (or via health endpoint)
- Assert `mem_total_gb` matches machine RAM (sysctl check, within 0.5 GB)
- Assert `mem_used_gb > 0`
- Assert `gpu_util` is a valid float (0.0 expected on Apple Silicon — verify it's a number, don't fail on value)
- Assert `timestamp` is recent (within last 30s)

### 8. crash_recovery_test

1. Verify engine is in `ready` state via ETS meta table
2. Get the Python adapter's OS PID from loom_port state (via `sys:get_state/1`)
3. `os:cmd("kill -9 " ++ integer_to_list(OsPid))` — SIGKILL the adapter
4. Poll coordinator status — expect transition through `starting` back to `ready`, timeout 120s (model must reload)
5. Send `POST /v1/chat/completions` with `stream: false`, same params as test 3
6. Assert HTTP 200 with non-empty response content
7. This proves: crash detected, supervisor restarted engine, model reloaded, full request pipeline recovered

## HTTP Client & SSE Parsing

### HTTP Client

Erlang's built-in `httpc` from `inets` application:

- **Non-streaming:** `httpc:request(post, {Url, Headers, "application/json", Body}, [{timeout, 60000}], [{body_format, binary}])`
- **Streaming:** `httpc:request(post, {Url, Headers, ContentType, Body}, [{timeout, 60000}], [{sync, false}, {stream, self}])` — delivers chunks as `{http, {RequestId, stream, BinChunk}}` messages

### SSE Parser

Helper function within the suite:

1. Accumulates `stream` messages until `stream_end`
2. Splits accumulated binary on `\n\n` boundaries
3. Extracts `data: ` prefixed lines
4. Decodes JSON from each data line (except `[DONE]`)
5. Returns list of decoded event maps

### JSON

Uses `jsx` (existing project dependency) for encode/decode.

## Test Configuration

Temporary config written to a temp file during `init_per_suite`:

```json
{
  "engines": [
    {
      "name": "integration_engine",
      "backend": "mlx",
      "model": "mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit",
      "gpu_ids": [],
      "coordinator": {
        "startup_timeout_ms": 120000
      },
      "gpu_monitor": {
        "backend": "apple",
        "poll_interval_ms": 5000
      }
    }
  ],
  "server": {
    "port": 18080
  }
}
```

Port selection: try 18080, if `gen_tcp:listen` fails try 18081-18089. Store chosen port
in config JSON and CT config.

## Setup Instructions (README.md)

```
## Prerequisites

1. Apple Silicon Mac (M1/M2/M3/M4)
2. Erlang/OTP 26+ and rebar3
3. Python 3.11+:    brew install python@3.11
4. MLX dependencies: pip install mlx-lm>=0.20.0 huggingface-hub psutil
5. Download model:   huggingface-cli download mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit

## Running

    rebar3 ct --suite test/integration/loom_mlx_integration_SUITE

## Notes

- First inference is slow (~10-20s) due to Metal shader compilation
- Model stays in HuggingFace cache (~/.cache/huggingface/hub/)
- Tests use port 18080 (auto-increments if busy)
- Total runtime: ~2-3 minutes
- Suite auto-skips (not fails) if prerequisites are missing
```

## Assumptions

- ASSUMPTION: `httpc` async streaming mode delivers SSE chunks without buffering issues
  for the data volumes we expect (small token payloads). If chunking proves unreliable,
  fallback is `gun` HTTP client (already a cowboy dependency).
- ASSUMPTION: Metal shader compilation on first inference adds ~10-20s. The 60s per-test
  timeout accommodates this. If a specific Mac model is significantly slower, the timeout
  may need tuning.
- ASSUMPTION: The HuggingFace cache path (`~/.cache/huggingface/hub/`) is stable across
  huggingface-hub versions. The `snapshot_download(local_files_only=True)` check is
  version-independent.
- ASSUMPTION: `loom_gpu_monitor` with `backend: apple` correctly auto-detects on Apple
  Silicon without needing explicit configuration. The explicit `"backend": "apple"` in
  config is a safety measure.
