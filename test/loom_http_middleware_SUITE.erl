-module(loom_http_middleware_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    request_id_attached/1,
    content_type_rejected/1,
    get_request_passes/1
]).

all() -> [request_id_attached, content_type_rejected, get_request_passes].

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
    %% ASSUMPTION: CT runs init_per_suite in a temporary process whose death
    %% destroys ETS tables it created. Reload config each test case.
    DataDir = ?config(data_dir, Config),
    ok = loom_config:load(filename:join(DataDir, "loom.json")),
    Config.

end_per_testcase(_TC, _Config) -> ok.

request_id_attached(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, _Status, Headers} = gun:await(ConnPid, StreamRef),
    RequestId = proplists:get_value(<<"x-request-id">>, Headers),
    ?assert(RequestId =/= undefined),
    ?assertMatch(<<"req-", _/binary>>, RequestId),
    gun:close(ConnPid).

content_type_rejected(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"text/plain">>}], <<"hello">>),
    {response, nofin, Status, _Headers} = gun:await(ConnPid, StreamRef),
    ?assertEqual(415, Status),
    gun:close(ConnPid).

get_request_passes(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, Status, _Headers} = gun:await(ConnPid, StreamRef),
    %% Should not be 415 — GET has no content-type requirement
    ?assert(Status =/= 415),
    gun:close(ConnPid).
