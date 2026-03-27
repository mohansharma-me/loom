-module(loom_format_anthropic_tests).
-include_lib("eunit/include/eunit.hrl").

parse_request_basic_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"max_tokens">> => 1024,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}]
    },
    {ok, Parsed} = loom_format_anthropic:parse_request(Body),
    ?assertEqual(<<"llama-3">>, maps:get(model, Parsed)),
    ?assert(binary:match(maps:get(prompt, Parsed), <<"hello">>) =/= nomatch),
    ?assertEqual(false, maps:get(stream, Parsed)),
    ?assertEqual(1024, maps:get(max_tokens, maps:get(params, Parsed))).

parse_request_with_system_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"max_tokens">> => 1024,
        <<"system">> => <<"You are helpful.">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}]
    },
    {ok, Parsed} = loom_format_anthropic:parse_request(Body),
    Prompt = maps:get(prompt, Parsed),
    ?assert(binary:match(Prompt, <<"You are helpful.">>) =/= nomatch).

parse_request_missing_model_test() ->
    Body = #{<<"max_tokens">> => 1024,
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    ?assertMatch({error, _}, loom_format_anthropic:parse_request(Body)).

parse_request_missing_max_tokens_test() ->
    Body = #{<<"model">> => <<"llama-3">>,
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    ?assertMatch({error, _}, loom_format_anthropic:parse_request(Body)).

format_message_start_test() ->
    Bin = loom_format_anthropic:format_message_start(<<"msg-abc">>, <<"llama-3">>),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"message_start">>, maps:get(<<"type">>, Decoded)),
    Msg = maps:get(<<"message">>, Decoded),
    ?assertEqual(<<"msg-abc">>, maps:get(<<"id">>, Msg)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"llama-3">>, maps:get(<<"model">>, Msg)).

format_content_block_start_test() ->
    Bin = loom_format_anthropic:format_content_block_start(0),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"content_block_start">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(0, maps:get(<<"index">>, Decoded)),
    Block = maps:get(<<"content_block">>, Decoded),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)).

format_content_block_delta_test() ->
    Bin = loom_format_anthropic:format_content_block_delta(0, <<"Hello">>),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"content_block_delta">>, maps:get(<<"type">>, Decoded)),
    Delta = maps:get(<<"delta">>, Decoded),
    ?assertEqual(<<"text_delta">>, maps:get(<<"type">>, Delta)),
    ?assertEqual(<<"Hello">>, maps:get(<<"text">>, Delta)).

format_content_block_stop_test() ->
    Bin = loom_format_anthropic:format_content_block_stop(0),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"content_block_stop">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(0, maps:get(<<"index">>, Decoded)).

format_message_delta_test() ->
    Bin = loom_format_anthropic:format_message_delta(5),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"message_delta">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, maps:get(<<"delta">>, Decoded))),
    ?assertEqual(5, maps:get(<<"output_tokens">>, maps:get(<<"usage">>, Decoded))).

format_message_stop_test() ->
    Bin = loom_format_anthropic:format_message_stop(),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"message_stop">>, maps:get(<<"type">>, Decoded)).

format_response_test() ->
    Resp = loom_format_anthropic:format_response(
        <<"msg-abc">>, <<"Hello world">>, <<"llama-3">>, #{tokens => 2}),
    ?assertEqual(<<"msg-abc">>, maps:get(<<"id">>, Resp)),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Resp)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Resp)),
    [Content] = maps:get(<<"content">>, Resp),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"Hello world">>, maps:get(<<"text">>, Content)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Resp)),
    Usage = maps:get(<<"usage">>, Resp),
    ?assertEqual(0, maps:get(<<"input_tokens">>, Usage)),
    ?assertEqual(2, maps:get(<<"output_tokens">>, Usage)).

format_error_test() ->
    Err = loom_format_anthropic:format_error(<<"overloaded_error">>, <<"At capacity">>),
    ?assertEqual(<<"error">>, maps:get(<<"type">>, Err)),
    ErrBody = maps:get(<<"error">>, Err),
    ?assertEqual(<<"overloaded_error">>, maps:get(<<"type">>, ErrBody)),
    ?assertEqual(<<"At capacity">>, maps:get(<<"message">>, ErrBody)).
