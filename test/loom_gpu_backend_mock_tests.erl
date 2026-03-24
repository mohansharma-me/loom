-module(loom_gpu_backend_mock_tests).
-include_lib("eunit/include/eunit.hrl").

-spec detect_always_true_test() -> any().
detect_always_true_test() ->
    ?assert(loom_gpu_backend_mock:detect()).

-spec init_default_metrics_test() -> any().
init_default_metrics_test() ->
    {ok, State} = loom_gpu_backend_mock:init(#{}),
    ?assert(is_map(State)).

-spec init_custom_metrics_test() -> any().
init_custom_metrics_test() ->
    Custom = #{
        gpu_util => 50.0, mem_used_gb => 4.0, mem_total_gb => 8.0,
        temperature_c => 65.0, power_w => 150.0, ecc_errors => 0
    },
    {ok, State} = loom_gpu_backend_mock:init(#{metrics => Custom}),
    {ok, Metrics, _} = loom_gpu_backend_mock:poll(State),
    ?assertEqual(Custom, Metrics).

-spec init_fail_mode_test() -> any().
init_fail_mode_test() ->
    {ok, State} = loom_gpu_backend_mock:init(#{fail_poll => true}),
    ?assertMatch({error, _}, loom_gpu_backend_mock:poll(State)).

-spec poll_returns_default_metrics_test() -> any().
poll_returns_default_metrics_test() ->
    {ok, State} = loom_gpu_backend_mock:init(#{}),
    {ok, Metrics, NewState} = loom_gpu_backend_mock:poll(State),
    ?assert(maps:is_key(gpu_util, Metrics)),
    ?assert(maps:is_key(mem_used_gb, Metrics)),
    ?assert(maps:is_key(mem_total_gb, Metrics)),
    ?assert(maps:is_key(temperature_c, Metrics)),
    ?assert(maps:is_key(power_w, Metrics)),
    ?assert(maps:is_key(ecc_errors, Metrics)),
    ?assertEqual(State, NewState).

-spec poll_returns_same_metrics_each_time_test() -> any().
poll_returns_same_metrics_each_time_test() ->
    {ok, State} = loom_gpu_backend_mock:init(#{}),
    {ok, M1, S1} = loom_gpu_backend_mock:poll(State),
    {ok, M2, _S2} = loom_gpu_backend_mock:poll(S1),
    ?assertEqual(M1, M2).

-spec terminate_returns_ok_test() -> any().
terminate_returns_ok_test() ->
    {ok, State} = loom_gpu_backend_mock:init(#{}),
    ?assertEqual(ok, loom_gpu_backend_mock:terminate(State)).
