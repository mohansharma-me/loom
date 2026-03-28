%%%-------------------------------------------------------------------
%%% @doc HTTP client disconnect test suite.
%%%
%%% Validates that abrupt HTTP client disconnection during SSE streaming
%%% is handled gracefully: in-flight requests are cleaned up, the engine
%%% stays ready, and subsequent requests succeed.
%%%
%%% Starts the full loom application with an engine supervisor started
%%% directly (for control over adapter args). Uses raw gen_tcp for
%%% precise connection lifecycle control.
%%%
%%% ASSUMPTION: python3 is on PATH in the test environment.
%%% ASSUMPTION: The loom_config ETS table must be owned by a process that
%%% survives across CT callbacks (init_per_suite and test cases run in
%%% different processes). We use a keeper process for this.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_http_disconnect_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([client_disconnect_test/1]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [client_disconnect_test].

init_per_suite(Config) ->
    ok = application:load(loom),
    %% Load config so HTTP server starts. Use minimal.json as base.
    ok = loom_config:load(fixture_path("minimal.json")),

    %% ASSUMPTION: CT runs init_per_suite and test cases in different processes.
    %% The loom_config ETS table is owned by the calling process. When
    %% init_per_suite's process dies, the table would be deleted. Transfer
    %% ownership to a keeper process that persists across the suite.
    KeeperPid = spawn_ets_keeper(),
    ets:give_away(loom_config, KeeperPid, []),

    {ok, _} = application:ensure_all_started(loom),

    %% The app starts its own engine supervisor for fixture_engine.
    %% We need to replace it with one using --token-delay 0.5 for
    %% disconnect testing. Terminate the app-started engine child first.
    [FirstEngine | _] = loom_config:engine_names(),
    AppSupName = loom_engine_sup:sup_name(FirstEngine),
    _ = supervisor:terminate_child(loom_sup, AppSupName),
    _ = supervisor:delete_child(loom_sup, AppSupName),

    %% Start our own engine supervisor with slow tokens for disconnect testing.
    %% Use the same engine_id as the first configured engine so the HTTP
    %% handler can find it via loom_http_util:lookup_coordinator/1.
    EngineConfig = #{
        engine_id => FirstEngine,
        adapter_cmd => python_cmd(),
        adapter_args => [mock_adapter_path(), "--token-delay", "0.5"],
        model => <<"test-model">>,
        backend => <<"mock">>,
        gpus => [],
        max_concurrent => 64,
        startup_timeout_ms => 10000,
        drain_timeout_ms => 5000,
        allow_mock_backend => true
    },
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    %% Unlink from CT process so the supervisor survives process transitions
    %% between init_per_suite and test cases. We clean it up in end_per_suite.
    unlink(SupPid),
    ok = wait_status(FirstEngine, ready, 15000),

    %% Get actual HTTP port from ranch
    HttpPort = ranch:get_port(loom_http_listener),

    [{engine_id, FirstEngine}, {sup_pid, SupPid},
     {http_port, HttpPort}, {keeper_pid, KeeperPid} | Config].

end_per_suite(Config) ->
    %% Stop our engine supervisor first, before tearing down the app.
    %% Use kill to avoid hanging on drain timeout during cleanup.
    case ?config(sup_pid, Config) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true ->
                    exit(Pid, kill),
                    timer:sleep(100);
                false -> ok
            end;
        _ -> ok
    end,
    application:stop(loom),
    %% Kill the ETS keeper process
    case ?config(keeper_pid, Config) of
        KPid when is_pid(KPid) -> exit(KPid, kill);
        _ -> ok
    end,
    loom_test_helpers:cleanup_ets(),
    ok.

init_per_testcase(_TestCase, Config) ->
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_TestCase, _Config) ->
    flush_mailbox(),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc Scenario 6: Start an SSE stream via HTTP, disconnect the client
