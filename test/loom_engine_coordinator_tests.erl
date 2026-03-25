-module(loom_engine_coordinator_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Config validation tests ---

-spec valid_config_test() -> any().
valid_config_test() ->
    Config = valid_config(),
    ?assertEqual(ok, loom_engine_coordinator:validate_config(Config)).

-spec missing_engine_id_test() -> any().
missing_engine_id_test() ->
    Config = maps:remove(engine_id, valid_config()),
    ?assertMatch({error, {missing_required, engine_id}},
                 loom_engine_coordinator:validate_config(Config)).

-spec missing_command_test() -> any().
missing_command_test() ->
    Config = maps:remove(command, valid_config()),
    ?assertMatch({error, {missing_required, command}},
                 loom_engine_coordinator:validate_config(Config)).

-spec missing_model_test() -> any().
missing_model_test() ->
    Config = maps:remove(model, valid_config()),
    ?assertMatch({error, {missing_required, model}},
                 loom_engine_coordinator:validate_config(Config)).

-spec missing_backend_test() -> any().
missing_backend_test() ->
    Config = maps:remove(backend, valid_config()),
    ?assertMatch({error, {missing_required, backend}},
                 loom_engine_coordinator:validate_config(Config)).

-spec empty_engine_id_test() -> any().
empty_engine_id_test() ->
    Config = (valid_config())#{engine_id => <<>>},
    ?assertMatch({error, {empty_required, engine_id}},
                 loom_engine_coordinator:validate_config(Config)).

-spec invalid_startup_timeout_test() -> any().
invalid_startup_timeout_test() ->
    Config = (valid_config())#{startup_timeout_ms => 0},
    ?assertMatch({error, {invalid_value, startup_timeout_ms, _}},
                 loom_engine_coordinator:validate_config(Config)).

-spec invalid_max_concurrent_test() -> any().
invalid_max_concurrent_test() ->
    Config = (valid_config())#{max_concurrent => -1},
    ?assertMatch({error, {invalid_value, max_concurrent, _}},
                 loom_engine_coordinator:validate_config(Config)).

-spec defaults_applied_test() -> any().
defaults_applied_test() ->
    Config = valid_config(),
    {ok, Merged} = loom_engine_coordinator:merge_config(Config),
    ?assertEqual(120000, maps:get(startup_timeout_ms, Merged)),
    ?assertEqual(30000, maps:get(drain_timeout_ms, Merged)),
    ?assertEqual(64, maps:get(max_concurrent, Merged)),
    ?assertEqual([], maps:get(args, Merged)).

-spec defaults_not_overridden_test() -> any().
defaults_not_overridden_test() ->
    Config = (valid_config())#{startup_timeout_ms => 5000, max_concurrent => 10},
    {ok, Merged} = loom_engine_coordinator:merge_config(Config),
    ?assertEqual(5000, maps:get(startup_timeout_ms, Merged)),
    ?assertEqual(10, maps:get(max_concurrent, Merged)).

%% --- Helpers ---

valid_config() ->
    #{
        engine_id => <<"engine_0">>,
        command => "/usr/bin/python3",
        model => <<"mock">>,
        backend => <<"mock">>
    }.
