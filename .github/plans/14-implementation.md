# P0-13: Port Communication Benchmark Suite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a benchmark suite measuring Port communication overhead to validate the <1ms latency target.

**Architecture:** Single CT suite (`loom_bench_SUITE`) with 5 test groups (protocol, port, coordinator, concurrent, large_messages) plus a statistics helper module (`loom_bench_stats`). Results stored in ETS during the run, then written as JSON and a console table in `end_per_suite`. Thresholds enforced softly by default, strictly via `BENCH_STRICT=true`.

**Tech Stack:** Erlang/OTP 27 Common Test, EUnit (for stats module TDD), `erlang:monotonic_time(microsecond)` for timing, `loom_json` for JSON output.

**Design spec:** `.github/plans/14-design.md`

**Deviations from design spec:**
- Mock adapter produces 5 tokens per generate (not 10 as spec assumed). Using 5 to match reality.
- `coordinator_health` replaced with `coordinator_ets_read` — the coordinator has no health API; ETS reads (`get_status/1`, `get_load/1`, `get_info/1`) are the coordinator's lock-free read path used by HTTP handlers.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `test/bench/loom_bench_stats.erl` | Create | Percentile calculation, threshold checking, JSON output, console table formatting |
| `test/bench/loom_bench_stats_tests.erl` | Create | EUnit tests for stats module |
| `test/bench/loom_bench_SUITE.erl` | Create | CT benchmark suite — all 5 groups, timing logic, result collection, reporting |
| `rebar.config` | Modify | Add `test/bench` to `extra_src_dirs` in test profile |
| `.github/workflows/ci.yml` | Modify | Add optional `bench` job |

---

### Task 1: Setup rebar.config and directory

**Files:**
- Modify: `rebar.config` (test profile, lines 34-43)

- [ ] **Step 1: Create test/bench directory**

```bash
mkdir -p test/bench
```

- [ ] **Step 2: Add extra_src_dirs to test profile in rebar.config**

In `rebar.config`, inside the `{test, [...]}` profile, add `extra_src_dirs`:

```erlang
    {test, [
        {erl_opts, [debug_info, warnings_as_errors, nowarn_missing_spec]},
        {extra_src_dirs, ["test/bench"]},
        {deps, [
            {gun, "2.1.0"},
            {proper, "1.4.0"},
            {meck, "0.9.2"}
        ]},
        {cover_enabled, true},
        {cover_opts, [verbose]}
    ]}
```

- [ ] **Step 3: Verify compilation**

```bash
rebar3 as test compile
```

Expected: compiles with no errors (no bench files yet, but the dir is recognized).

- [ ] **Step 4: Commit**

```bash
git add rebar.config test/bench
git commit -m "chore: add test/bench directory and extra_src_dirs for benchmarks

Refs #14"
```

---

### Task 2: Stats module — percentile calculation (TDD)

**Files:**
- Create: `test/bench/loom_bench_stats.erl`
- Create: `test/bench/loom_bench_stats_tests.erl`

- [ ] **Step 1: Write failing EUnit tests for calculate/1**

Create `test/bench/loom_bench_stats_tests.erl`:

```erlang
%%%-------------------------------------------------------------------
%%% @doc EUnit tests for loom_bench_stats.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_bench_stats_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% calculate/1 tests
%%--------------------------------------------------------------------

calculate_basic_test() ->
    Stats = loom_bench_stats:calculate([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
    ?assertEqual(1, maps:get(min, Stats)),
    ?assertEqual(10, maps:get(max, Stats)),
    ?assertEqual(5.5, maps:get(mean, Stats)),
    ?assertEqual(5, maps:get(p50, Stats)),
    ?assertEqual(8, maps:get(p80, Stats)),
    ?assertEqual(10, maps:get(p95, Stats)),
    ?assertEqual(10, maps:get(p99, Stats)),
    ?assertEqual(10, maps:get(samples, Stats)).

calculate_single_element_test() ->
    Stats = loom_bench_stats:calculate([42]),
    ?assertEqual(42, maps:get(min, Stats)),
    ?assertEqual(42, maps:get(max, Stats)),
    ?assertEqual(42.0, maps:get(mean, Stats)),
    ?assertEqual(42, maps:get(p50, Stats)),
    ?assertEqual(42, maps:get(p80, Stats)),
    ?assertEqual(42, maps:get(p95, Stats)),
    ?assertEqual(42, maps:get(p99, Stats)),
    ?assertEqual(1, maps:get(samples, Stats)).

calculate_unsorted_input_test() ->
    Stats = loom_bench_stats:calculate([10, 1, 5, 3, 7, 2, 8, 4, 9, 6]),
    ?assertEqual(1, maps:get(min, Stats)),
    ?assertEqual(10, maps:get(max, Stats)),
    ?assertEqual(5, maps:get(p50, Stats)).

calculate_empty_list_test() ->
    ?assertMatch({error, empty_samples}, loom_bench_stats:calculate([])).

calculate_hundred_elements_test() ->
    %% 1..100, p50=50, p80=80, p95=95, p99=99
    Samples = lists:seq(1, 100),
    Stats = loom_bench_stats:calculate(Samples),
    ?assertEqual(1, maps:get(min, Stats)),
    ?assertEqual(100, maps:get(max, Stats)),
    ?assertEqual(50, maps:get(p50, Stats)),
    ?assertEqual(80, maps:get(p80, Stats)),
    ?assertEqual(95, maps:get(p95, Stats)),
    ?assertEqual(99, maps:get(p99, Stats)),
    ?assertEqual(100, maps:get(samples, Stats)).
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
rebar3 eunit --module loom_bench_stats_tests
```

Expected: FAIL — module `loom_bench_stats` not found.

- [ ] **Step 3: Write minimal implementation of calculate/1**

Create `test/bench/loom_bench_stats.erl`:

