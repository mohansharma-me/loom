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

%% --- ETS table name helpers ---

-spec reqs_table_name_test() -> any().
reqs_table_name_test() ->
    ?assertEqual(loom_coord_reqs_engine_0,
                 loom_engine_coordinator:reqs_table_name(<<"engine_0">>)).

-spec meta_table_name_test() -> any().
meta_table_name_test() ->
    ?assertEqual(loom_coord_meta_engine_0,
                 loom_engine_coordinator:meta_table_name(<<"engine_0">>)).

%% --- ETS read API tests ---

-spec get_status_from_ets_test() -> any().
get_status_from_ets_test() ->
    MetaTable = loom_coord_meta_test_status,
    ets:new(MetaTable, [named_table, set, public]),
    ets:insert(MetaTable, {meta, ready, <<"test">>, <<"mock">>, <<"mock">>,
                           undefined, 0}),
    ?assertEqual(ready, loom_engine_coordinator:get_status(<<"test_status">>)),
    ets:delete(MetaTable).

-spec get_load_from_ets_test() -> any().
get_load_from_ets_test() ->
    ReqsTable = loom_coord_reqs_test_load,
    ets:new(ReqsTable, [named_table, set, public]),
    ets:insert(ReqsTable, {<<"req-1">>, self(), make_ref(), 0}),
    ets:insert(ReqsTable, {<<"req-2">>, self(), make_ref(), 0}),
    ?assertEqual(2, loom_engine_coordinator:get_load(<<"test_load">>)),
    ets:delete(ReqsTable).

-spec get_info_from_ets_test() -> any().
get_info_from_ets_test() ->
    MetaTable = loom_coord_meta_test_info,
    ReqsTable = loom_coord_reqs_test_info,
    ets:new(MetaTable, [named_table, set, public]),
    ets:new(ReqsTable, [named_table, set, public]),
    ets:insert(MetaTable, {meta, ready, <<"test_info">>, <<"mock_model">>,
                           <<"mock">>, undefined, 12345}),
    ets:insert(ReqsTable, {<<"req-1">>, self(), make_ref(), 0}),
    Info = loom_engine_coordinator:get_info(<<"test_info">>),
    ?assertEqual(<<"test_info">>, maps:get(engine_id, Info)),
    ?assertEqual(<<"mock_model">>, maps:get(model, Info)),
    ?assertEqual(ready, maps:get(status, Info)),
    ?assertEqual(1, maps:get(load, Info)),
    ets:delete(MetaTable),
    ets:delete(ReqsTable).

%% --- Request ID generation tests ---

-spec request_id_unique_test() -> any().
request_id_unique_test() ->
    Ids = [loom_engine_coordinator:generate_request_id() || _ <- lists:seq(1, 100)],
    UniqueIds = lists:usort(Ids),
    ?assertEqual(100, length(UniqueIds)).

-spec request_id_format_test() -> any().
request_id_format_test() ->
    Id = loom_engine_coordinator:generate_request_id(),
    ?assert(is_binary(Id)),
    ?assertMatch(<<"req-", _/binary>>, Id).

%% --- Helpers ---

valid_config() ->
    #{
        engine_id => <<"engine_0">>,
        command => "/usr/bin/python3",
        model => <<"mock">>,
        backend => <<"mock">>
    }.