%% mid-stream. Verify the in-flight request is cleaned up, the engine
%% stays ready, and a new HTTP request succeeds.
client_disconnect_test(Config) ->
    EngineId = ?config(engine_id, Config),
    Port = ?config(http_port, Config),

    %% Verify engine is ready before test
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    %% Open raw TCP connection and send streaming request
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port,
        [binary, {active, false}, {packet, raw}]),

    Body = loom_json:encode(#{
        model => <<"test-model">>,
        messages => [#{role => <<"user">>, content => <<"Hello">>}],
        stream => true
    }),
    BodyLen = byte_size(Body),

    HttpReq = iolist_to_binary([
        <<"POST /v1/chat/completions HTTP/1.1\r\n">>,
        <<"Host: localhost:", (integer_to_binary(Port))/binary, "\r\n">>,
        <<"Content-Type: application/json\r\n">>,
        <<"Content-Length: ", (integer_to_binary(BodyLen))/binary, "\r\n">>,
        <<"\r\n">>,
        Body
    ]),

    ok = gen_tcp:send(Socket, HttpReq),

    %% Read response until we get at least one SSE data event
    %% (confirms streaming has started and a request is in-flight)
    {ok, ResponseData} = read_until_sse_data(Socket, <<>>, 10000),
    ct:pal("Received SSE data before disconnect: ~s",
           [truncate(ResponseData, 200)]),

    %% Verify the coordinator has an in-flight request
    %% ASSUMPTION: The request is still in-flight because --token-delay 0.5s
    %% means 5 tokens take ~2.5s total.
    ?assert(loom_engine_coordinator:get_load(EngineId) > 0),

    %% Abruptly close the TCP connection
    gen_tcp:close(Socket),
    ct:pal("TCP connection closed abruptly"),

    %% Wait for the coordinator to clean up the in-flight request.
    %% When Cowboy detects the closed connection, it terminates the handler
    %% process. The coordinator's DOWN monitor fires and cleans up.
    wait_load_zero(EngineId, 10000),

    %% Verify engine is still ready (not crashed)
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),

    %% Verify a new HTTP request succeeds
    {ok, Socket2} = gen_tcp:connect({127, 0, 0, 1}, Port,
        [binary, {active, false}, {packet, raw}]),

    Body2 = loom_json:encode(#{
        model => <<"test-model">>,
        messages => [#{role => <<"user">>, content => <<"World">>}],
        stream => false
    }),
    BodyLen2 = byte_size(Body2),

    HttpReq2 = iolist_to_binary([
        <<"POST /v1/chat/completions HTTP/1.1\r\n">>,
        <<"Host: localhost:", (integer_to_binary(Port))/binary, "\r\n">>,
        <<"Content-Type: application/json\r\n">>,
        <<"Content-Length: ", (integer_to_binary(BodyLen2))/binary, "\r\n">>,
        <<"\r\n">>,
        Body2
    ]),

    ok = gen_tcp:send(Socket2, HttpReq2),

    %% Read the full response (non-streaming)
    {ok, Response2} = read_full_response(Socket2, <<>>, 15000),
    ct:pal("Post-disconnect response: ~s", [truncate(Response2, 300)]),

    %% Verify we got a 200 OK response
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Response2),

    gen_tcp:close(Socket2),
    ct:pal("Client disconnect test passed").

%%====================================================================
%% Helpers
%%====================================================================

fixture_path(Name) ->
    TestDir = filename:dirname(?FILE),
    filename:join([TestDir, "fixtures", Name]).

mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

python_cmd() ->
    os:find_executable("python3").

%% @doc Spawn a process that simply waits forever, used to hold ETS
%% table ownership across CT callback boundaries.
spawn_ets_keeper() ->
    spawn(fun ets_keeper_loop/0).

ets_keeper_loop() ->
    receive
        stop -> ok
    end.

wait_status(EngineId, Status, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_status(EngineId) of
        Status -> ok;
        _ ->
            timer:sleep(50),
            wait_status(EngineId, Status, Timeout - 50)
    end;
wait_status(_EngineId, Status, _Timeout) ->
    ct:fail(io_lib:format("wait_status: never reached ~p", [Status])).

wait_load_zero(EngineId, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_load(EngineId) of
        0 -> ok;
        _ ->
            timer:sleep(50),
            wait_load_zero(EngineId, Timeout - 50)
    end;
wait_load_zero(_EngineId, _Timeout) ->
    ct:fail("wait_load_zero: load never reached 0").

flush_mailbox() ->
    receive _ -> flush_mailbox()
    after 0 -> ok
    end.

%% @doc Read from socket until we find "data: " (SSE event) or timeout.
read_until_sse_data(Socket, Acc, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            Combined = <<Acc/binary, Data/binary>>,
            case binary:match(Combined, <<"data: ">>) of
                nomatch ->
                    read_until_sse_data(Socket, Combined, Timeout);
                _ ->
                    {ok, Combined}
            end;
        {error, timeout} ->
            ct:fail("timeout waiting for SSE data");
        {error, Reason} ->
            ct:fail(io_lib:format("socket error: ~p", [Reason]))
    end.

%% @doc Read full HTTP response from socket.
read_full_response(Socket, Acc, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            Combined = <<Acc/binary, Data/binary>>,
            %% For non-streaming, check if we've received the full body.
            %% Simple heuristic: look for double CRLF (end of headers)
            %% then check Content-Length.
            case is_response_complete(Combined) of
                true -> {ok, Combined};
                false -> read_full_response(Socket, Combined, Timeout)
            end;
        {error, closed} ->
            %% Server closed connection after sending response
            {ok, Acc};
        {error, timeout} ->
            %% Return what we have
            {ok, Acc};
        {error, Reason} ->
            ct:fail(io_lib:format("socket error: ~p", [Reason]))
    end.

%% @doc Simple check if an HTTP response is complete.
%% Looks for the end of a JSON body (closing brace after headers).
is_response_complete(Data) ->
    case binary:match(Data, <<"\r\n\r\n">>) of
        nomatch -> false;
        {Pos, _Len} ->
            %% We have headers. Check if body looks complete.
            Body = binary:part(Data, Pos + 4, byte_size(Data) - Pos - 4),
            %% ASSUMPTION: Non-streaming responses are JSON objects.
            %% Check for closing brace followed by potential whitespace.
            byte_size(Body) > 0 andalso
            binary:last(string:trim(Body, trailing)) =:= $}
    end.

%% @doc Truncate binary for logging.
truncate(Bin, MaxLen) when byte_size(Bin) =< MaxLen -> Bin;
truncate(Bin, MaxLen) ->
    <<Prefix:MaxLen/binary, _/binary>> = Bin,
    <<Prefix/binary, "...">>.