```erlang
%%%-------------------------------------------------------------------
%%% @doc Statistics calculation, threshold checking, and reporting
%%% for the Loom benchmark suite.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_bench_stats).

-export([
    calculate/1
]).

%% @doc Calculate statistics from a list of timing samples (microseconds).
%% Returns a map with min, max, mean, p50, p80, p95, p99, samples.
-spec calculate([non_neg_integer()]) ->
    #{atom() => number()} | {error, empty_samples}.
calculate([]) ->
    {error, empty_samples};
calculate(Samples) ->
    Sorted = lists:sort(Samples),
    N = length(Sorted),
    Sum = lists:sum(Sorted),
    #{
        min => hd(Sorted),
        max => lists:last(Sorted),
        mean => Sum / N,
        p50 => percentile(Sorted, N, 0.50),
        p80 => percentile(Sorted, N, 0.80),
        p95 => percentile(Sorted, N, 0.95),
        p99 => percentile(Sorted, N, 0.99),
        samples => N
    }.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

%% @doc Get the value at a given percentile from a sorted list.
%% Uses ceiling-rank method: index = ceil(N * P).
percentile(Sorted, N, P) ->
    Index = erlang:ceil(N * P),
    lists:nth(Index, Sorted).
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
rebar3 eunit --module loom_bench_stats_tests
```

Expected: All 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add test/bench/loom_bench_stats.erl test/bench/loom_bench_stats_tests.erl
git commit -m "feat(bench): add loom_bench_stats:calculate/1 with percentile calculation

Refs #14"
```

---

### Task 3: Stats module — threshold checking (TDD)

**Files:**
- Modify: `test/bench/loom_bench_stats_tests.erl`
- Modify: `test/bench/loom_bench_stats.erl`

- [ ] **Step 1: Write failing EUnit tests for check_thresholds/2**

Add to `test/bench/loom_bench_stats_tests.erl`:

```erlang
%%--------------------------------------------------------------------
%% check_thresholds/2 tests
%%--------------------------------------------------------------------

check_thresholds_all_pass_test() ->
    Stats = #{p50 => 500, p99 => 1500, min => 100, max => 2000,
              mean => 600.0, p80 => 800, p95 => 1200, samples => 100},
    Thresholds = #{health_roundtrip => #{p50 => 1000, p99 => 2000}},
    Results = loom_bench_stats:check_thresholds([{health_roundtrip, Stats}], Thresholds),
    ?assertMatch([{health_roundtrip, pass, []}], Results).

check_thresholds_one_fail_test() ->
    Stats = #{p50 => 1500, p99 => 3000, min => 100, max => 4000,
              mean => 1800.0, p80 => 2000, p95 => 2500, samples => 100},
    Thresholds = #{health_roundtrip => #{p50 => 1000, p99 => 2000}},
    Results = loom_bench_stats:check_thresholds([{health_roundtrip, Stats}], Thresholds),
    [{health_roundtrip, fail, Violations}] = Results,
    ?assertEqual(2, length(Violations)),
    ?assert(lists:any(fun({p50, _, _}) -> true; (_) -> false end, Violations)),
    ?assert(lists:any(fun({p99, _, _}) -> true; (_) -> false end, Violations)).

check_thresholds_no_threshold_defined_test() ->
    Stats = #{p50 => 500, p99 => 1500, min => 100, max => 2000,
              mean => 600.0, p80 => 800, p95 => 1200, samples => 100},
    Thresholds = #{},
    Results = loom_bench_stats:check_thresholds([{some_benchmark, Stats}], Thresholds),
    ?assertMatch([{some_benchmark, pass, []}], Results).
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
rebar3 eunit --module loom_bench_stats_tests
```

Expected: FAIL — `check_thresholds/2` undefined.

- [ ] **Step 3: Implement check_thresholds/2**

Add to the exports in `test/bench/loom_bench_stats.erl`:

```erlang
-export([
    calculate/1,
    check_thresholds/2
]).
```

Add the implementation:

```erlang
%% @doc Check benchmark results against threshold map.
%% Thresholds :: #{BenchmarkName => #{MetricName => MaxValueUs}}.
%% Returns [{BenchmarkName, pass | fail, [{Metric, Actual, Limit}]}].
-spec check_thresholds([{atom(), map()}], map()) ->
    [{atom(), pass | fail, [{atom(), number(), number()}]}].
check_thresholds(Results, Thresholds) ->
    lists:map(fun({Name, Stats}) ->
        case maps:get(Name, Thresholds, undefined) of
            undefined ->
                {Name, pass, []};
            BenchThresholds ->
                Violations = maps:fold(fun(Metric, Limit, Acc) ->
                    Actual = maps:get(Metric, Stats),
                    case Actual >= Limit of
                        true -> [{Metric, Actual, Limit} | Acc];
                        false -> Acc
                    end
                end, [], BenchThresholds),
                case Violations of
                    [] -> {Name, pass, []};
                    _ -> {Name, fail, Violations}
                end
        end
    end, Results).
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
rebar3 eunit --module loom_bench_stats_tests
```

Expected: All 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add test/bench/loom_bench_stats.erl test/bench/loom_bench_stats_tests.erl
git commit -m "feat(bench): add threshold checking to loom_bench_stats

Refs #14"
```

---

### Task 4: Stats module — JSON output and console formatting (TDD)

**Files:**
- Modify: `test/bench/loom_bench_stats_tests.erl`
- Modify: `test/bench/loom_bench_stats.erl`

- [ ] **Step 1: Write failing EUnit tests for to_json/2 and format_table/1**

Add to `test/bench/loom_bench_stats_tests.erl`:

