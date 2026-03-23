-module(loom_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Buffer tests ---

-spec buffer_new_test() -> any().
buffer_new_test() ->
    ?assertEqual(<<>>, loom_protocol:new_buffer()).

-spec buffer_single_complete_line_test() -> any().
buffer_single_complete_line_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"hello\n">>, Buf0),
    ?assertEqual([<<"hello">>], Lines),
    ?assertEqual(<<>>, Buf1).

-spec buffer_multiple_lines_test() -> any().
buffer_multiple_lines_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"aaa\nbbb\nccc\n">>, Buf0),
    ?assertEqual([<<"aaa">>, <<"bbb">>, <<"ccc">>], Lines),
    ?assertEqual(<<>>, Buf1).

-spec buffer_partial_read_test() -> any().
buffer_partial_read_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines1, Buf1} = loom_protocol:feed(<<"hel">>, Buf0),
    ?assertEqual([], Lines1),
    {Lines2, Buf2} = loom_protocol:feed(<<"lo\n">>, Buf1),
    ?assertEqual([<<"hello">>], Lines2),
    ?assertEqual(<<>>, Buf2).

-spec buffer_partial_then_multiple_test() -> any().
buffer_partial_then_multiple_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {[], Buf1} = loom_protocol:feed(<<"aa">>, Buf0),
    {Lines, Buf2} = loom_protocol:feed(<<"a\nbbb\ncc">>, Buf1),
    ?assertEqual([<<"aaa">>, <<"bbb">>], Lines),
    ?assertEqual(<<"cc">>, Buf2).

-spec buffer_empty_feed_test() -> any().
buffer_empty_feed_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<>>, Buf0),
    ?assertEqual([], Lines),
    ?assertEqual(<<>>, Buf1).

-spec buffer_newline_only_test() -> any().
buffer_newline_only_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"\n">>, Buf0),
    ?assertEqual([<<>>], Lines),
    ?assertEqual(<<>>, Buf1).

-spec buffer_no_trailing_newline_test() -> any().
buffer_no_trailing_newline_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"no newline">>, Buf0),
    ?assertEqual([], Lines),
    ?assertEqual(<<"no newline">>, Buf1).

%% --- Encode tests ---

