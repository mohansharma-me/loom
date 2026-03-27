-module(loom_handler_models_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([models_list/1, models_no_engine/1]).

all() -> [models_list, models_no_engine].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    application:set_env(loom, http, #{port => 18082, engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    catch loom_http:stop(),
    catch loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

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
    application:set_env(loom, http, #{port => 18082, engine_id => <<"nonexistent">>}),
    {ok, ConnPid} = gun:open("127.0.0.1", 18082),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/v1/models"),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual([], maps:get(<<"data">>, Decoded)),
    application:set_env(loom, http, #{port => 18082, engine_id => <<"engine_0">>}),
    gun:close(ConnPid).
