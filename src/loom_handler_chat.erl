-module(loom_handler_chat).
-behaviour(cowboy_loop).

-export([init/2, info/3, terminate/3]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    request_id :: binary() | undefined,
    engine_request_id :: binary() | undefined,
    model :: binary() | undefined,
    stream :: boolean() | undefined,
    tokens = [] :: [binary()],
    created :: non_neg_integer() | undefined,
    headers_sent = false :: boolean(),
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
                            Created = loom_http_util:unix_timestamp(),
                            State = #state{
                                request_id = RequestId,
                                engine_request_id = EngReqId,
                                model = Model,
                                stream = Stream,
                                tokens = [],
                                created = Created,
                                headers_sent = false,
                                inactivity_timeout = InactivityTimeout
                            },
                            case Stream of
                                true ->
                                    Req2 = loom_http_util:stream_reply(
                                        #{<<"x-request-id">> => RequestId}, Req1),
                                    {cowboy_loop, Req2, State#state{headers_sent = true},
                                     InactivityTimeout};
                                false ->
                                    {cowboy_loop, Req1, State, InactivityTimeout}
                            end;
                        {error, overloaded} ->
                            Err = loom_format_openai:format_error(
                                <<"rate_limit_error">>, <<"overloaded">>,
                                <<"Engine at max capacity">>),
                            Req2 = loom_http_util:json_response(429, Err, Req1),
                            {ok, Req2, #state{}};
                        {error, timeout} ->
                            Err = loom_format_openai:format_error(
                                <<"server_error">>, <<"timeout">>,
                                <<"Engine unresponsive">>),
                            Req2 = loom_http_util:json_response(504, Err, Req1),
                            {ok, Req2, #state{}};
                        {error, Reason} ->
                            Err = loom_format_openai:format_error(
                                <<"server_error">>, atom_to_binary(Reason),
                                <<"Engine unavailable">>),
                            Req2 = loom_http_util:json_response(503, Err, Req1),
                            {ok, Req2, #state{}}
                    end;
                {error, not_found} ->
                    Err = loom_format_openai:format_error(
                        <<"server_error">>, <<"engine_unavailable">>,
                        <<"No engine available">>),
                    Req2 = loom_http_util:json_response(503, Err, Req1),
                    {ok, Req2, #state{}}
            end;
        {error, ParseError, Req1} ->
            Err = loom_format_openai:format_error(
                <<"invalid_request_error">>, <<"bad_request">>, ParseError),
            Req2 = loom_http_util:json_response(400, Err, Req1),
            {ok, Req2, #state{}}
    end.

-spec info(any(), cowboy_req:req(), #state{}) ->
    {ok, cowboy_req:req(), #state{}, non_neg_integer()} |
    {stop, cowboy_req:req(), #state{}}.
info({loom_token, EngReqId, Text, _Finished},
     Req, #state{engine_request_id = EngReqId, stream = true} = State) ->
    Data = loom_format_openai:format_chunk(
        State#state.request_id, Text, State#state.model, State#state.created),
    loom_http_util:send_sse_data(Data, Req),
    {ok, Req, State, State#state.inactivity_timeout};

info({loom_token, EngReqId, Text, _Finished},
     Req, #state{engine_request_id = EngReqId, stream = false} = State) ->
    Tokens = [Text | State#state.tokens],
    {ok, Req, State#state{tokens = Tokens}, State#state.inactivity_timeout};

info({loom_done, EngReqId, _Stats},
     Req, #state{engine_request_id = EngReqId, stream = true} = State) ->
    %% Send final chunk with finish_reason=stop, then [DONE]
    FinalChunk = loom_format_openai:format_final_chunk(
        State#state.request_id, State#state.model, State#state.created),
    loom_http_util:send_sse_data(FinalChunk, Req),
    loom_http_util:send_sse_data(loom_format_openai:format_done(), Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info({loom_done, EngReqId, Stats},
     Req, #state{engine_request_id = EngReqId, stream = false} = State) ->
    Content = iolist_to_binary(lists:reverse(State#state.tokens)),
    Body = loom_format_openai:format_response(
        State#state.request_id, Content, State#state.model, Stats, State#state.created),
    Req2 = loom_http_util:json_response(200, Body, Req),
    {stop, Req2, State};

info({loom_error, EngReqId, _Code, Message},
     Req, #state{engine_request_id = EngReqId, headers_sent = true} = State) ->
    ErrData = loom_format_openai:format_stream_error(<<"server_error">>, Message),
    loom_http_util:send_sse_data(ErrData, Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info({loom_error, EngReqId, _Code, Message},
     Req, #state{engine_request_id = EngReqId, headers_sent = false} = State) ->
    Err = loom_format_openai:format_error(
        <<"server_error">>, <<"engine_error">>, Message),
    Req2 = loom_http_util:json_response(500, Err, Req),
    {stop, Req2, State};

info(timeout, Req, #state{headers_sent = true} = State) ->
    ?LOG_WARNING(#{msg => inactivity_timeout, request_id => State#state.request_id}),
    ErrData = loom_format_openai:format_stream_error(
        <<"server_error">>, <<"Request timed out">>),
    loom_http_util:send_sse_data(ErrData, Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info(timeout, Req, #state{headers_sent = false} = State) ->
    ?LOG_WARNING(#{msg => inactivity_timeout, request_id => State#state.request_id}),
    Err = loom_format_openai:format_error(
        <<"server_error">>, <<"timeout">>, <<"Request timed out">>),
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
            case loom_format_openai:parse_request(Map) of
                {ok, Parsed} -> {ok, Parsed, Req1};
                {error, Reason} -> {error, Reason, Req1}
            end;
        {error, Reason, Req1} ->
            {error, Reason, Req1}
    end.
