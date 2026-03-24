-module(loom_gpu_backend_nvidia_tests).
-include_lib("eunit/include/eunit.hrl").

-spec parse_normal_output_test() -> any().
parse_normal_output_test() ->
    Line = "73, 62400, 81920, 71, 245, 0",
    {ok, M} = loom_gpu_backend_nvidia:parse_nvidia_csv(Line),
    ?assertEqual(73.0, maps:get(gpu_util, M)),
    ?assert(maps:get(mem_used_gb, M) > 59.0),
    ?assert(maps:get(mem_total_gb, M) > 78.0),
    ?assertEqual(71.0, maps:get(temperature_c, M)),
    ?assertEqual(245.0, maps:get(power_w, M)),
    ?assertEqual(0, maps:get(ecc_errors, M)).

-spec parse_with_extra_whitespace_test() -> any().
parse_with_extra_whitespace_test() ->
    Line = " 50 , 40960 , 81920 , 65 , 200 , 3 ",
    {ok, M} = loom_gpu_backend_nvidia:parse_nvidia_csv(Line),
    ?assertEqual(50.0, maps:get(gpu_util, M)),
    ?assertEqual(65.0, maps:get(temperature_c, M)),
    ?assertEqual(3, maps:get(ecc_errors, M)).

-spec parse_not_available_fields_test() -> any().
parse_not_available_fields_test() ->
    Line = "73, 62400, 81920, 71, [Not Supported], [Not Supported]",
    {ok, M} = loom_gpu_backend_nvidia:parse_nvidia_csv(Line),
    ?assertEqual(73.0, maps:get(gpu_util, M)),
    ?assertEqual(-1.0, maps:get(power_w, M)),
    ?assertEqual(-1, maps:get(ecc_errors, M)).

-spec parse_decimal_values_test() -> any().
parse_decimal_values_test() ->
    Line = "73, 62400, 81920, 71, 245.50, 0",
    {ok, M} = loom_gpu_backend_nvidia:parse_nvidia_csv(Line),
    ?assertEqual(245.5, maps:get(power_w, M)).

-spec parse_wrong_field_count_test() -> any().
parse_wrong_field_count_test() ->
    Line = "73, 62400",
    ?assertMatch({error, {parse_error, _}}, loom_gpu_backend_nvidia:parse_nvidia_csv(Line)).

-spec parse_empty_string_test() -> any().
parse_empty_string_test() ->
    ?assertMatch({error, {parse_error, _}}, loom_gpu_backend_nvidia:parse_nvidia_csv("")).

-spec parse_garbage_test() -> any().
parse_garbage_test() ->
    ?assertMatch({error, {parse_error, _}}, loom_gpu_backend_nvidia:parse_nvidia_csv("not,csv,data,at,all,!")).

%% --- edge case tests ---

-spec parse_zero_values_test() -> any().
parse_zero_values_test() ->
    %% Cold-start GPU with zero memory used
    Line = "0, 0, 81920, 30, 50, 0",
    {ok, M} = loom_gpu_backend_nvidia:parse_nvidia_csv(Line),
    ?assertEqual(0.0, maps:get(gpu_util, M)),
    ?assertEqual(0.0, maps:get(mem_used_gb, M)),
    ?assertEqual(30.0, maps:get(temperature_c, M)).

-spec parse_all_not_supported_test() -> any().
parse_all_not_supported_test() ->
    %% Some older/embedded GPUs report all fields as unsupported
    Line = "[Not Supported], [Not Supported], [Not Supported], [Not Supported], [Not Supported], [Not Supported]",
    {ok, M} = loom_gpu_backend_nvidia:parse_nvidia_csv(Line),
    ?assertEqual(-1.0, maps:get(gpu_util, M)),
    ?assertEqual(-1.0, maps:get(mem_used_gb, M)),
    ?assertEqual(-1.0, maps:get(mem_total_gb, M)),
    ?assertEqual(-1.0, maps:get(temperature_c, M)),
    ?assertEqual(-1.0, maps:get(power_w, M)),
    ?assertEqual(-1, maps:get(ecc_errors, M)).

%% --- detect/0 test ---

-spec detect_returns_boolean_test() -> any().
detect_returns_boolean_test() ->
    Result = loom_gpu_backend_nvidia:detect(),
    ?assert(is_boolean(Result)).