-spec encode_health_test() -> any().
encode_health_test() ->
    Bin = loom_protocol:encode({health}),
    ?assert(is_binary(Bin)),
    ?assertEqual($\n, binary:last(Bin)),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(#{<<"type">> => <<"health">>}, Map).

-spec encode_memory_test() -> any().
encode_memory_test() ->
    Bin = loom_protocol:encode({memory}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(#{<<"type">> => <<"memory">>}, Map).

-spec encode_shutdown_test() -> any().
encode_shutdown_test() ->
    Bin = loom_protocol:encode({shutdown}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(#{<<"type">> => <<"shutdown">>}, Map).

-spec encode_cancel_test() -> any().
encode_cancel_test() ->
    Bin = loom_protocol:encode({cancel, <<"req-42">>}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(<<"cancel">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"req-42">>, maps:get(<<"id">>, Map)).

-spec encode_generate_empty_params_test() -> any().
encode_generate_empty_params_test() ->
    Bin = loom_protocol:encode({generate, <<"req-1">>, <<"Hello">>, #{}}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(<<"generate">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"req-1">>, maps:get(<<"id">>, Map)),
    ?assertEqual(<<"Hello">>, maps:get(<<"prompt">>, Map)),
    ?assertEqual(#{}, maps:get(<<"params">>, Map)).

-spec encode_generate_full_params_test() -> any().
encode_generate_full_params_test() ->
    Params = #{max_tokens => 100, temperature => 0.7, top_p => 0.9, stop => [<<"END">>]},
    Bin = loom_protocol:encode({generate, <<"req-2">>, <<"Hi">>, Params}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ParamsMap = maps:get(<<"params">>, Map),
    ?assertEqual(100, maps:get(<<"max_tokens">>, ParamsMap)),
    ?assertEqual(0.7, maps:get(<<"temperature">>, ParamsMap)),
    ?assertEqual(0.9, maps:get(<<"top_p">>, ParamsMap)),
    ?assertEqual([<<"END">>], maps:get(<<"stop">>, ParamsMap)).

-spec encode_generate_partial_params_test() -> any().
encode_generate_partial_params_test() ->
    Params = #{max_tokens => 50},
    Bin = loom_protocol:encode({generate, <<"req-3">>, <<"Test">>, Params}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ParamsMap = maps:get(<<"params">>, Map),
    ?assertEqual(50, maps:get(<<"max_tokens">>, ParamsMap)),
    ?assertEqual(1, maps:size(ParamsMap)).

-spec encode_bad_input_crashes_test() -> any().
encode_bad_input_crashes_test() ->
    ?assertError(function_clause, loom_protocol:encode({bogus})),
    ?assertError(function_clause, loom_protocol:encode(not_a_tuple)).

%% --- Decode error tests ---

-spec decode_invalid_json_test() -> any().
decode_invalid_json_test() ->
    ?assertMatch({error, {invalid_json, _}}, loom_protocol:decode(<<"not json">>)).

-spec decode_empty_input_test() -> any().
decode_empty_input_test() ->
    ?assertMatch({error, {invalid_json, _}}, loom_protocol:decode(<<>>)).

-spec decode_missing_type_test() -> any().
decode_missing_type_test() ->
    Json = loom_json:encode(#{foo => bar}),
    ?assertEqual({error, missing_type}, loom_protocol:decode(Json)).

-spec decode_unknown_type_test() -> any().
decode_unknown_type_test() ->
    Json = loom_json:encode(#{type => <<"bogus">>}),
    ?assertEqual({error, {unknown_type, <<"bogus">>}}, loom_protocol:decode(Json)).

-spec decode_not_object_test() -> any().
decode_not_object_test() ->
    ?assertEqual({error, missing_type}, loom_protocol:decode(<<"42">>)).

-spec decode_array_not_object_test() -> any().
decode_array_not_object_test() ->
    ?assertEqual({error, missing_type}, loom_protocol:decode(<<"[1,2,3]">>)).

%% --- Decode token tests ---

-spec decode_token_test() -> any().
decode_token_test() ->
    Json = loom_json:encode(#{
        type => <<"token">>, id => <<"r1">>,
        token_id => 42, text => <<"hello">>, finished => false
    }),
    ?assertEqual(
        {ok, {token, <<"r1">>, 42, <<"hello">>, false}},
        loom_protocol:decode(Json)
    ).

-spec decode_token_finished_test() -> any().
decode_token_finished_test() ->
    Json = loom_json:encode(#{
        type => <<"token">>, id => <<"r1">>,
        token_id => 99, text => <<"end">>, finished => true
    }),
    ?assertEqual(
        {ok, {token, <<"r1">>, 99, <<"end">>, true}},
        loom_protocol:decode(Json)
    ).

-spec decode_token_missing_id_test() -> any().
decode_token_missing_id_test() ->
    Json = loom_json:encode(#{
        type => <<"token">>, token_id => 1, text => <<"x">>, finished => false
    }),
    ?assertEqual(
        {error, {missing_field, <<"id">>, <<"token">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_token_bad_token_id_test() -> any().
decode_token_bad_token_id_test() ->
    Json = loom_json:encode(#{
        type => <<"token">>, id => <<"r1">>,
        token_id => <<"not_int">>, text => <<"x">>, finished => false
    }),
    ?assertMatch(
        {error, {invalid_field, <<"token_id">>, integer, _}},
        loom_protocol:decode(Json)
    ).

-spec decode_token_negative_token_id_test() -> any().
decode_token_negative_token_id_test() ->
    Json = loom_json:encode(#{
        type => <<"token">>, id => <<"r1">>,
        token_id => -1, text => <<"x">>, finished => false
    }),
    ?assertEqual(
        {error, {invalid_field, <<"token_id">>, integer, -1}},
        loom_protocol:decode(Json)
    ).

%% --- Decode done tests ---

-spec decode_done_test() -> any().
decode_done_test() ->
    Json = loom_json:encode(#{
        type => <<"done">>, id => <<"r1">>,
        tokens_generated => 47, time_ms => 1820
    }),
    ?assertEqual(
        {ok, {done, <<"r1">>, 47, 1820}},
        loom_protocol:decode(Json)
    ).

-spec decode_done_missing_field_test() -> any().
decode_done_missing_field_test() ->
    Json = loom_json:encode(#{
        type => <<"done">>, id => <<"r1">>, tokens_generated => 10
    }),
    ?assertEqual(
        {error, {missing_field, <<"time_ms">>, <<"done">>}},
        loom_protocol:decode(Json)
    ).

%% --- Decode error tests ---

-spec decode_error_with_id_test() -> any().
decode_error_with_id_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>, id => <<"r1">>,
        code => <<"engine_crashed">>, message => <<"vLLM died">>
    }),
    ?assertEqual(
        {ok, {error, <<"r1">>, <<"engine_crashed">>, <<"vLLM died">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_error_no_id_test() -> any().
decode_error_no_id_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>,
        code => <<"parse_error">>, message => <<"bad input">>
    }),
    ?assertEqual(
        {ok, {error, undefined, <<"parse_error">>, <<"bad input">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_error_null_id_test() -> any().
decode_error_null_id_test() ->
    %% JSON null maps to Erlang null atom via loom_json
    Json = <<"{\"type\":\"error\",\"id\":null,\"code\":\"x\",\"message\":\"y\"}">>,
    ?assertEqual(
        {ok, {error, undefined, <<"x">>, <<"y">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_error_missing_code_test() -> any().
decode_error_missing_code_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>, message => <<"oops">>
    }),
    ?assertEqual(
        {error, {missing_field, <<"code">>, <<"error">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_error_missing_message_test() -> any().
decode_error_missing_message_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>, code => <<"x">>
    }),
    ?assertEqual(
        {error, {missing_field, <<"message">>, <<"error">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_error_invalid_id_type_test() -> any().
decode_error_invalid_id_type_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>, id => 42,
        code => <<"x">>, message => <<"y">>
    }),
    ?assertMatch(
        {error, {invalid_field, <<"id">>, binary, _}},
        loom_protocol:decode(Json)
    ).

%% --- Decode health_response tests ---

-spec decode_health_response_test() -> any().
decode_health_response_test() ->
    Json = loom_json:encode(#{
        type => <<"health">>, status => <<"ok">>,
        gpu_util => 0.73, mem_used_gb => 62.4, mem_total_gb => 80.0
    }),
    ?assertEqual(
        {ok, {health_response, <<"ok">>, 0.73, 62.4, 80.0}},
        loom_protocol:decode(Json)
    ).

-spec decode_health_response_missing_field_test() -> any().
decode_health_response_missing_field_test() ->
    Json = loom_json:encode(#{
        type => <<"health">>, status => <<"ok">>,
        gpu_util => 0.5, mem_used_gb => 10.0
    }),
    ?assertEqual(
        {error, {missing_field, <<"mem_total_gb">>, <<"health">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_health_response_integer_coercion_test() -> any().
decode_health_response_integer_coercion_test() ->
    %% JSON integers (e.g., 0 instead of 0.0) should be coerced to floats
    Json = loom_json:encode(#{
        type => <<"health">>, status => <<"ok">>,
        gpu_util => 0, mem_used_gb => 0, mem_total_gb => 80
    }),
    ?assertEqual(
        {ok, {health_response, <<"ok">>, 0.0, 0.0, 80.0}},
        loom_protocol:decode(Json)
    ).

-spec decode_health_response_bad_type_test() -> any().
decode_health_response_bad_type_test() ->
    Json = loom_json:encode(#{
        type => <<"health">>, status => <<"ok">>,
        gpu_util => <<"not_number">>, mem_used_gb => 0.0, mem_total_gb => 80.0
    }),
    ?assertMatch(
        {error, {invalid_field, <<"gpu_util">>, number, _}},
        loom_protocol:decode(Json)
    ).

%% --- Decode memory_response tests ---

-spec decode_memory_response_test() -> any().
decode_memory_response_test() ->
    Json = loom_json:encode(#{
        type => <<"memory">>,
        total_gb => 80.0, used_gb => 62.4, available_gb => 17.6
    }),
    {ok, {memory_response, Info}} = loom_protocol:decode(Json),
    ?assertEqual(80.0, maps:get(<<"total_gb">>, Info)),
    ?assertEqual(62.4, maps:get(<<"used_gb">>, Info)),
    ?assertEqual(17.6, maps:get(<<"available_gb">>, Info)),
    %% Verify "type" key is stripped from the returned map
    ?assertEqual(false, maps:is_key(<<"type">>, Info)).

-spec decode_memory_response_integer_coercion_test() -> any().
decode_memory_response_integer_coercion_test() ->
    %% JSON integers should be coerced to floats (consistent with health_response)
    Json = loom_json:encode(#{
        type => <<"memory">>,
        total_gb => 80, used_gb => 0, available_gb => 80
    }),
    {ok, {memory_response, Info}} = loom_protocol:decode(Json),
    ?assertEqual(80.0, maps:get(<<"total_gb">>, Info)),
    ?assertEqual(0.0, maps:get(<<"used_gb">>, Info)),
    ?assertEqual(80.0, maps:get(<<"available_gb">>, Info)).

-spec decode_memory_response_extra_keys_test() -> any().
decode_memory_response_extra_keys_test() ->
    Json = loom_json:encode(#{
        type => <<"memory">>,
        total_gb => 80.0, used_gb => 40.0, available_gb => 40.0,
        kv_cache_gb => 25.0
    }),
    {ok, {memory_response, Info}} = loom_protocol:decode(Json),
    ?assertEqual(25.0, maps:get(<<"kv_cache_gb">>, Info)).

-spec decode_memory_response_missing_field_test() -> any().
decode_memory_response_missing_field_test() ->
    Json = loom_json:encode(#{
        type => <<"memory">>,
        total_gb => 80.0, used_gb => 40.0
    }),
    ?assertEqual(
        {error, {missing_field, <<"available_gb">>, <<"memory">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_memory_bad_type_test() -> any().
decode_memory_bad_type_test() ->
    Json = loom_json:encode(#{
        type => <<"memory">>,
        total_gb => <<"not_number">>, used_gb => 0.0, available_gb => 0.0
    }),
    ?assertMatch(
        {error, {invalid_field, <<"total_gb">>, number, _}},
        loom_protocol:decode(Json)
    ).

%% --- Decode ready tests ---

-spec decode_ready_test() -> any().
decode_ready_test() ->
    Json = loom_json:encode(#{
        type => <<"ready">>,
        model => <<"meta-llama/Llama-3-8B">>,
        backend => <<"vllm">>
    }),
    ?assertEqual(
        {ok, {ready, <<"meta-llama/Llama-3-8B">>, <<"vllm">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_ready_missing_model_test() -> any().
decode_ready_missing_model_test() ->
    Json = loom_json:encode(#{type => <<"ready">>, backend => <<"vllm">>}),
    ?assertEqual(
        {error, {missing_field, <<"model">>, <<"ready">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_ready_missing_backend_test() -> any().
decode_ready_missing_backend_test() ->
    Json = loom_json:encode(#{type => <<"ready">>, model => <<"m">>}),
    ?assertEqual(
        {error, {missing_field, <<"backend">>, <<"ready">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_ready_bad_type_test() -> any().
decode_ready_bad_type_test() ->
    Json = loom_json:encode(#{type => <<"ready">>, model => 42, backend => <<"vllm">>}),
    ?assertMatch(
        {error, {invalid_field, <<"model">>, binary, _}},
        loom_protocol:decode(Json)
    ).

-spec decode_done_bad_type_test() -> any().
decode_done_bad_type_test() ->
    Json = loom_json:encode(#{
        type => <<"done">>, id => <<"r1">>,
        tokens_generated => <<"not_int">>, time_ms => 100
    }),
    ?assertMatch(
        {error, {invalid_field, <<"tokens_generated">>, integer, _}},
        loom_protocol:decode(Json)
    ).
