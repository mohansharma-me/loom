# Design: Crash Recovery Validation Test Suite

**Issue:** [#13 — P0-12: Validate crash recovery](https://github.com/mohansharma-me/loom/issues/13)
**Date:** 2026-03-28

---

## Overview

Comprehensive `common_test` suites that validate Loom's core fault-tolerance thesis: BEAM can manage an inference engine subprocess via Port with automatic crash recovery. This is the "money test" for Phase 0.

## Architecture

Two separate test suites, one mock adapter enhancement:

```
test/
  loom_crash_recovery_SUITE.erl   — engine-level crash recovery (scenarios 1-5)
  loom_http_disconnect_SUITE.erl  — HTTP client disconnect (scenario 6)
priv/scripts/
  mock_adapter.py                 — add {crash, ExitCode} command support
```

### Why Two Suites

- **loom_crash_recovery_SUITE** tests the supervision tree and coordinator self-heal logic. Exercises `loom_engine_coordinator`, `loom_port`, and `loom_engine_sup` directly via Erlang APIs.
- **loom_http_disconnect_SUITE** tests the HTTP layer's integration with request lifecycle. Exercises `loom_http_handler` and Cowboy's SSE connection management.

Separate suites give clearer failure signals — an engine recovery failure won't be confused with an HTTP handling issue.

## Process Kill Mechanism

- **Scenarios 1-4:** Extract OS PID from `loom_port` state, then `os:cmd("kill -9 " ++ OsPid)` for realistic SIGKILL crashes. This tests the actual production crash path: OS process death → Port exit signal → coordinator self-heal.
- **Scenario 5:** Send `{crash, ExitCode}` command to mock adapter via the port protocol for controlled exit codes. Requires a small addition to `mock_adapter.py`.

## Recovery Verification Pattern

All crash scenarios follow the same verification structure:

1. Kill the engine process (OS-level or via crash command)
2. Assert in-flight callers receive `{loom_error, _, <<"engine_crashed">>, _}`
3. Poll `loom_engine_coordinator:get_status/1` until it returns `ready`
4. Measure and log recovery time (kill timestamp → ready timestamp)
5. Send a new request and verify it completes successfully
6. Verify no orphaned OS processes (old PID gone, new PID alive)

## Test Scenarios

### Scenario 1 — Clean Operation (baseline)

**Purpose:** Control test. If this fails, nothing else matters.

**Steps:**
1. Start system with mock adapter config
2. Verify `get_status/1` returns `ready`
3. Call `generate/3`, receive `{ok, RequestId}`
4. Receive streaming tokens: `{loom_token, Id, Text, false}` messages
5. Receive final token with `Finished = true`
6. Receive `{loom_done, Id, #{tokens := N, time_ms := T}}`
7. Verify load returns to 0

### Scenario 2 — Engine Crash During Idle

**Purpose:** Verify self-heal when no requests are in flight.

**Steps:**
1. Wait for `ready` status
2. Extract OS PID from port, `kill -9`
3. Poll status: expect transition through `starting` then back to `ready`
4. Log recovery time
5. Send new generate request, verify tokens arrive and complete
6. Verify old OS PID no longer exists

### Scenario 3 — Engine Crash During Active Request

**Purpose:** Verify in-flight request error delivery and subsequent self-heal.

**Steps:**
1. Configure mock adapter with slow `--token-delay` (e.g., 200ms)
2. Send generate request, wait for at least 1 token
3. Kill adapter with `SIGKILL`
4. Assert caller receives `{loom_error, RequestId, <<"engine_crashed">>, _}`
5. Poll until status returns to `ready`
6. Send new request, verify full completion
7. Verify load is 0

### Scenario 4 — Multiple Rapid Crashes (Restart Intensity)

**Purpose:** Verify supervisor respects `max_restarts` and doesn't crash-loop.

**Steps:**
1. Configure with low restart intensity (e.g., `max_restarts: 2, max_seconds: 60`)
2. Kill adapter, wait for self-heal to reach `starting` state
3. Kill again immediately after new adapter spawns
4. Kill a third time — exceeds configured intensity
5. Assert engine supervisor has terminated
6. Assert `loom_sup` is still alive (fault isolation)
7. Verify no orphaned OS processes

### Scenario 5 — Different Exit Codes

**Purpose:** Verify system handles various adapter exit scenarios correctly.

**Steps:**
1. Send `{crash, 0}` → verify coordinator handles clean exit, self-heals
2. After recovery, send `{crash, 1}` → verify error with exit code detail, self-heals
3. After recovery, use `kill -9` → verify SIGKILL (exit 137) handled, self-heals
4. For each exit: verify the exit code is included in error detail sent to callers
5. Verify self-heal completes and next request succeeds after each

### Scenario 6 — HTTP Client Disconnect (separate suite)

**Purpose:** Verify request cleanup when HTTP client disconnects mid-stream.

**Steps:**
1. Start Loom with mock adapter
2. Open HTTP connection to `/v1/chat/completions` with `stream: true`
3. Read at least one SSE event
4. Close TCP connection abruptly
5. Verify in-flight request is cancelled (coordinator load → 0)
6. Verify engine stays `ready` (no crash, just cleanup)
7. Send new HTTP request, verify it succeeds

## Mock Adapter Enhancement

Add a `{crash, ExitCode}` command to `mock_adapter.py`:

```python
# When receiving: {"type": "crash", "exit_code": N}
# Immediately call sys.exit(N)
```

This allows scenario 5 to produce specific exit codes without relying on OS signals, which map to fixed codes (SIGKILL → 137, SIGTERM → 143).

## Test Infrastructure

- Uses existing `loom_test_helpers` for app lifecycle, status polling, config management
- Uses existing `mock_adapter.py` with `--startup-delay` and `--token-delay` for timing control
- Helper function to extract OS PID from `loom_port` (via `sys:get_state/1` or a new accessor)
- Helper function to verify no orphaned OS processes (check PID existence after kill)
- Recovery time measurement: `erlang:monotonic_time/1` before kill, after `ready` status

## Acceptance Criteria Mapping

| Criteria | Covered by |
|----------|-----------|
| All six test scenarios pass | Scenarios 1-6 across both suites |
| Recovery time measured and logged | Scenarios 2, 3, 4, 5 (logged via `ct:pal/2`) |
| No orphaned processes | Scenarios 2, 3, 4, 5 (OS PID existence check) |
| No memory leaks after repeated cycles | Scenario 4 + process count assertions |
| Tests run in CI without GPU | Mock adapter used throughout, no GPU dependencies |

## Assumptions

- `loom_port` exposes or allows extraction of the OS PID of the managed subprocess (via `sys:get_state/1` or a dedicated accessor function).
- The mock adapter's `--token-delay` is sufficient to reliably kill mid-stream (200ms+ delay gives a comfortable window).
- Supervisor restart intensity can be configured per-test via the test config passed to the application.
- HTTP client disconnect is detectable by Cowboy and propagated to the coordinator as a caller process death (monitored via `erlang:monitor/2`).
