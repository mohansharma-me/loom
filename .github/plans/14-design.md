# P0-13 Design: Port Communication Benchmark Suite

**Issue:** [#14](https://github.com/mohansharma-me/loom/issues/14)
**Date:** 2026-03-29
**Status:** Draft

---

## Overview

Benchmark suite that measures Port communication overhead across the full Erlang-Python path to validate the <1ms latency target. Implemented as a single Common Test suite with a statistics helper module, outputting both a console report and a JSON file for CI tracking.

## Architecture

### Files

| File | Purpose |
|------|---------|
| `test/bench/loom_bench_SUITE.erl` | CT suite with all benchmark test cases, grouped by layer |
| `test/bench/loom_bench_stats.erl` | Percentile calculation, JSON output, threshold checking, console formatting |

### Test Groups

The suite is organized into 5 groups, ordered from lowest-level (no Port) to highest-level (concurrent full-path):

1. **`protocol`** — JSON encode/decode in isolation. No Port, no app startup. Pure Erlang measurement of `loom_protocol` overhead.
2. **`port`** — Direct `loom_port:send/2` round-trips. Measures Port + Python adapter overhead without coordinator.
3. **`coordinator`** — Full path through `loom_engine_coordinator:generate/3`. Adds ETS lookups, caller monitoring, request ID generation.
4. **`concurrent`** — N simultaneous requests through coordinator from separate Erlang processes. Measures overhead under contention.
5. **`large_messages`** — Full path with large prompts (4K/16K/64K characters). Measures serialization and Port I/O overhead for large payloads.

### Lifecycle

- `init_per_suite` — Start the loom application with mock adapter (`--token-delay 0 --startup-delay 0 --heartbeat-interval 5`), wait for `ready` state. Initialize results accumulator in CT config.
- `init_per_group(protocol, ...)` — No-op (protocol group doesn't need the app).
- `init_per_group(_, ...)` — Verify app is running and engine is in `ready` state.
- `end_per_suite` — Stop app, write aggregated JSON results to `_build/bench/results.json`, print formatted console summary table.

## Benchmark Specifications

### Protocol Group (no Port)

| Test Case | What it measures | Iterations |
|-----------|-----------------|------------|
| `encode_decode_health` | Round-trip encode + decode of health message | 10,000 |
| `encode_decode_generate` | Encode generate request + decode token response | 10,000 |
| `encode_decode_large` | Encode/decode with 4K, 16K, 64K character prompts | 1,000 per size |

### Port Group (direct loom_port)

| Test Case | What it measures | Iterations |
|-----------|-----------------|------------|
| `health_roundtrip` | Send health request, receive health_response through Port | 1,000 |
| `token_overhead` | Send generate, measure per-token delivery latency (10 tokens per request) | 500 |

### Coordinator Group (full path)

| Test Case | What it measures | Iterations |
|-----------|-----------------|------------|
| `coordinator_health` | Health check through coordinator | 1,000 |
| `coordinator_generate` | Full generate request through coordinator | 500 |

### Concurrent Group (N simultaneous processes through coordinator)

| Test Case | Concurrency | Rounds | What it measures |
|-----------|-------------|--------|-----------------|
| `concurrent_10` | 10 | 100 | Per-request latency + throughput at low concurrency |
| `concurrent_50` | 50 | 50 | Per-request latency + throughput at medium concurrency |
| `concurrent_100` | 100 | 20 | Per-request latency + throughput at high concurrency |

Each round spawns N Erlang processes that barrier-sync (all block on a shared ref, then a single message releases them) before calling `loom_engine_coordinator:generate/3`. Measures per-request latency (time from barrier release to final token received) and aggregate throughput (requests completed per second).

### Large Messages Group (through coordinator)

| Test Case | Prompt size | Iterations |
|-----------|-------------|------------|
| `large_4k` | 4,096 characters | 200 |
| `large_16k` | 16,384 characters | 100 |
| `large_64k` | 65,536 characters | 50 |

## Statistics Module (`loom_bench_stats`)

### Percentile Calculation

Input: list of timing samples in microseconds (collected via `erlang:monotonic_time(microsecond)`).

Output map per benchmark:
```erlang
#{
    min => integer(),      %% microseconds
    max => integer(),
    mean => float(),
    p50 => integer(),
    p80 => integer(),
    p95 => integer(),
    p99 => integer(),
    samples => integer()   %% count
}
```

Implementation: sort the samples list, index into it for each percentile. Simple, no external dependencies.

### Threshold Checking

Each benchmark defines a threshold map:

| Benchmark | Metric | Threshold (microseconds) |
|-----------|--------|--------------------------|
| `health_roundtrip` | p50 | < 1,000 |
| `health_roundtrip` | p99 | < 2,000 |
| `token_overhead` | p50 | < 500 |
| `encode_decode_health` | p50 | < 100 |
| `encode_decode_generate` | p50 | < 100 |

**Default mode:** Threshold violations emit warnings via `ct:pal` with `[WARN]` prefix. Test passes regardless.

**Strict mode:** When `BENCH_STRICT=true` environment variable is set, threshold violations call `ct:fail/1`. Intended for controlled hardware environments where results are reproducible.

### Console Output

Printed in `end_per_suite` via `ct:pal`:

```
============================================================
  Loom Port Benchmark Results
============================================================
 Benchmark                 p50      p80      p95      p99      min      max
 -------------------------------------------------------------------------
 json_encode_health          3us      4us      6us     12us      2us     45us
 health_roundtrip          420us    510us    780us   1.1ms    350us    2.3ms
 coordinator_generate      580us    700us    950us   1.5ms    420us    3.1ms
 concurrent_100_per_req    1.2ms    1.8ms    2.5ms   4.1ms    650us    8.2ms
 ...
============================================================
 Threshold checks: 5/5 PASS
============================================================
```

### JSON Output

Written to `_build/bench/results.json`:

```json
{
  "timestamp": "2026-03-29T12:00:00Z",
  "otp_version": "27.0",
  "strict_mode": false,
  "benchmarks": {
    "encode_decode_health": {
      "min_us": 2,
      "max_us": 45,
      "mean_us": 4.2,
      "p50_us": 3,
      "p80_us": 4,
      "p95_us": 6,
      "p99_us": 12,
      "samples": 10000,
      "threshold_pass": true
    },
    "health_roundtrip": {
      "min_us": 350,
      "max_us": 2300,
      "mean_us": 480.5,
      "p50_us": 420,
      "p80_us": 510,
      "p95_us": 780,
      "p99_us": 1100,
      "samples": 1000,
      "threshold_pass": true
    }
  },
  "pass": true
}
```

## Mock Adapter Configuration

The benchmark suite uses the existing mock adapter with minimal delays to isolate Port/framework overhead:

```
python3 priv/scripts/mock_adapter.py --token-delay 0 --startup-delay 0 --heartbeat-interval 5
```

- `--token-delay 0` — no artificial delay between tokens
- `--startup-delay 0` — adapter reaches `ready` state immediately
- `--heartbeat-interval 5` — infrequent heartbeats to avoid noise
- **10 tokens per generate request** — enough to measure per-token overhead without making iterations too long

The mock adapter's Python overhead (stdin read, JSON parse, stdout write) is intentional — real adapters are also Python, so this reflects realistic overhead. The `protocol` group provides the pure-Erlang baseline for comparison.

## CI Integration

### Running Locally

```bash
# Report-only mode (default)
rebar3 ct --suite loom_bench_SUITE

# Strict mode — fail on threshold breach
BENCH_STRICT=true rebar3 ct --suite loom_bench_SUITE
```

### GitHub Actions

Added as an optional job in `.github/workflows/ci.yml`:

```yaml
bench:
  name: Benchmarks
  runs-on: ubuntu-24.04
  needs: build
  steps:
    - uses: actions/checkout@v4
    - uses: erlef/setup-beam@v1
      with:
        otp-version: '27'
        rebar3-version: '3.24'
    - name: Restore deps cache
      uses: actions/cache@v4
      with:
        path: _build
        key: ${{ runner.os }}-rebar3-${{ hashFiles('rebar.lock') }}
    - name: Run benchmarks
      run: rebar3 ct --suite loom_bench_SUITE
    - name: Upload results
      uses: actions/upload-artifact@v4
      with:
        name: bench-results
        path: _build/bench/results.json
      if: always()
```

- **No `BENCH_STRICT` in CI** — runner performance varies, avoids flaky failures
- **Always uploads** JSON artifact regardless of pass/fail
- **Does not block merges** — benchmark failure doesn't gate the test job

### rebar.config Change

Add `test/bench` to CT spec dirs so `rebar3 ct --suite loom_bench_SUITE` discovers the suite.

## Assumptions

- **ASSUMPTION:** `erlang:monotonic_time(microsecond)` provides sufficient resolution for micro-benchmarks on all target platforms.
- **ASSUMPTION:** Mock adapter with `--token-delay 0` returns tokens fast enough that Python overhead is small relative to Port overhead. If not, protocol-group baselines will reveal this.
- **ASSUMPTION:** CT framework overhead (logging, config passing) is negligible compared to Port round-trip times. Protocol-group benchmarks will validate this since they run without a Port.
- **ASSUMPTION:** 10 tokens per generate request is representative enough for per-token overhead measurement. Can be tuned later.

## Out of Scope

- Trend tracking / historical comparison across CI runs (JSON structure supports it, tooling deferred)
- PR comparison comments (future enhancement)
- GPU hardware benchmarks (covered by #15, P0-14)
- Coordinator-level optimizations (benchmark first, optimize in P1)
