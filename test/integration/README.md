# Integration Tests

End-to-end integration tests that run against real inference engines on actual hardware.
These tests are **not** part of the standard CI pipeline — they require specific hardware
and model downloads.

## MLX Integration Suite (Apple Silicon)

Tests the full Loom stack with a real MLX inference engine using TinyLlama-1.1B.

### Prerequisites

1. **Apple Silicon Mac** (M1/M2/M3/M4)
2. **Erlang/OTP 27+** and rebar3
3. **Python 3.11+**
   ```bash
   brew install python@3.11
   ```
4. **MLX dependencies**
   ```bash
   pip install mlx-lm>=0.20.0 huggingface-hub psutil
   ```
5. **Download test model** (~700MB, cached for subsequent runs)
   ```bash
   huggingface-cli download mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit
   ```

### Running

Run the full suite:

```bash
rebar3 ct --suite test/integration/loom_mlx_integration_SUITE
```

Run a specific test:

```bash
rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case health_endpoint_test
```

### Test Cases

| Test | What It Validates |
|------|------------------|
| `health_endpoint_test` | GET /health returns 200 with engine status `ready` |
| `memory_metrics_test` | GPU monitor reports sensible memory values matching machine RAM |
| `chat_completion_openai_test` | POST /v1/chat/completions returns non-empty completion |
| `chat_completion_anthropic_test` | POST /v1/messages returns non-empty completion in Anthropic format |
| `sse_streaming_openai_test` | SSE streaming delivers token chunks ending with [DONE] |
| `sse_streaming_anthropic_test` | SSE streaming follows Anthropic event sequence |
| `gpu_metrics_sanity_test` | GPU metrics have valid types and sensible values |
| `crash_recovery_test` | SIGKILL adapter → auto-restart → successful request |

### Notes

- First inference after model load is slow (~10-20s) due to Metal shader compilation
- The model is cached in `~/.cache/huggingface/hub/` after first download
- Tests use HTTP port 18080 (auto-increments to 18089 if busy)
- Total runtime: ~2-3 minutes
- If prerequisites are missing, the suite **skips** (not fails) with setup instructions
