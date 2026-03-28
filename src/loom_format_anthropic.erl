-module(loom_format_anthropic).
-dialyzer(no_underspecs).

-export([
    parse_request/1,
    format_message_start/2,
    format_content_block_start/1,
    format_content_block_delta/2,
    format_content_block_stop/1,
    format_message_delta/1,
    format_message_stop/0,
    format_response/4,
    format_error/2,
    format_stream_error/2
]).

-spec parse_request(map()) -> {ok, map()} | {error, binary()}.
parse_request(Body) ->
    case {maps:get(<<"model">>, Body, undefined),
          maps:get(<<"max_tokens">>, Body, undefined),
          maps:get(<<"messages">>, Body, undefined)} of
        {undefined, _, _} ->
            {error, <<"missing required field: model">>};
        {_, undefined, _} ->
            {error, <<"missing required field: max_tokens">>};
        {_, _, undefined} ->
            {error, <<"missing required field: messages">>};
        {Model, MaxTokens, Messages} when is_list(Messages) ->
            System = maps:get(<<"system">>, Body, undefined),
            Prompt = messages_to_prompt(System, Messages),
            Stream = maps:get(<<"stream">>, Body, false),
            Params = extract_params(Body),
            {ok, #{model => Model, prompt => Prompt, stream => Stream,
                   params => Params#{max_tokens => MaxTokens}}};
        {_, _, _} ->
            {error, <<"messages must be an array">>}
    end.

-spec format_message_start(binary(), binary()) -> binary().
format_message_start(MessageId, Model) ->
    loom_json:encode(#{
        <<"type">> => <<"message_start">>,
        <<"message">> => #{
            <<"id">> => MessageId,
            <<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"content">> => [],
            <<"model">> => Model,
            <<"usage">> => #{<<"input_tokens">> => 0}
        }
    }).

-spec format_content_block_start(non_neg_integer()) -> binary().
format_content_block_start(Index) ->
    loom_json:encode(#{
        <<"type">> => <<"content_block_start">>,
        <<"index">> => Index,
        <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}
    }).

-spec format_content_block_delta(non_neg_integer(), binary()) -> binary().
format_content_block_delta(Index, Text) ->
    loom_json:encode(#{
        <<"type">> => <<"content_block_delta">>,
        <<"index">> => Index,
        <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => Text}
    }).

-spec format_content_block_stop(non_neg_integer()) -> binary().
format_content_block_stop(Index) ->
    loom_json:encode(#{
        <<"type">> => <<"content_block_stop">>,
        <<"index">> => Index
    }).

-spec format_message_delta(non_neg_integer()) -> binary().
format_message_delta(OutputTokens) ->
    loom_json:encode(#{
        <<"type">> => <<"message_delta">>,
        <<"delta">> => #{<<"stop_reason">> => <<"end_turn">>},
        <<"usage">> => #{<<"output_tokens">> => OutputTokens}
    }).

-spec format_message_stop() -> binary().
format_message_stop() ->
    loom_json:encode(#{<<"type">> => <<"message_stop">>}).

-spec format_response(binary(), binary(), binary(), map()) -> map().
format_response(MessageId, Content, Model, Stats) ->
    OutputTokens = maps:get(tokens, Stats, 0),
    #{
        <<"id">> => MessageId,
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => Model,
        <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => Content}],
        <<"stop_reason">> => <<"end_turn">>,
        %% ASSUMPTION: input_tokens is 0 in Phase 0 (no tokenizer)
        <<"usage">> => #{
            <<"input_tokens">> => 0,
            <<"output_tokens">> => OutputTokens
        }
    }.

-spec format_error(binary(), binary()) -> map().
format_error(Type, Message) ->
    #{<<"type">> => <<"error">>,
      <<"error">> => #{<<"type">> => Type, <<"message">> => Message}}.

-spec format_stream_error(binary(), binary()) -> binary().
format_stream_error(Type, Message) ->
    loom_json:encode(#{<<"type">> => <<"error">>,
                       <<"error">> => #{<<"type">> => Type, <<"message">> => Message}}).

%%% Internal

-spec messages_to_prompt(binary() | undefined, [map()]) -> binary().
messages_to_prompt(System, Messages) ->
    SystemParts = case System of
        undefined -> [];
        S -> [<<"system: ", S/binary>>]
    end,
    MsgParts = lists:map(fun(Msg) ->
        Role = maps:get(<<"role">>, Msg, <<"user">>),
        Content = maps:get(<<"content">>, Msg, <<>>),
        <<Role/binary, ": ", Content/binary>>
    end, Messages),
    iolist_to_binary(lists:join(<<"\n">>, SystemParts ++ MsgParts)).

-spec extract_params(map()) -> map().
extract_params(Body) ->
    Params0 = #{},
    Params1 = maybe_add(<<"temperature">>, temperature, Body, Params0),
    Params2 = maybe_add(<<"top_p">>, top_p, Body, Params1),
    maybe_add(<<"stop_sequences">>, stop, Body, Params2).

-spec maybe_add(binary(), atom(), map(), map()) -> map().
maybe_add(JsonKey, ErlKey, Body, Params) ->
    case maps:get(JsonKey, Body, undefined) of
        undefined -> Params;
        Value -> maps:put(ErlKey, Value, Params)
    end.