```erlang
%%--------------------------------------------------------------------
%% to_json/2 tests
%%--------------------------------------------------------------------

to_json_structure_test() ->
    Stats = #{p50 => 420, p80 => 510, p95 => 780, p99 => 1100,
              min => 350, max => 2300, mean => 480.5, samples => 1000},
    Thresholds = #{health_roundtrip => #{p50 => 1000, p99 => 2000}},
    Json = loom_bench_stats:to_json(
        [{health_roundtrip, Stats}],
        #{strict_mode => false, thresholds => Thresholds}),
    ?assert(is_binary(Json)),
    Decoded = json:decode(Json),
    ?assert(is_map(Decoded)),
    ?assertMatch(#{<<"benchmarks">> := _}, Decoded),
    ?assertMatch(#{<<"pass">> := true}, Decoded),
    ?assertMatch(#{<<"strict_mode">> := false}, Decoded),
    Bench = maps:get(<<"health_roundtrip">>, maps:get(<<"benchmarks">>, Decoded)),
    ?assertEqual(420, maps:get(<<"p50_us">>, Bench)),
    ?assertEqual(1100, maps:get(<<"p99_us">>, Bench)),
    ?assertEqual(1000, maps:get(<<"samples">>, Bench)),
    ?assertEqual(true, maps:get(<<"threshold_pass">>, Bench)).

to_json_failing_threshold_test() ->
    Stats = #{p50 => 1500, p80 => 1800, p95 => 2200, p99 => 3000,
              min => 500, max => 4000, mean => 1600.0, samples => 100},
    Thresholds = #{health_roundtrip => #{p50 => 1000}},
    Json = loom_bench_stats:to_json(
        [{health_roundtrip, Stats}],
        #{strict_mode => false, thresholds => Thresholds}),
    Decoded = json:decode(Json),
    ?assertMatch(#{<<"pass">> := false}, Decoded),
    Bench = maps:get(<<"health_roundtrip">>, maps:get(<<"benchmarks">>, Decoded)),
    ?assertEqual(false, maps:get(<<"threshold_pass">>, Bench)).

%%--------------------------------------------------------------------
%% format_table/1 tests
%%--------------------------------------------------------------------

format_table_returns_iolist_test() ->
    Stats = #{p50 => 420, p80 => 510, p95 => 780, p99 => 1100,
              min => 350, max => 2300, mean => 480.5, samples => 1000},
    Output = loom_bench_stats:format_table([{health_roundtrip, Stats}]),
    Flat = lists:flatten(Output),
    ?assert(is_list(Flat)),
    %% Should contain the benchmark name
    ?assert(string:find(Flat, "health_roundtrip") =/= nomatch),
    %% Should contain formatted durations
    ?assert(string:find(Flat, "420us") =/= nomatch).

%%--------------------------------------------------------------------
%% format_duration/1 tests
%%--------------------------------------------------------------------

format_duration_microseconds_test() ->
    ?assertEqual("420us", lists:flatten(loom_bench_stats:format_duration(420))),
    ?assertEqual("3us", lists:flatten(loom_bench_stats:format_duration(3))),
    ?assertEqual("999us", lists:flatten(loom_bench_stats:format_duration(999))).

format_duration_milliseconds_test() ->
    ?assertEqual("1.0ms", lists:flatten(loom_bench_stats:format_duration(1000))),
    ?assertEqual("1.2ms", lists:flatten(loom_bench_stats:format_duration(1200))),
    ?assertEqual("4.1ms", lists:flatten(loom_bench_stats:format_duration(4100))).
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
rebar3 eunit --module loom_bench_stats_tests
```

Expected: FAIL — `to_json/2`, `format_table/1`, `format_duration/1` undefined.

- [ ] **Step 3: Implement to_json/2, format_table/1, format_duration/1**

Update exports in `test/bench/loom_bench_stats.erl`:

```erlang
-export([
    calculate/1,
    check_thresholds/2,
    to_json/2,
    format_table/1,
    format_duration/1
]).
```

Add implementations:

```erlang
%% @doc Generate JSON binary from benchmark results.
%% Opts :: #{strict_mode => boolean(), thresholds => map()}.
-spec to_json([{atom(), map()}], map()) -> binary().
to_json(Results, Opts) ->
    StrictMode = maps:get(strict_mode, Opts, false),
    Thresholds = maps:get(thresholds, Opts, #{}),
    BenchMap = lists:foldl(fun({Name, Stats}, Acc) ->
        ThresholdPass = check_single_threshold(Name, Stats, Thresholds),
        Entry = #{
            min_us => maps:get(min, Stats),
            max_us => maps:get(max, Stats),
            mean_us => maps:get(mean, Stats),
            p50_us => maps:get(p50, Stats),
            p80_us => maps:get(p80, Stats),
            p95_us => maps:get(p95, Stats),
            p99_us => maps:get(p99, Stats),
            samples => maps:get(samples, Stats),
            threshold_pass => ThresholdPass
        },
        Acc#{Name => Entry}
    end, #{}, Results),
    AllPass = lists:all(fun({_, #{threshold_pass := P}}) -> P end,
                        maps:to_list(BenchMap)),
    Timestamp = list_to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{offset, "Z"}])),
    OtpVersion = list_to_binary(erlang:system_info(otp_release)),
    loom_json:encode(#{
        timestamp => Timestamp,
        otp_version => OtpVersion,
        strict_mode => StrictMode,
        benchmarks => BenchMap,
        pass => AllPass
    }).

%% @doc Format benchmark results as a console table (iolist).
-spec format_table([{atom(), map()}]) -> iolist().
format_table(Results) ->
    Header = io_lib:format(
        "~n============================================================~n"
        "  Loom Port Benchmark Results~n"
        "============================================================~n"
        " ~-28s ~8s ~8s ~8s ~8s ~8s ~8s~n"
        " ~s~n",
        ["Benchmark", "p50", "p80", "p95", "p99", "min", "max",
         lists:duplicate(76, $-)]),
    Rows = lists:map(fun({Name, Stats}) ->
        io_lib:format(" ~-28s ~8s ~8s ~8s ~8s ~8s ~8s~n", [
            atom_to_list(Name),
            format_duration(maps:get(p50, Stats)),
            format_duration(maps:get(p80, Stats)),
            format_duration(maps:get(p95, Stats)),
            format_duration(maps:get(p99, Stats)),
            format_duration(maps:get(min, Stats)),
            format_duration(maps:get(max, Stats))
        ])
    end, Results),
    Footer = io_lib:format(
        "============================================================~n", []),
    [Header, Rows, Footer].

%% @doc Format a duration in microseconds as a human-readable string.
-spec format_duration(number()) -> iolist().
format_duration(Us) when Us < 1000 ->
    io_lib:format("~Bus", [Us]);
format_duration(Us) ->
    Ms = Us / 1000,
    io_lib:format("~.1fms", [Ms]).

%%--------------------------------------------------------------------
%% Internal functions (continued)
%%--------------------------------------------------------------------

%% @doc Check if a single benchmark passes its thresholds.
check_single_threshold(Name, Stats, Thresholds) ->
    case maps:get(Name, Thresholds, undefined) of
        undefined -> true;
        BenchThresholds ->
            maps:fold(fun(Metric, Limit, Acc) ->
                Actual = maps:get(Metric, Stats),
                Acc andalso (Actual < Limit)
            end, true, BenchThresholds)
    end.
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
rebar3 eunit --module loom_bench_stats_tests
```

