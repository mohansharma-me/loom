-module(loom_handler_health_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([health_ready/1, health_no_engine/1]).

all() -> [health_ready, health_no_engine].

init_per_suite(Config) ->
    %% ASSUMPTION: Handler tests need isolated control with a mock coordinator,
    %% not the full loom application. Starting loom would launch loom_sup which
    %% starts loom_http_server (Cowboy), causing an already_started error when
    %% we call loom_http:start() below. Start only the dependencies we need.
    DataDir = ?config(data_dir, Config),
    ok = loom_config:load(filename:join(DataDir, "loom.json")),
    {ok, _} = application:ensure_all_started(cowboy),
    {ok, _} = application:ensure_all_started(gun),
    %% Stop any leftover loom app / Cowboy listener from a prior suite
    catch application:stop(loom),
    catch cowboy:stop_listener(loom_http_listener),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    catch loom_http:stop(),
    catch loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

init_per_testcase(_TC, Config) ->
    %% Reload config each test case to ensure a clean ETS baseline.
    %% Tests like health_no_engine directly mutate ETS keys.
    DataDir = ?config(data_dir, Config),
    ok = loom_config:load(filename:join(DataDir, "loom.json")),
    Config.

end_per_testcase(_TC, _Config) -> ok.

health_ready(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18081),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual(<<"ready">>, maps:get(<<"status">>, Decoded)),
    gun:close(ConnPid).

health_no_engine(_Config) ->
    %% Temporarily override engine names in ETS to simulate nonexistent engine
    ets:insert(loom_config, {{engine, names}, [<<"nonexistent">>]}),
    try
        {ok, ConnPid} = gun:open("127.0.0.1", 18081),
        {ok, _} = gun:await_up(ConnPid),
        StreamRef = gun:get(ConnPid, "/health"),
        {response, nofin, 503, _} = gun:await(ConnPid, StreamRef),
        {ok, Body} = gun:await_body(ConnPid, StreamRef),
        Decoded = loom_json:decode(Body),
        ?assertEqual(<<"stopped">>, maps:get(<<"status">>, Decoded)),
        gun:close(ConnPid)
    after
        ets:insert(loom_config, {{engine, names}, [<<"engine_0">>]})
    end.
