# Design Plan: CC-01 — Testing Strategy & Infrastructure (#49)

## Overview

Establish comprehensive testing infrastructure across the Loom project: add missing dependencies (`proper`, `meck`, `cover`), create a shared `loom_test_helpers` module, write property-based tests for key modules, enhance the mock adapter, and enable coverage reporting.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Scope | Foundation + Retrofit | AI agents pattern-match on existing code; existing code must exemplify conventions |
| Property testing | `proper` + tests for key modules | Protocol round-trip, config merging, JSON encode/decode need generative testing |
| Mock management | Separate concerns | `loom_test_helpers` for utilities, existing mocks keep their own APIs |
| Mocking library | `meck` | Standard Erlang mocking; complements explicit mocks for targeted function stubs |
| Coverage | `cover` via rebar3 | Built-in, zero-dependency coverage reporting |

## Dependencies to Add (test profile only)

- `proper` — property-based testing framework
- `meck` — function mocking library
- Enable `{cover_enabled, true}` and `{cover_opts, [verbose]}` in test profile

## New Module: `loom_test_helpers.erl`

Cross-cutting test utilities extracted from inline helpers scattered across suites:

- `start_app/0`, `stop_app/0` — application lifecycle with clean teardown
- `wait_for_status/3` — poll a process until expected state (replaces per-suite `wait_status`)
- `fixture_path/1` — resolve fixture paths relative to test data dir
- `write_temp_config/1` — write a temporary JSON config, return path, auto-cleanup
- `flush_mailbox/0` — drain process mailbox between tests
- `with_config/2` — run a fun with a temporary config file, clean up after
- `assert_log/2` — capture and assert on structured log output

## Property Tests

| Module | Test Module | Property | Generator |
|--------|-------------|----------|-----------|
| `loom_protocol` | `prop_loom_protocol` | encode/decode round-trip for all message types | `outbound_msg()`, `inbound_msg()` generators |
| `loom_protocol` | `prop_loom_protocol` | partial buffer assembly — chunked data produces same result | random chunk boundaries over valid JSON lines |
| `loom_config` | `prop_loom_config` | merge semantics — engine overrides always win over defaults | random config maps with overlapping keys |
| `loom_config` | `prop_loom_config` | validation rejects all invalid configs | invalid config generator (missing required fields, wrong types) |
| `loom_json` | `prop_loom_json` | encode/decode round-trip for all JSON value types | `json_value()` generator |

Property test files use `prop_` prefix naming convention.

## Mock Adapter Enhancement

Extend `loom_mock_coordinator` with:

- `{fail_after, N}` — fail after N tokens emitted
- `{delay_ms, {Min, Max}}` — random delay per token for latency simulation
- Memory pressure simulation — report high memory via health responses

## Coverage Integration

- Add `{cover_enabled, true}` and `{cover_opts, [verbose]}` to rebar.config test profile
- Coverage report generates automatically when CI runs eunit + ct
- No changes to CI workflow needed — rebar3 outputs coverage with the flag enabled

## Test Organization

- Keep flat `test/` structure (working well)
- `prop_*.erl` naming convention for property test modules
- `*_tests.erl` for EUnit, `*_SUITE.erl` for Common Test (existing convention, unchanged)

## Files to Create

- `test/loom_test_helpers.erl` — shared test utilities
- `test/prop_loom_protocol.erl` — protocol property tests
- `test/prop_loom_config.erl` — config property tests
- `test/prop_loom_json.erl` — JSON property tests

## Files to Modify

- `rebar.config` — add `proper`, `meck` to test deps; enable `cover`
- `test/loom_mock_coordinator.erl` — add failure injection, latency simulation
- Existing test suites — migrate inline helpers to use `loom_test_helpers` where beneficial