Expected: All 13 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add test/bench/loom_bench_stats.erl test/bench/loom_bench_stats_tests.erl
git commit -m "feat(bench): add JSON output and console table formatting to loom_bench_stats

Refs #14"
```

---

### Task 5: Benchmark suite — skeleton + protocol group

**Files:**
- Create: `test/bench/loom_bench_SUITE.erl`

- [ ] **Step 1: Write the suite skeleton with protocol group**

Create `test/bench/loom_bench_SUITE.erl`:

```erlang
%%%-------------------------------------------------------------------
%%% @doc Benchmark suite for measuring Port communication overhead.
%%%
%%% Run: rebar3 ct --dir test/bench --suite loom_bench_SUITE
%%% Strict: BENCH_STRICT=true rebar3 ct --dir test/bench --suite loom_bench_SUITE
%%%
%%% Results: _build/bench/results.json + console table
%%% @end
%%%-------------------------------------------------------------------
-module(loom_bench_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Protocol group
-export([
    encode_decode_health/1,
    encode_decode_generate/1,
    encode_decode_large/1
]).

%% Port group
-export([
    health_roundtrip/1,
    token_overhead/1
]).

%% Coordinator group
-export([
    coordinator_ets_read/1,
    coordinator_generate/1
]).

%% Concurrent group
-export([
    concurrent_10/1,
    concurrent_50/1,
    concurrent_100/1
]).

%% Large messages group
-export([
    large_4k/1,
    large_16k/1,
    large_64k/1
]).

%% Pre-encoded inbound JSON for protocol benchmarks (avoids measuring
%% binary construction overhead during the benchmark loop).
-define(HEALTH_RESPONSE_JSON,
    <<"{\"type\":\"health\",\"status\":\"ok\",\"gpu_util\":0.0,"
      "\"mem_used_gb\":0.0,\"mem_total_gb\":80.0}">>).
-define(TOKEN_RESPONSE_JSON,
    <<"{\"type\":\"token\",\"id\":\"bench\",\"token_id\":1,"
      "\"text\":\"hello\",\"finished\":false}">>).

%% Threshold map: benchmark_name => #{metric => max_microseconds}.
-define(THRESHOLDS, #{
    health_roundtrip => #{p50 => 1000, p99 => 2000},
    token_overhead => #{p50 => 500},
    encode_decode_health => #{p50 => 100},
    encode_decode_generate => #{p50 => 100}
}).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [{group, protocol},
     {group, port},
     {group, coordinator},
     {group, concurrent},
     {group, large_messages}].

groups() ->
    [{protocol, [sequence], [
        encode_decode_health,
        encode_decode_generate,
        encode_decode_large
    ]},
     {port, [sequence], [
        health_roundtrip,
        token_overhead
    ]},
     {coordinator, [sequence], [
        coordinator_ets_read,
        coordinator_generate
    ]},
     {concurrent, [sequence], [
        concurrent_10,
        concurrent_50,
        concurrent_100
    ]},
     {large_messages, [sequence], [
        large_4k,
        large_16k,
        large_64k
    ]}].

init_per_suite(Config) ->
    %% ASSUMPTION: loom_config:load/1 must be called before starting loom
    %% so that loom_app:start/2 skips file-based config resolution.
    ok = loom_config:load(fixture_path("minimal.json")),
    {ok, _} = application:ensure_all_started(loom),
    ets:new(loom_bench_results, [named_table, public, set]),
    Config.

end_per_suite(_Config) ->
    %% Collect all results
    Results = lists:sort(ets:tab2list(loom_bench_results)),
    ets:delete(loom_bench_results),

    %% Print console table
    Table = loom_bench_stats:format_table(Results),
    ct:pal("~s", [Table]),

    %% Check thresholds
    ThresholdResults = loom_bench_stats:check_thresholds(Results, ?THRESHOLDS),
    log_threshold_results(ThresholdResults),

    %% Write JSON
    StrictMode = os:getenv("BENCH_STRICT") =:= "true",
    JsonBin = loom_bench_stats:to_json(Results,
        #{strict_mode => StrictMode, thresholds => ?THRESHOLDS}),
    ResultsDir = filename:join(["_build", "bench"]),
    filelib:ensure_dir(filename:join(ResultsDir, "dummy")),
    ResultsFile = filename:join(ResultsDir, "results.json"),
    ok = file:write_file(ResultsFile, JsonBin),
    ct:pal("Results written to ~s", [ResultsFile]),

    %% Enforce thresholds in strict mode
    case StrictMode of
        true ->
            Failures = [R || {_, fail, _} = R <- ThresholdResults],
            case Failures of
                [] -> ok;
                _ -> ct:fail({threshold_violations, Failures})
            end;
        false ->
            ok
    end,

    application:stop(loom),
    ok.

init_per_group(protocol, Config) ->
    Config;
init_per_group(port, Config) ->
    process_flag(trap_exit, true),
    Opts = #{
        command => python_cmd(),
        args => [mock_adapter_path(), "--token-delay", "0",
                 "--startup-delay", "0", "--heartbeat-interval", "5"],
        owner => self(),
        spawn_timeout_ms => 10000,
        heartbeat_timeout_ms => 15000,
        max_line_length => 1048576
    },
    {ok, Pid} = loom_port:start_link(Opts),
    Ref = wait_port_ready(Pid),
    [{port_pid, Pid}, {port_ref, Ref} | Config];
