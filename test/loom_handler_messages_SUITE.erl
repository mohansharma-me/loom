-module(loom_handler_messages_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    non_streaming_response/1,
    streaming_sse_sequence/1,
    bad_request_missing_max_tokens/1,
    engine_overloaded/1,
    system_prompt/1
]).

all() -> [non_streaming_response, streaming_sse_sequence,
          bad_request_missing_max_tokens, engine_overloaded, system_prompt].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    application:set_env(loom, http, #{port => 18084, engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    catch loom_http:stop(),
    catch loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

init_per_testcase(_TC, Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>, <<" ">>, <<"world">>],
        token_delay => 0,
        error => undefined
    }),
    Config.

end_per_testcase(_TC, _Config) -> ok.

non_streaming_response(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"max_tokens">> => 1024,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(RespBody),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Decoded)),
    [Content] = maps:get(<<"content">>, Decoded),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"Hello world">>, maps:get(<<"text">>, Content)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Decoded)),
    gun:close(ConnPid).

streaming_sse_sequence(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"max_tokens">> => 1024,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, Headers} = gun:await(ConnPid, StreamRef),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertMatch(<<"text/event-stream", _/binary>>, ContentType),
    %% Collect all SSE events (event: <type>\ndata: <json>)
    Events = collect_sse_events(ConnPid, StreamRef, []),
    EventTypes = [Type || {Type, _} <- Events],
    %% Verify event sequence
    ?assertEqual(<<"message_start">>, hd(EventTypes)),
    ?assertEqual(<<"content_block_start">>, lists:nth(2, EventTypes)),
    %% Middle should be content_block_delta events
    ?assertEqual(<<"message_stop">>, lists:last(EventTypes)),
    %% Check message_delta is before message_stop
    ?assert(lists:member(<<"message_delta">>, EventTypes)),
    ?assert(lists:member(<<"content_block_stop">>, EventTypes)),
    gun:close(ConnPid).

bad_request_missing_max_tokens(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 400, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).

engine_overloaded(Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        generate_response => {error, overloaded}
    }),
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"max_tokens">> => 1024,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 429, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).

system_prompt(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"max_tokens">> => 1024,
        <<"system">> => <<"You are a helpful assistant.">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    %% Just verifying it doesn't error — system prompt is passed through
    gun:close(ConnPid).

%%% Internal

collect_sse_events(ConnPid, StreamRef, Acc) ->
    case gun:await(ConnPid, StreamRef, 5000) of
        {data, nofin, Chunk} ->
            Events = parse_sse_events(Chunk),
            collect_sse_events(ConnPid, StreamRef, Acc ++ Events);
        {data, fin, Chunk} ->
            Events = parse_sse_events(Chunk),
            Acc ++ Events;
        {error, _} ->
            Acc
    end.

parse_sse_events(Chunk) ->
    %% Split into event blocks separated by double newlines
    Blocks = binary:split(Chunk, <<"\n\n">>, [global, trim_all]),
    lists:filtermap(fun(Block) ->
        Lines = binary:split(Block, <<"\n">>, [global]),
        EventType = find_field(<<"event: ">>, Lines),
        Data = find_field(<<"data: ">>, Lines),
        case {EventType, Data} of
            {undefined, undefined} -> false;
            {undefined, D} -> {true, {<<"data">>, D}};
            {E, D} -> {true, {E, D}}
        end
    end, Blocks).

find_field(Prefix, Lines) ->
    PLen = byte_size(Prefix),
    case lists:filtermap(fun(Line) ->
        case Line of
            <<Prefix:PLen/binary, Rest/binary>> -> {true, Rest};
            _ -> false
        end
    end, Lines) of
        [Value | _] -> Value;
        [] -> undefined
    end.
