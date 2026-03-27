-module(loom_http_middleware_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    request_id_attached/1,
    content_type_rejected/1,
    get_request_passes/1
]).

all() -> [request_id_attached, content_type_rejected, get_request_passes].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    application:set_env(loom, http, #{port => 18080, engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    catch loom_http:stop(),
    catch loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

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
