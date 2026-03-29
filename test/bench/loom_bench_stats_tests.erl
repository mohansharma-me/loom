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
