-module(loom_format_openai_tests).
-include_lib("eunit/include/eunit.hrl").

parse_request_basic_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
        <<"stream">> => true
    },
    {ok, Parsed} = loom_format_openai:parse_request(Body),
    ?assertEqual(<<"llama-3">>, maps:get(model, Parsed)),
    ?assertEqual(true, maps:get(stream, Parsed)).

parse_request_with_params_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"max_tokens">> => 100,
        <<"temperature">> => 0.7
    },
    {ok, Parsed} = loom_format_openai:parse_request(Body),
    ?assertEqual(100, maps:get(max_tokens, maps:get(params, Parsed))).

parse_request_missing_model_test() ->
    Body = #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    ?assertMatch({error, _}, loom_format_openai:parse_request(Body)).

parse_request_missing_messages_test() ->
    Body = #{<<"model">> => <<"llama-3">>},
    ?assertMatch({error, _}, loom_format_openai:parse_request(Body)).

parse_request_multi_message_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"You are helpful.">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}
        ]
    },
    {ok, Parsed} = loom_format_openai:parse_request(Body),
    Prompt = maps:get(prompt, Parsed),
    ?assert(binary:match(Prompt, <<"You are helpful.">>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"hello">>) =/= nomatch).

parse_request_stream_default_false_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    },
    {ok, Parsed} = loom_format_openai:parse_request(Body),
    ?assertEqual(false, maps:get(stream, Parsed)).

format_chunk_test() ->
    Chunk = loom_format_openai:format_chunk(<<"req-abc">>, <<"Hello">>, <<"llama-3">>, 1700000000),
    Decoded = loom_json:decode(Chunk),
    ?assertEqual(<<"chatcmpl-req-abc">>, maps:get(<<"id">>, Decoded)),
    ?assertEqual(<<"chat.completion.chunk">>, maps:get(<<"object">>, Decoded)),
    ?assertEqual(<<"llama-3">>, maps:get(<<"model">>, Decoded)),
    ?assertEqual(1700000000, maps:get(<<"created">>, Decoded)),
    [Choice] = maps:get(<<"choices">>, Decoded),
    ?assertEqual(0, maps:get(<<"index">>, Choice)),
    Delta = maps:get(<<"delta">>, Choice),
    ?assertEqual(<<"Hello">>, maps:get(<<"content">>, Delta)),
    ?assertEqual(null, maps:get(<<"finish_reason">>, Choice)).

format_final_chunk_test() ->
    Chunk = loom_format_openai:format_final_chunk(<<"req-abc">>, <<"llama-3">>, 1700000000),
    Decoded = loom_json:decode(Chunk),
    [Choice] = maps:get(<<"choices">>, Decoded),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice)),
    ?assertEqual(#{}, maps:get(<<"delta">>, Choice)).

format_done_test() ->
    ?assertEqual(<<"[DONE]">>, loom_format_openai:format_done()).

format_response_test() ->
    Resp = loom_format_openai:format_response(
        <<"req-abc">>, <<"Hello world">>, <<"llama-3">>, #{tokens => 2, time_ms => 100}, 1700000000),
    ?assertEqual(<<"chatcmpl-req-abc">>, maps:get(<<"id">>, Resp)),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Resp)),
    [Choice] = maps:get(<<"choices">>, Resp),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"Hello world">>, maps:get(<<"content">>, Msg)),
    Usage = maps:get(<<"usage">>, Resp),
    ?assertEqual(0, maps:get(<<"prompt_tokens">>, Usage)),
    ?assertEqual(2, maps:get(<<"completion_tokens">>, Usage)).

format_error_test() ->
    Err = loom_format_openai:format_error(<<"server_error">>, <<"engine_unavailable">>, <<"Engine is down">>),
    ?assertEqual(<<"Engine is down">>, maps:get(<<"message">>, maps:get(<<"error">>, Err))),
    ?assertEqual(<<"server_error">>, maps:get(<<"type">>, maps:get(<<"error">>, Err))),
    ?assertEqual(<<"engine_unavailable">>, maps:get(<<"code">>, maps:get(<<"error">>, Err))).

format_stream_error_test() ->
    Bin = loom_format_openai:format_stream_error(<<"server_error">>, <<"Engine crashed">>),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"Engine crashed">>, maps:get(<<"message">>, maps:get(<<"error">>, Decoded))).