init_per_group(Group, Config) when Group =:= coordinator;
                                   Group =:= concurrent;
                                   Group =:= large_messages ->
    process_flag(trap_exit, true),
    EngineId = list_to_binary("bench_" ++ atom_to_list(Group)),
    MaxConcurrent = case Group of
        concurrent -> 200;
        _ -> 64
    end,
    CoordConfig = #{
        engine_id => EngineId,
        command => python_cmd(),
        args => [mock_adapter_path(), "--token-delay", "0",
                 "--startup-delay", "0", "--heartbeat-interval", "5"],
        model => <<"mock">>,
        backend => <<"mock">>,
        startup_timeout_ms => 10000,
        drain_timeout_ms => 5000,
        max_concurrent => MaxConcurrent
    },
    {ok, Pid} = loom_engine_coordinator:start_link(CoordConfig),
    wait_coordinator_ready(EngineId, 10000),
    [{coord_pid, Pid}, {engine_id, EngineId} | Config].

end_per_group(protocol, _Config) ->
    ok;
end_per_group(port, Config) ->
    PortPid = ?config(port_pid, Config),
    loom_port:shutdown(PortPid),
    wait_process_dead(PortPid, 5000),
    ok;
end_per_group(_Group, Config) ->
    CoordPid = ?config(coord_pid, Config),
    loom_engine_coordinator:stop(CoordPid),
    wait_process_dead(CoordPid, 5000),
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%%====================================================================
%% Protocol group benchmarks
%%====================================================================

encode_decode_health(_Config) ->
    Msg = {health},
    Samples = time_iterations(fun() ->
        _Encoded = loom_protocol:encode(Msg),
        {ok, _} = loom_protocol:decode(?HEALTH_RESPONSE_JSON)
    end, 10000),
    store_result(encode_decode_health, Samples).

