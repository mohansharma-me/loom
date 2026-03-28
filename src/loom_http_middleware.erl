-module(loom_http_middleware).
-behaviour(cowboy_middleware).

-export([execute/2, emit_request_start/3, emit_request_stop/5]).

-include_lib("kernel/include/logger.hrl").

-spec execute(cowboy_req:req(), cowboy_middleware:env()) ->
    {ok, cowboy_req:req(), cowboy_middleware:env()} | {stop, cowboy_req:req()}.
execute(Req0, Env) ->
    RequestId = loom_http_util:generate_request_id(),
    logger:set_process_metadata(#{request_id => RequestId}),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, RequestId, Req0),
    %% Store request ID in Req metadata for handler access
    Req2 = Req1#{request_id => RequestId},
    Method = cowboy_req:method(Req2),
    Path = cowboy_req:path(Req2),
    ?LOG_INFO(#{msg => http_request, method => Method, path => Path, request_id => RequestId}),
    emit_request_start(Method, Path, RequestId),
    case validate_content_type(Method, Req2) of
        ok ->
            {ok, Req2, Env};
        {error, Req3} ->
            {stop, Req3}
    end.

%%====================================================================
%% Telemetry helpers
%%====================================================================

-spec emit_request_start(binary(), binary(), binary()) -> ok.
emit_request_start(Method, Path, RequestId) ->
    telemetry:execute([loom, http, request_start],
        #{system_time => erlang:system_time(millisecond)},
        #{method => Method, path => Path, request_id => RequestId}).

-spec emit_request_stop(non_neg_integer(), binary(), binary(), binary(), integer()) -> ok.
emit_request_stop(Duration, Method, Path, RequestId, Status) ->
    telemetry:execute([loom, http, request_stop],
        #{duration => Duration},
        #{method => Method, path => Path, request_id => RequestId, status => Status}).

%%% Internal

-spec validate_content_type(binary(), cowboy_req:req()) -> ok | {error, cowboy_req:req()}.
validate_content_type(<<"POST">>, Req) ->
    ContentType = cowboy_req:header(<<"content-type">>, Req, <<>>),
    case binary:match(ContentType, <<"application/json">>) of
        nomatch ->
            Body = loom_json:encode(#{
                <<"error">> => #{
                    <<"type">> => <<"invalid_request_error">>,
                    <<"message">> => <<"Content-Type must be application/json">>
                }
            }),
            Req2 = cowboy_req:reply(415,
                #{<<"content-type">> => <<"application/json">>},
                Body, Req),
            {error, Req2};
        _ ->
            ok
    end;
validate_content_type(_, _Req) ->
    ok.
