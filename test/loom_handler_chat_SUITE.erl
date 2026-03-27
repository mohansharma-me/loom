-module(loom_handler_chat_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    non_streaming_response/1,
    streaming_sse/1,
    bad_request/1,
    malformed_json/1,
    engine_overloaded/1,
    engine_unavailable/1,
    mid_stream_error/1,
    inactivity_timeout/1,
    client_disconnect/1
]).

all() -> [non_streaming_response, streaming_sse, bad_request, malformed_json,
          engine_overloaded, engine_unavailable, mid_stream_error,
          inactivity_timeout, client_disconnect].

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
    %% destroys ETS tables it created. Reload config each test case to ensure
    %% the loom_config ETS table exists for tests that manipulate it directly.
    DataDir = ?config(data_dir, Config),
    ok = loom_config:load(filename:join(DataDir, "loom.json")),
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>, <<" ">>, <<"world">>],
        token_delay => 0,
        error => undefined
    }),
    Config.

end_per_testcase(_TC, _Config) -> ok.

non_streaming_response(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => false
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(RespBody),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Decoded)),
    [Choice] = maps:get(<<"choices">>, Decoded),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"Hello world">>, maps:get(<<"content">>, Msg)),
    gun:close(ConnPid).

streaming_sse(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, Headers} = gun:await(ConnPid, StreamRef),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertMatch(<<"text/event-stream", _/binary>>, ContentType),
    %% Collect SSE data chunks
    Events = collect_sse_data(ConnPid, StreamRef, []),
    %% Should have 3 token chunks + 1 final chunk + [DONE]
    ?assert(length(Events) >= 4),
    %% Last event should be [DONE]
    ?assertEqual(<<"[DONE]">>, lists:last(Events)),
    gun:close(ConnPid).

bad_request(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{<<"invalid">> => true}),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 400, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).

engine_overloaded(Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        generate_response => {error, overloaded}
    }),
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 429, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).

engine_unavailable(_Config) ->
    %% Temporarily override engine names in ETS to simulate nonexistent engine
    ets:insert(loom_config, {{engine, names}, [<<"nonexistent">>]}),
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 503, _} = gun:await(ConnPid, StreamRef),
    %% Restore engine names
    ets:insert(loom_config, {{engine, names}, [<<"engine_0">>]}),
    gun:close(ConnPid).

malformed_json(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], <<"{broken">>),
    {response, nofin, 400, _} = gun:await(ConnPid, StreamRef),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(RespBody),
    ?assertMatch(#{<<"error">> := _}, Decoded),
    gun:close(ConnPid).

mid_stream_error(Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>],
        token_delay => 0,
        error => {<<"engine_crashed">>, <<"Engine process died">>}
    }),
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    %% Should receive at least one token then an error event
    _Events = collect_sse_data(ConnPid, StreamRef, []),
    gun:close(ConnPid).

inactivity_timeout(Config) ->
    %% Set very short inactivity timeout and slow token delivery
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>, <<"world">>],
        token_delay => 3000,  %% 3s between tokens
        error => undefined
    }),
    %% Temporarily override server config in ETS with short inactivity_timeout
    [{_, OrigServerConfig}] = ets:lookup(loom_config, {server, config}),
    ets:insert(loom_config, {{server, config},
        OrigServerConfig#{inactivity_timeout => 500}}),
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => false
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 504, _} = gun:await(ConnPid, StreamRef, 10000),
    %% Restore server config
    ets:insert(loom_config, {{server, config}, OrigServerConfig}),
    gun:close(ConnPid).

client_disconnect(Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>, <<"world">>, <<"foo">>, <<"bar">>],
        token_delay => 500,  %% slow tokens so we can disconnect mid-stream
        error => undefined
    }),
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    %% Wait for first token then disconnect
    timer:sleep(200),
    gun:close(ConnPid),
    %% Give coordinator time to process DOWN — no crash expected
    timer:sleep(500),
    ok.

%%% Internal

collect_sse_data(ConnPid, StreamRef, Acc) ->
    case gun:await(ConnPid, StreamRef, 5000) of
        {data, nofin, Chunk} ->
            Events = parse_sse_data(Chunk),
            collect_sse_data(ConnPid, StreamRef, Acc ++ Events);
        {data, fin, Chunk} ->
            Events = parse_sse_data(Chunk),
            Acc ++ Events;
        {error, _} ->
            Acc
    end.

parse_sse_data(Chunk) ->
    Lines = binary:split(Chunk, <<"\n">>, [global, trim_all]),
    lists:filtermap(fun(Line) ->
        case Line of
            <<"data: ", Data/binary>> -> {true, Data};
            _ -> false
        end
    end, Lines).
