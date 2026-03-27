-module(loom_handler_models_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([models_list/1, models_no_engine/1]).

all() -> [models_list, models_no_engine].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    DataDir = ?config(data_dir, Config),
    ok = loom_config:load(filename:join(DataDir, "loom.json")),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    catch loom_http:stop(),
    catch loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

init_per_testcase(_TC, Config) ->
    %% ASSUMPTION: CT runs init_per_suite in a temporary process whose death
    %% destroys ETS tables it created. Reload config each test case.
    DataDir = ?config(data_dir, Config),
    ok = loom_config:load(filename:join(DataDir, "loom.json")),
    Config.

end_per_testcase(_TC, _Config) -> ok.

models_list(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18082),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/v1/models"),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual(<<"list">>, maps:get(<<"object">>, Decoded)),
    [Model] = maps:get(<<"data">>, Decoded),
    ?assertEqual(<<"mock">>, maps:get(<<"id">>, Model)),
    gun:close(ConnPid).

models_no_engine(_Config) ->
    %% Temporarily override engine names in ETS to simulate nonexistent engine
    ets:insert(loom_config, {{engine, names}, [<<"nonexistent">>]}),
    {ok, ConnPid} = gun:open("127.0.0.1", 18082),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/v1/models"),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual([], maps:get(<<"data">>, Decoded)),
    %% Restore engine names
    ets:insert(loom_config, {{engine, names}, [<<"engine_0">>]}),
    gun:close(ConnPid).
