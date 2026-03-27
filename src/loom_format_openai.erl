-module(loom_format_openai).

-export([
    parse_request/1,
    format_chunk/4,
    format_final_chunk/3,
    format_done/0,
    format_response/5,
    format_error/3,
    format_stream_error/2
]).

-spec parse_request(map()) -> {ok, map()} | {error, binary()}.
parse_request(Body) ->
    case {maps:get(<<"model">>, Body, undefined),
          maps:get(<<"messages">>, Body, undefined)} of
        {undefined, _} ->
            {error, <<"missing required field: model">>};
        {_, undefined} ->
            {error, <<"missing required field: messages">>};
        {Model, Messages} when is_list(Messages) ->
            Prompt = messages_to_prompt(Messages),
            Stream = maps:get(<<"stream">>, Body, false),
            Params = extract_params(Body),
            {ok, #{model => Model, prompt => Prompt, stream => Stream, params => Params}};
        {_, _} ->
            {error, <<"messages must be an array">>}
    end.

-spec format_chunk(binary(), binary(), binary(), non_neg_integer()) -> binary().
format_chunk(RequestId, Text, Model, Created) ->
    loom_json:encode(#{
        <<"id">> => <<"chatcmpl-", RequestId/binary>>,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{<<"content">> => Text},
            <<"finish_reason">> => null
        }]
    }).

-spec format_final_chunk(binary(), binary(), non_neg_integer()) -> binary().
format_final_chunk(RequestId, Model, Created) ->
    loom_json:encode(#{
        <<"id">> => <<"chatcmpl-", RequestId/binary>>,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{},
            <<"finish_reason">> => <<"stop">>
        }]
    }).

-spec format_done() -> binary().
format_done() ->
    <<"[DONE]">>.

-spec format_response(binary(), binary(), binary(), map(), non_neg_integer()) -> map().
format_response(RequestId, Content, Model, Stats, Created) ->
    CompletionTokens = maps:get(tokens, Stats, 0),
    #{
        <<"id">> => <<"chatcmpl-", RequestId/binary>>,
        <<"object">> => <<"chat.completion">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => Content
            },
            <<"finish_reason">> => <<"stop">>
        }],
        %% ASSUMPTION: prompt_tokens is 0 in Phase 0 (no tokenizer)
        <<"usage">> => #{
            <<"prompt_tokens">> => 0,
            <<"completion_tokens">> => CompletionTokens,
            <<"total_tokens">> => CompletionTokens
        }
    }.

-spec format_error(binary(), binary(), binary()) -> map().
format_error(Type, Code, Message) ->
    #{<<"error">> => #{
        <<"message">> => Message,
        <<"type">> => Type,
        <<"code">> => Code
    }}.

-spec format_stream_error(binary(), binary()) -> binary().
format_stream_error(Type, Message) ->
    loom_json:encode(#{<<"error">> => #{
        <<"message">> => Message,
        <<"type">> => Type
    }}).

%%% Internal

-spec messages_to_prompt([map()]) -> binary().
messages_to_prompt(Messages) ->
    Parts = lists:map(fun(Msg) ->
        Role = maps:get(<<"role">>, Msg, <<"user">>),
        Content = maps:get(<<"content">>, Msg, <<>>),
        <<Role/binary, ": ", Content/binary>>
    end, Messages),
    iolist_to_binary(lists:join(<<"\n">>, Parts)).

-spec extract_params(map()) -> map().
extract_params(Body) ->
    Params0 = #{},
    Params1 = maybe_add(<<"max_tokens">>, max_tokens, Body, Params0),
    Params2 = maybe_add(<<"temperature">>, temperature, Body, Params1),
    Params3 = maybe_add(<<"top_p">>, top_p, Body, Params2),
    maybe_add(<<"stop">>, stop, Body, Params3).

-spec maybe_add(binary(), atom(), map(), map()) -> map().
maybe_add(JsonKey, ErlKey, Body, Params) ->
    case maps:get(JsonKey, Body, undefined) of
        undefined -> Params;
        Value -> maps:put(ErlKey, Value, Params)
    end.
