-module(loom_handler_health_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([health_ready/1, health_no_engine/1]).

all() -> [health_ready, health_no_engine].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    application:set_env(loom, http, #{port => 18081, engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    catch loom_http:stop(),
    catch loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

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
    %% Use a nonexistent engine_id
    application:set_env(loom, http, #{port => 18081, engine_id => <<"nonexistent">>}),
    {ok, ConnPid} = gun:open("127.0.0.1", 18081),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, 503, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual(<<"stopped">>, maps:get(<<"status">>, Decoded)),
    %% Restore config
    application:set_env(loom, http, #{port => 18081, engine_id => <<"engine_0">>}),
    gun:close(ConnPid).
