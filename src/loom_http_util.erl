-module(loom_http_util).

%% ASSUMPTION: OTP >= 26 is required for binary:encode_hex/2 with lowercase option.
%% The rebar.config specifies {minimum_otp_vsn, "27"}, so this is safe.

-export([
    generate_request_id/0,
    unix_timestamp/0,
    default_config/0,
    get_config/0,
    json_response/3,
    stream_reply/2,
    send_sse_event/3,
    send_sse_data/2,
    lookup_coordinator/1,
    try_generate/4,
    read_and_decode_body/2
]).

-spec generate_request_id() -> binary().
generate_request_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    Hex = binary:encode_hex(Bytes, lowercase),
    <<"req-", Hex/binary>>.

-spec unix_timestamp() -> non_neg_integer().
unix_timestamp() ->
    erlang:system_time(second).

-spec default_config() -> map().
default_config() ->
    #{
        port => 8080,
        ip => {0, 0, 0, 0},
        max_connections => 1024,
        max_body_size => 10485760,
        inactivity_timeout => 60000,
        generate_timeout => 5000,
        engine_id => <<"engine_0">>
    }.

-spec get_config() -> map().
get_config() ->
    UserConfig = application:get_env(loom, http, #{}),
    maps:merge(default_config(), UserConfig).

-spec json_response(non_neg_integer(), map() | binary(), cowboy_req:req()) ->
    cowboy_req:req().
json_response(StatusCode, Body, Req) when is_map(Body) ->
    json_response(StatusCode, loom_json:encode(Body), Req);
json_response(StatusCode, Body, Req) when is_binary(Body) ->
    cowboy_req:reply(StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req).

-spec stream_reply(map(), cowboy_req:req()) -> cowboy_req:req().
stream_reply(Headers, Req) ->
    cowboy_req:stream_reply(200,
        maps:merge(#{<<"content-type">> => <<"text/event-stream">>,
                     <<"cache-control">> => <<"no-cache">>}, Headers),
        Req).

-spec send_sse_event(binary(), binary(), cowboy_req:req()) -> ok.
send_sse_event(Event, Data, Req) ->
    Chunk = [<<"event: ">>, Event, <<"\ndata: ">>, Data, <<"\n\n">>],
    cowboy_req:stream_body(iolist_to_binary(Chunk), nofin, Req).

-spec send_sse_data(binary(), cowboy_req:req()) -> ok.
send_sse_data(Data, Req) ->
    Chunk = [<<"data: ">>, Data, <<"\n\n">>],
    cowboy_req:stream_body(iolist_to_binary(Chunk), nofin, Req).

-spec lookup_coordinator(binary()) -> {ok, pid()} | {error, not_found}.
lookup_coordinator(EngineId) ->
    MetaTable = loom_engine_coordinator:meta_table_name(EngineId),
    try ets:lookup(MetaTable, coordinator_pid) of
        [{coordinator_pid, Pid}] when is_pid(Pid) -> {ok, Pid};
        _ -> {error, not_found}
    catch
        error:badarg -> {error, not_found}
    end.

-spec try_generate(pid(), binary(), map(), timeout()) ->
    {ok, binary()} | {error, atom()}.
try_generate(CoordPid, Prompt, Params, Timeout) ->
    try
        loom_engine_coordinator:generate(CoordPid, Prompt, Params, Timeout)
    catch
        exit:{noproc, _} -> {error, stopped};
        exit:{timeout, _} -> {error, timeout}
    end.

-spec read_and_decode_body(cowboy_req:req(), non_neg_integer()) ->
    {ok, map(), cowboy_req:req()} | {error, binary(), cowboy_req:req()}.
read_and_decode_body(Req0, MaxBodySize) ->
    case cowboy_req:read_body(Req0, #{length => MaxBodySize}) of
        {ok, Body, Req1} ->
            try loom_json:decode(Body) of
                Map when is_map(Map) -> {ok, Map, Req1};
                _ -> {error, <<"Request body must be a JSON object">>, Req1}
            catch
                error:_ -> {error, <<"Invalid JSON body">>, Req1}
            end;
        {more, _, Req1} ->
            {error, <<"Request body too large">>, Req1}
    end.
