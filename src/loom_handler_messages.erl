-module(loom_handler_messages).
-behaviour(cowboy_loop).

-export([init/2, info/3, terminate/3]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    request_id :: binary() | undefined,
    engine_request_id :: binary() | undefined,
    model :: binary() | undefined,
    stream :: boolean() | undefined,
    tokens = [] :: [binary()],
    token_count = 0 :: non_neg_integer(),
    headers_sent = false :: boolean(),
    block_started = false :: boolean(),
    inactivity_timeout :: non_neg_integer() | undefined
}).

-spec init(cowboy_req:req(), any()) ->
    {cowboy_loop, cowboy_req:req(), #state{}, non_neg_integer()} |
    {ok, cowboy_req:req(), #state{}}.
init(Req0, _Opts) ->
    Config = loom_http_util:get_config(),
    InactivityTimeout = maps:get(inactivity_timeout, Config),
    GenerateTimeout = maps:get(generate_timeout, Config),
    MaxBodySize = maps:get(max_body_size, Config),
    EngineId = maps:get(engine_id, Config),
    RequestId = maps:get(request_id, Req0, loom_http_util:generate_request_id()),
    MessageId = <<"msg_", RequestId/binary>>,
    case read_and_parse(Req0, MaxBodySize) of
        {ok, Parsed, Req1} ->
            Model = maps:get(model, Parsed),
            Stream = maps:get(stream, Parsed),
            Prompt = maps:get(prompt, Parsed),
            Params = maps:get(params, Parsed),
            case loom_http_util:lookup_coordinator(EngineId) of
                {ok, CoordPid} ->
                    case loom_http_util:try_generate(CoordPid, Prompt, Params, GenerateTimeout) of
                        {ok, EngReqId} ->
                            State = #state{
                                request_id = MessageId,
                                engine_request_id = EngReqId,
                                model = Model,
                                stream = Stream,
                                tokens = [],
                                token_count = 0,
                                headers_sent = false,
                                block_started = false,
                                inactivity_timeout = InactivityTimeout
                            },
                            case Stream of
                                true ->
                                    Req2 = loom_http_util:stream_reply(
                                        #{<<"x-request-id">> => RequestId}, Req1),
                                    %% Send message_start and content_block_start
                                    loom_http_util:send_sse_event(
                                        <<"message_start">>,
                                        loom_format_anthropic:format_message_start(MessageId, Model),
                                        Req2),
                                    loom_http_util:send_sse_event(
                                        <<"content_block_start">>,
                                        loom_format_anthropic:format_content_block_start(0),
                                        Req2),
                                    {cowboy_loop, Req2,
                                     State#state{headers_sent = true, block_started = true},
                                     InactivityTimeout};
                                false ->
                                    {cowboy_loop, Req1, State, InactivityTimeout}
                            end;
                        {error, overloaded} ->
                            Err = loom_format_anthropic:format_error(
                                <<"overloaded_error">>, <<"Engine at max capacity">>),
                            Req2 = loom_http_util:json_response(429, Err, Req1),
                            {ok, Req2, #state{}};
                        {error, timeout} ->
                            Err = loom_format_anthropic:format_error(
                                <<"api_error">>, <<"Engine unresponsive">>),
                            Req2 = loom_http_util:json_response(504, Err, Req1),
                            {ok, Req2, #state{}};
                        {error, Reason} ->
                            Err = loom_format_anthropic:format_error(
                                <<"api_error">>, iolist_to_binary(
                                    io_lib:format("Engine unavailable: ~p", [Reason]))),
                            Req2 = loom_http_util:json_response(503, Err, Req1),
                            {ok, Req2, #state{}}
                    end;
                {error, not_found} ->
                    Err = loom_format_anthropic:format_error(
                        <<"api_error">>, <<"No engine available">>),
                    Req2 = loom_http_util:json_response(503, Err, Req1),
                    {ok, Req2, #state{}}
            end;
        {error, ParseError, Req1} ->
            Err = loom_format_anthropic:format_error(
                <<"invalid_request_error">>, ParseError),
            Req2 = loom_http_util:json_response(400, Err, Req1),
            {ok, Req2, #state{}}
    end.

-spec info(any(), cowboy_req:req(), #state{}) ->
    {ok, cowboy_req:req(), #state{}, non_neg_integer()} |
    {stop, cowboy_req:req(), #state{}}.
info({loom_token, EngReqId, Text, _Finished},
     Req, #state{engine_request_id = EngReqId, stream = true} = State) ->
    Data = loom_format_anthropic:format_content_block_delta(0, Text),
    loom_http_util:send_sse_event(<<"content_block_delta">>, Data, Req),
    NewCount = State#state.token_count + 1,
    {ok, Req, State#state{token_count = NewCount}, State#state.inactivity_timeout};

info({loom_token, EngReqId, Text, _Finished},
     Req, #state{engine_request_id = EngReqId, stream = false} = State) ->
    Tokens = [Text | State#state.tokens],
    NewCount = State#state.token_count + 1,
    {ok, Req, State#state{tokens = Tokens, token_count = NewCount},
     State#state.inactivity_timeout};

info({loom_done, EngReqId, Stats},
     Req, #state{engine_request_id = EngReqId, stream = true} = State) ->
    TokenCount = maps:get(tokens, Stats, State#state.token_count),
    %% content_block_stop
    loom_http_util:send_sse_event(
        <<"content_block_stop">>,
        loom_format_anthropic:format_content_block_stop(0), Req),
    %% message_delta with usage
    loom_http_util:send_sse_event(
        <<"message_delta">>,
        loom_format_anthropic:format_message_delta(TokenCount), Req),
    %% message_stop
    loom_http_util:send_sse_event(
        <<"message_stop">>,
        loom_format_anthropic:format_message_stop(), Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info({loom_done, EngReqId, Stats},
     Req, #state{engine_request_id = EngReqId, stream = false} = State) ->
    Content = iolist_to_binary(lists:reverse(State#state.tokens)),
    Body = loom_format_anthropic:format_response(
        State#state.request_id, Content, State#state.model, Stats),
    Req2 = loom_http_util:json_response(200, Body, Req),
    {stop, Req2, State};

info({loom_error, EngReqId, _Code, Message},
     Req, #state{engine_request_id = EngReqId, headers_sent = true} = State) ->
    ErrData = loom_format_anthropic:format_stream_error(<<"api_error">>, Message),
    loom_http_util:send_sse_event(<<"error">>, ErrData, Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info({loom_error, EngReqId, _Code, Message},
     Req, #state{engine_request_id = EngReqId, headers_sent = false} = State) ->
    Err = loom_format_anthropic:format_error(<<"api_error">>, Message),
    Req2 = loom_http_util:json_response(500, Err, Req),
    {stop, Req2, State};

info(timeout, Req, #state{headers_sent = true} = State) ->
    ?LOG_WARNING(#{msg => inactivity_timeout, request_id => State#state.request_id}),
    ErrData = loom_format_anthropic:format_stream_error(
        <<"api_error">>, <<"Request timed out">>),
    loom_http_util:send_sse_event(<<"error">>, ErrData, Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info(timeout, Req, #state{headers_sent = false} = State) ->
    ?LOG_WARNING(#{msg => inactivity_timeout, request_id => State#state.request_id}),
    Err = loom_format_anthropic:format_error(<<"api_error">>, <<"Request timed out">>),
    Req2 = loom_http_util:json_response(504, Err, Req),
    {stop, Req2, State};

info(_Other, Req, State) ->
    {ok, Req, State, State#state.inactivity_timeout}.

-spec terminate(any(), cowboy_req:req(), #state{}) -> ok.
terminate(_Reason, _Req, _State) ->
    %% Process death triggers coordinator's DOWN monitor — automatic cleanup
    ok.

%%% Internal

-spec read_and_parse(cowboy_req:req(), non_neg_integer()) ->
    {ok, map(), cowboy_req:req()} | {error, binary(), cowboy_req:req()}.
read_and_parse(Req0, MaxBodySize) ->
    case loom_http_util:read_and_decode_body(Req0, MaxBodySize) of
        {ok, Map, Req1} ->
            case loom_format_anthropic:parse_request(Map) of
                {ok, Parsed} -> {ok, Parsed, Req1};
                {error, Reason} -> {error, Reason, Req1}
            end;
        {error, Reason, Req1} ->
            {error, Reason, Req1}
    end.