encode_decode_generate(_Config) ->
    Msg = {generate, <<"bench-id">>, <<"Hello world">>, #{max_tokens => 100}},
    Samples = time_iterations(fun() ->
        _Encoded = loom_protocol:encode(Msg),
        {ok, _} = loom_protocol:decode(?TOKEN_RESPONSE_JSON)
    end, 10000),
    store_result(encode_decode_generate, Samples).

encode_decode_large(_Config) ->
    Sizes = [{encode_large_4k, 4096},
             {encode_large_16k, 16384},
             {encode_large_64k, 65536}],
    lists:foreach(fun({Name, Size}) ->
        Prompt = binary:copy(<<"x">>, Size),
        Msg = {generate, <<"bench-id">>, Prompt, #{max_tokens => 100}},
        Samples = time_iterations(fun() ->
            _Encoded = loom_protocol:encode(Msg)
        end, 1000),
        store_result(Name, Samples)
    end, Sizes).

%%====================================================================
%% Port group benchmarks (placeholder — implemented in Task 6)
%%====================================================================

health_roundtrip(_Config) ->
    store_result(health_roundtrip, [0]).

token_overhead(_Config) ->
    store_result(token_overhead, [0]).

%%====================================================================
%% Coordinator group benchmarks (placeholder — implemented in Task 7)
%%====================================================================

coordinator_ets_read(_Config) ->
    store_result(coordinator_ets_read, [0]).

coordinator_generate(_Config) ->
    store_result(coordinator_generate, [0]).

%%====================================================================
%% Concurrent group benchmarks (placeholder — implemented in Task 8)
%%====================================================================

concurrent_10(_Config) ->
    store_result(concurrent_10, [0]).

concurrent_50(_Config) ->
    store_result(concurrent_50, [0]).

concurrent_100(_Config) ->
    store_result(concurrent_100, [0]).

%%====================================================================
%% Large messages group benchmarks (placeholder — implemented in Task 9)
%%====================================================================

large_4k(_Config) ->
    store_result(large_4k, [0]).

large_16k(_Config) ->
    store_result(large_16k, [0]).

large_64k(_Config) ->
    store_result(large_64k, [0]).

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Time N iterations of Fun, return list of microsecond timings.
time_iterations(Fun, N) ->
    lists:map(fun(_) ->
        T0 = erlang:monotonic_time(microsecond),
        Fun(),
        erlang:monotonic_time(microsecond) - T0
    end, lists:seq(1, N)).

%% @doc Store benchmark result in the shared ETS table.
store_result(Name, Samples) ->
    Stats = loom_bench_stats:calculate(Samples),
    true = ets:insert(loom_bench_results, {Name, Stats}).

%% @doc Path to the mock adapter script.
mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

%% @doc Python 3 executable path.
python_cmd() ->
    os:find_executable("python3").

%% @doc Path to test fixture file.
fixture_path(Filename) ->
    filename:join(["test", "fixtures", Filename]).

%% @doc Wait for loom_port to send ready message, return the port ref.
wait_port_ready(Pid) ->
    receive
        {loom_port_ready, Ref, _Model, _Backend} -> Ref
    after 10000 ->
        ct:fail({port_ready_timeout, loom_port:get_state(Pid)})
    end.

%% @doc Poll coordinator status until ready or timeout.
wait_coordinator_ready(EngineId, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_status(EngineId) of
        ready -> ok;
        _ ->
            timer:sleep(50),
            wait_coordinator_ready(EngineId, Timeout - 50)
    end;
wait_coordinator_ready(EngineId, _Timeout) ->
    ct:fail({coordinator_ready_timeout, EngineId}).

%% @doc Wait for a process to terminate.
wait_process_dead(Pid, Timeout) when Timeout > 0 ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(50),
            wait_process_dead(Pid, Timeout - 50)
    end;
wait_process_dead(Pid, _Timeout) ->
    ct:fail({process_still_alive, Pid}).

%% @doc Log threshold check results.
log_threshold_results(Results) ->
    Passed = length([R || {_, pass, _} = R <- Results]),
    Failed = length([R || {_, fail, _} = R <- Results]),
    Total = Passed + Failed,
    lists:foreach(fun
        ({Name, pass, _}) ->
            ct:pal("[PASS] ~s", [Name]);
        ({Name, fail, Violations}) ->
            lists:foreach(fun({Metric, Actual, Limit}) ->
                ct:pal("[WARN] ~s.~s: ~s >= ~s (limit)",
                    [Name, Metric,
                     loom_bench_stats:format_duration(Actual),
                     loom_bench_stats:format_duration(Limit)])
            end, Violations)
    end, Results),
    ct:pal("Threshold checks: ~B/~B PASS", [Passed, Total]).
```

- [ ] **Step 2: Run the suite to verify protocol group works**

```bash
rebar3 ct --dir test/bench --suite loom_bench_SUITE
```

Expected: All groups PASS (placeholder test cases return `[0]` samples). Protocol group produces real measurements. Console table and JSON file are generated.

- [ ] **Step 3: Verify JSON output exists**

```bash
cat _build/bench/results.json | python3 -m json.tool
```

Expected: Valid JSON with `encode_decode_health`, `encode_decode_generate`, `encode_large_4k/16k/64k` benchmarks showing real microsecond values, plus placeholder `0` values for other groups.

- [ ] **Step 4: Commit**

```bash
git add test/bench/loom_bench_SUITE.erl
git commit -m "feat(bench): add benchmark suite skeleton with protocol group

Protocol group measures loom_protocol encode/decode overhead in
isolation. Other groups are placeholders to be implemented next.

Refs #14"
```

---

### Task 6: Port group benchmarks

**Files:**
- Modify: `test/bench/loom_bench_SUITE.erl`

- [ ] **Step 1: Replace port group placeholders with real benchmarks**

Replace the port group section in `test/bench/loom_bench_SUITE.erl`:

```erlang
%%====================================================================
%% Port group benchmarks
%%====================================================================

health_roundtrip(Config) ->
    PortPid = ?config(port_pid, Config),
    PortRef = ?config(port_ref, Config),
    Samples = lists:map(fun(_) ->
        T0 = erlang:monotonic_time(microsecond),
        ok = loom_port:send(PortPid, {health}),
        receive
            {loom_port_msg, PortRef, {health_response, _, _, _, _}} ->
                erlang:monotonic_time(microsecond) - T0
        after 5000 ->
            ct:fail(health_response_timeout)
        end
    end, lists:seq(1, 1000)),
    store_result(health_roundtrip, Samples).

token_overhead(Config) ->
    PortPid = ?config(port_pid, Config),
    PortRef = ?config(port_ref, Config),
    %% ASSUMPTION: Mock adapter produces 5 tokens per generate request.
    TokensPerRequest = 5,
    AllSamples = lists:flatmap(fun(I) ->
        Id = integer_to_binary(I),
        ok = loom_port:send(PortPid,
            {generate, Id, <<"bench prompt">>, #{max_tokens => 100}}),
        TokenTimestamps = collect_port_token_timestamps(PortRef, Id, TokensPerRequest),
        %% Wait for done message
        receive
            {loom_port_msg, PortRef, {done, Id, _, _}} -> ok
        after 5000 ->
            ct:fail(done_timeout)
        end,
        inter_token_deltas(TokenTimestamps)
    end, lists:seq(1, 500)),
    store_result(token_overhead, AllSamples).
```

- [ ] **Step 2: Add the port-level timing helpers**

Add to the Helpers section:

```erlang
%% @doc Collect timestamps for each token arrival from loom_port.
%% Returns list of monotonic timestamps in microseconds.
collect_port_token_timestamps(PortRef, Id, N) ->
    collect_port_token_timestamps(PortRef, Id, N, []).

collect_port_token_timestamps(_PortRef, _Id, 0, Acc) ->
    lists:reverse(Acc);
collect_port_token_timestamps(PortRef, Id, N, Acc) ->
    receive
        {loom_port_msg, PortRef, {token, Id, _, _, _}} ->
            T = erlang:monotonic_time(microsecond),
            collect_port_token_timestamps(PortRef, Id, N - 1, [T | Acc])
    after 5000 ->
        ct:fail({token_timeout, {remaining, N}})
    end.

%% @doc Calculate deltas between consecutive timestamps.
%% [T1, T2, T3] -> [T2-T1, T3-T2]
inter_token_deltas([]) -> [];
inter_token_deltas([_]) -> [];
inter_token_deltas(Timestamps) ->
    Pairs = lists:zip(lists:droplast(Timestamps), tl(Timestamps)),
    [B - A || {A, B} <- Pairs].
```

- [ ] **Step 3: Run the suite to verify port group**

```bash
rebar3 ct --dir test/bench --suite loom_bench_SUITE --group port
```

Expected: `health_roundtrip` and `token_overhead` PASS with real microsecond measurements.

- [ ] **Step 4: Commit**

```bash
git add test/bench/loom_bench_SUITE.erl
git commit -m "feat(bench): implement port group benchmarks — health roundtrip and token overhead

Measures direct loom_port:send/2 round-trip latency and inter-token
delivery latency through the Port + Python mock adapter.

Refs #14"
```

---

### Task 7: Coordinator group benchmarks

**Files:**
- Modify: `test/bench/loom_bench_SUITE.erl`

- [ ] **Step 1: Replace coordinator group placeholders with real benchmarks**

Replace the coordinator group section:

```erlang
%%====================================================================
%% Coordinator group benchmarks
%%====================================================================

coordinator_ets_read(Config) ->
    EngineId = ?config(engine_id, Config),
    Samples = time_iterations(fun() ->
        _Status = loom_engine_coordinator:get_status(EngineId),
        _Load = loom_engine_coordinator:get_load(EngineId),
        _Info = loom_engine_coordinator:get_info(EngineId)
    end, 10000),
    store_result(coordinator_ets_read, Samples).

coordinator_generate(Config) ->
    CoordPid = ?config(coord_pid, Config),
    %% ASSUMPTION: Mock adapter produces 5 tokens per generate request.
    TokensPerRequest = 5,
    Samples = lists:map(fun(_) ->
        T0 = erlang:monotonic_time(microsecond),
        {ok, ReqId} = loom_engine_coordinator:generate(
            CoordPid, <<"bench prompt">>, #{max_tokens => 100}),
        collect_coordinator_tokens(ReqId, TokensPerRequest),
        receive
            {loom_done, ReqId, _Stats} ->
                erlang:monotonic_time(microsecond) - T0
        after 5000 ->
            ct:fail(coordinator_done_timeout)
        end
    end, lists:seq(1, 500)),
    store_result(coordinator_generate, Samples).
```

- [ ] **Step 2: Add the coordinator-level token collection helper**

Add to the Helpers section:

```erlang
%% @doc Collect N token messages from the coordinator for a given request.
collect_coordinator_tokens(_ReqId, 0) ->
    ok;
collect_coordinator_tokens(ReqId, N) ->
    receive
        {loom_token, ReqId, _Text, _Finished} ->
            collect_coordinator_tokens(ReqId, N - 1)
    after 5000 ->
        ct:fail({coordinator_token_timeout, {remaining, N}})
    end.
```

- [ ] **Step 3: Run the suite to verify coordinator group**

```bash
rebar3 ct --dir test/bench --suite loom_bench_SUITE --group coordinator
```

Expected: `coordinator_ets_read` and `coordinator_generate` PASS with real measurements. ETS reads should be sub-microsecond to single-digit microseconds.

- [ ] **Step 4: Commit**

```bash
git add test/bench/loom_bench_SUITE.erl
git commit -m "feat(bench): implement coordinator group — ETS reads and full-path generate

Measures lock-free ETS read latency and end-to-end generate request
through loom_engine_coordinator.

Refs #14"
```

---

### Task 8: Concurrent group benchmarks

**Files:**
- Modify: `test/bench/loom_bench_SUITE.erl`

- [ ] **Step 1: Replace concurrent group placeholders with real benchmarks**

Replace the concurrent group section:

```erlang
%%====================================================================
%% Concurrent group benchmarks
%%====================================================================

concurrent_10(Config) ->
    run_concurrent_bench(10, 100, Config).

concurrent_50(Config) ->
    run_concurrent_bench(50, 50, Config).

concurrent_100(Config) ->
    run_concurrent_bench(100, 20, Config).
```

- [ ] **Step 2: Add the concurrent benchmark runner helper**

Add to the Helpers section:

```erlang
%% @doc Run N concurrent generate requests for Rounds rounds, collect
%% per-request latency samples. Uses barrier sync so all workers start
%% simultaneously.
%% ASSUMPTION: Mock adapter produces 5 tokens per generate request.
run_concurrent_bench(N, Rounds, Config) ->
    CoordPid = ?config(coord_pid, Config),
    TokensPerRequest = 5,
    AllSamples = lists:flatmap(fun(_Round) ->
        BarrierRef = make_ref(),
        Parent = self(),
        Workers = [spawn_link(fun() ->
            %% Wait for barrier release
            receive {go, BarrierRef} -> ok end,
            T0 = erlang:monotonic_time(microsecond),
            {ok, ReqId} = loom_engine_coordinator:generate(
                CoordPid, <<"bench concurrent">>, #{max_tokens => 100}),
            collect_coordinator_tokens(ReqId, TokensPerRequest),
            receive
                {loom_done, ReqId, _Stats} ->
                    Elapsed = erlang:monotonic_time(microsecond) - T0,
                    Parent ! {bench_done, self(), Elapsed}
            after 30000 ->
                Parent ! {bench_done, self(), timeout}
            end
        end) || _ <- lists:seq(1, N)],
        %% Release all workers simultaneously
        [W ! {go, BarrierRef} || W <- Workers],
        %% Collect results
        lists:map(fun(W) ->
            receive
                {bench_done, W, timeout} -> ct:fail({worker_timeout, W});
                {bench_done, W, Elapsed} -> Elapsed
            after 60000 ->
                ct:fail({collect_timeout, W})
            end
        end, Workers)
    end, lists:seq(1, Rounds)),
    BenchName = list_to_atom("concurrent_" ++ integer_to_list(N)),
    store_result(BenchName, AllSamples).
```

- [ ] **Step 3: Run the suite to verify concurrent group**

```bash
rebar3 ct --dir test/bench --suite loom_bench_SUITE --group concurrent
```

Expected: `concurrent_10`, `concurrent_50`, `concurrent_100` PASS. Latency distributions will be wider than single-request benchmarks due to serial mock adapter processing.

- [ ] **Step 4: Commit**

```bash
git add test/bench/loom_bench_SUITE.erl
git commit -m "feat(bench): implement concurrent group — barrier-synced parallel requests

Measures per-request latency under 10/50/100 concurrent generate
requests through the coordinator with barrier synchronization.

Refs #14"
```

---

### Task 9: Large messages group benchmarks

**Files:**
- Modify: `test/bench/loom_bench_SUITE.erl`

- [ ] **Step 1: Replace large messages group placeholders with real benchmarks**

Replace the large messages group section:

```erlang
%%====================================================================
%% Large messages group benchmarks
%%====================================================================

large_4k(Config) ->
    run_large_message_bench(large_4k, 4096, 200, Config).

large_16k(Config) ->
    run_large_message_bench(large_16k, 16384, 100, Config).

large_64k(Config) ->
    run_large_message_bench(large_64k, 65536, 50, Config).
```

- [ ] **Step 2: Add the large message benchmark runner helper**

Add to the Helpers section:

```erlang
%% @doc Benchmark generate requests with a large prompt through the coordinator.
%% ASSUMPTION: Mock adapter produces 5 tokens per generate request regardless
%% of prompt size.
run_large_message_bench(Name, PromptSize, Iterations, Config) ->
    CoordPid = ?config(coord_pid, Config),
    TokensPerRequest = 5,
    Prompt = binary:copy(<<"x">>, PromptSize),
    Samples = lists:map(fun(_) ->
        T0 = erlang:monotonic_time(microsecond),
        {ok, ReqId} = loom_engine_coordinator:generate(
            CoordPid, Prompt, #{max_tokens => 100}),
        collect_coordinator_tokens(ReqId, TokensPerRequest),
        receive
            {loom_done, ReqId, _Stats} ->
                erlang:monotonic_time(microsecond) - T0
        after 10000 ->
            ct:fail({large_msg_done_timeout, Name})
        end
    end, lists:seq(1, Iterations)),
    store_result(Name, Samples).
```

- [ ] **Step 3: Run the suite to verify large messages group**

```bash
rebar3 ct --dir test/bench --suite loom_bench_SUITE --group large_messages
```

Expected: `large_4k`, `large_16k`, `large_64k` PASS. Latency should increase with prompt size due to JSON encoding and Port I/O overhead.

- [ ] **Step 4: Commit**

```bash
git add test/bench/loom_bench_SUITE.erl
git commit -m "feat(bench): implement large messages group — 4K/16K/64K prompt benchmarks

Measures full-path generate latency with large prompts to quantify
serialization and Port I/O overhead scaling.

Refs #14"
```

---

### Task 10: Full suite run and reporting verification

**Files:**
- No new files — verify existing implementation

- [ ] **Step 1: Run the complete benchmark suite**

```bash
rebar3 ct --dir test/bench --suite loom_bench_SUITE
```

Expected: All 5 groups pass. Console output shows formatted table with all benchmarks.

- [ ] **Step 2: Verify JSON output**

```bash
cat _build/bench/results.json | python3 -m json.tool
```

Expected: Valid JSON with all benchmark names, each containing `min_us`, `max_us`, `mean_us`, `p50_us`, `p80_us`, `p95_us`, `p99_us`, `samples`, `threshold_pass`.

- [ ] **Step 3: Verify strict mode warns but does not fail**

```bash
rebar3 ct --dir test/bench --suite loom_bench_SUITE 2>&1 | grep -E "\[WARN\]|\[PASS\]|Threshold"
```

Expected: Shows `[PASS]` or `[WARN]` lines for each benchmark with a threshold, plus a summary line like `Threshold checks: 5/5 PASS`.

- [ ] **Step 4: Verify strict mode enforces thresholds**

```bash
BENCH_STRICT=true rebar3 ct --dir test/bench --suite loom_bench_SUITE
```

Expected: Passes if all thresholds are met, fails with `{threshold_violations, ...}` if any are exceeded.

- [ ] **Step 5: Verify existing tests are not affected**

```bash
rebar3 eunit && rebar3 ct --verbose
```

Expected: All existing EUnit and CT tests pass. The bench suite is NOT run by `rebar3 ct --verbose` (it only searches `test/`, not `test/bench/`).

- [ ] **Step 6: Commit (if any fixes were needed)**

Only commit if fixes were made in previous steps:

```bash
git add test/bench/
git commit -m "fix(bench): address issues found during full suite verification

Refs #14"
```

---

### Task 11: CI integration

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add bench job to ci.yml**

Add the following job after the `analysis` job in `.github/workflows/ci.yml`:

```yaml
  bench:
    name: Benchmarks
    runs-on: ubuntu-24.04
    needs: build
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # v4

      - name: Set up Erlang/OTP
        uses: erlef/setup-beam@ee09b1e59bb240681c382eb1f0abc6a04af72764  # v1
        with:
          otp-version: ${{ env.OTP_VERSION }}
          rebar3-version: ${{ env.REBAR3_VERSION }}

      - name: Restore cache
        uses: actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830  # v4
        with:
          path: |
            _build
            ~/.cache/rebar3
          key: ${{ runner.os }}-otp${{ env.OTP_VERSION }}-${{ hashFiles('rebar.lock') }}
          restore-keys: |
            ${{ runner.os }}-otp${{ env.OTP_VERSION }}-

      - name: Run benchmarks
        run: rebar3 ct --dir test/bench --suite loom_bench_SUITE

      - name: Upload results
        uses: actions/upload-artifact@v4
        with:
          name: bench-results
          path: _build/bench/results.json
        if: always()
```

- [ ] **Step 2: Verify YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add optional benchmark job with artifact upload

Runs Port communication benchmarks after build, uploads results.json
as artifact. Does not gate merges — report-only mode.

Refs #14"
```

---

### Task 12: Final verification and cleanup

**Files:**
- No new files

- [ ] **Step 1: Run the full test suite (existing + bench)**

```bash
rebar3 eunit && rebar3 ct --verbose && rebar3 ct --dir test/bench --suite loom_bench_SUITE
```

Expected: All tests pass. Benchmark produces console table and JSON.

- [ ] **Step 2: Run Dialyzer**

```bash
rebar3 dialyzer
```

Expected: No warnings from bench modules (they are in `extra_src_dirs` so Dialyzer may or may not analyze them — verify either way).

- [ ] **Step 3: Run Xref**

```bash
rebar3 xref
```

Expected: No undefined function calls from bench modules.

- [ ] **Step 4: Review JSON output one final time**

```bash
cat _build/bench/results.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'Benchmarks: {len(data[\"benchmarks\"])}')
print(f'Overall pass: {data[\"pass\"]}')
for name, bench in sorted(data['benchmarks'].items()):
    print(f'  {name}: p50={bench[\"p50_us\"]}us p99={bench[\"p99_us\"]}us samples={bench[\"samples\"]}')
"
```

Expected: Lists all benchmarks with non-zero samples and reasonable microsecond values.

- [ ] **Step 5: Final commit if needed, then squash-ready summary**

If any cleanup was done, commit it. Then verify the full commit log for this feature:

```bash
git log --oneline main..HEAD
```

Expected: Clean series of commits all referencing `#14`.
