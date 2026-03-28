-module(loom_protocol).
-dialyzer(no_underspecs).

-export([encode/1, decode/1, new_buffer/0, feed/2]).


-export_type([
    outbound_msg/0, inbound_msg/0, generate_params/0,
    buffer/0, decode_error/0
]).

%% --- Internal types ---

%% ASSUMPTION: json_object matches the shape returned by OTP 27 json:decode/1
%% for JSON objects. This avoids underspecs warnings from Dialyzer narrowing
%% bare map() to the specific JSON-decoded map shape.
-type json_object() :: #{binary() => json:decode_value()}.

%% --- Types ---

-type generate_params() :: #{
    max_tokens => pos_integer(),
    temperature => float(),
    top_p => float(),
    stop => [binary()]
}.

-type outbound_msg() ::
    {generate, Id :: binary(), Prompt :: binary(), Params :: generate_params()}
  | {health}
  | {memory}
  | {cancel, Id :: binary()}
  | {shutdown}.

-type inbound_msg() ::
    {token, Id :: binary(), TokenId :: non_neg_integer(), Text :: binary(), Finished :: boolean()}
  | {done, Id :: binary(), TokensGenerated :: non_neg_integer(), TimeMs :: non_neg_integer()}
  | {error, Id :: binary() | undefined, Code :: binary(), Message :: binary()}
  | {health_response, Status :: binary(), GpuUtil :: float(), MemUsedGb :: float(), MemTotalGb :: float()}
  | {memory_response, MemoryInfo :: #{binary() => number()}}
  | {ready, Model :: binary(), Backend :: binary()}
  | {heartbeat, Status :: binary(), Detail :: binary()}.

-opaque buffer() :: binary().

-type decode_error() ::
    {invalid_json, term()}
  | missing_type
  | {unknown_type, binary()}
  | {missing_field, binary(), binary()}
  | {invalid_field, binary(), atom(), term()}.

%% --- Public API ---

-spec encode(outbound_msg()) -> nonempty_binary().
encode({health}) ->
    terminate_line(loom_json:encode(#{type => health}));
encode({memory}) ->
    terminate_line(loom_json:encode(#{type => memory}));
encode({shutdown}) ->
    terminate_line(loom_json:encode(#{type => shutdown}));
encode({cancel, Id}) ->
    terminate_line(loom_json:encode(#{type => cancel, id => Id}));
encode({generate, Id, Prompt, Params}) ->
    terminate_line(loom_json:encode(#{
        type => generate,
        id => Id,
        prompt => Prompt,
        params => Params
    })).

-spec decode(binary()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode(Bin) ->
    case parse_json(Bin) of
        {ok, Map} when is_map(Map) ->
            case maps:get(<<"type">>, Map, undefined) of
                undefined -> {error, missing_type};
                Type -> decode_by_type(Type, Map)
            end;
        {ok, _NotMap} ->
            {error, missing_type};
        {error, _} = Err ->
            Err
    end.

%% ASSUMPTION: loom_json:decode/1 raises an exception on invalid JSON rather
%% than returning an error tuple, so try/catch is required here. This is
%% separated from decode/1 so decoder bugs don't get mislabeled as invalid_json.
-spec parse_json(binary()) -> {ok, json:decode_value()} | {error, decode_error()}.
parse_json(Bin) ->
    try loom_json:decode(Bin) of
        Result -> {ok, Result}
    catch
        _:Reason -> {error, {invalid_json, Reason}}
    end.

-spec decode_by_type(json:decode_value(), json_object()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_by_type(<<"token">>, Map) -> decode_token(Map);
decode_by_type(<<"done">>, Map) -> decode_done(Map);
decode_by_type(<<"error">>, Map) -> decode_error_msg(Map);
decode_by_type(<<"health">>, Map) -> decode_health(Map);
decode_by_type(<<"memory">>, Map) -> decode_memory(Map);
decode_by_type(<<"ready">>, Map) -> decode_ready(Map);
decode_by_type(<<"heartbeat">>, Map) -> decode_heartbeat(Map);
decode_by_type(Type, _Map) when is_binary(Type) -> {error, {unknown_type, Type}};
decode_by_type(_Type, _Map) -> {error, {unknown_type, <<"non_binary_type">>}}.

%% --- Validation helpers ---

-spec require(binary(), binary(), json_object()) -> {ok, json:decode_value()} | {error, decode_error()}.
require(Field, Type, Map) ->
    case maps:get(Field, Map, undefined) of
        undefined -> {error, {missing_field, Field, Type}};
        Value -> {ok, Value}
    end.

-spec require_type(binary(), atom(), json:decode_value(), fun((json:decode_value()) -> boolean())) ->
    {ok, json:decode_value()} | {error, decode_error()}.
require_type(Field, Expected, Value, Check) ->
    case Check(Value) of
        true -> {ok, Value};
        false -> {error, {invalid_field, Field, Expected, Value}}
    end.

-spec is_non_neg_integer(term()) -> boolean().
is_non_neg_integer(V) -> is_integer(V) andalso V >= 0.

-spec to_float(number()) -> float().
to_float(V) when is_integer(V) -> float(V);
to_float(V) when is_float(V) -> V.

%% Generic field extraction + validation
-spec with_fields(binary(), json_object(),
    [{binary(), atom(), fun((json:decode_value()) -> boolean())}],
    fun(([json:decode_value()]) -> {ok, inbound_msg()})) ->
    {ok, inbound_msg()} | {error, decode_error()}.
with_fields(Type, Map, Fields, Build) ->
    with_fields_acc(Type, Map, Fields, [], Build).

-spec with_fields_acc(binary(), json_object(),
    [{binary(), atom(), fun((json:decode_value()) -> boolean())}],
    [json:decode_value()],
    fun(([json:decode_value()]) -> {ok, inbound_msg()})) ->
    {ok, inbound_msg()} | {error, decode_error()}.
with_fields_acc(_Type, _Map, [], Acc, Build) ->
    Build(lists:reverse(Acc));
with_fields_acc(Type, Map, [{Field, Expected, Check} | Rest], Acc, Build) ->
    case require(Field, Type, Map) of
        {error, _} = Err -> Err;
        {ok, Value} ->
            case require_type(Field, Expected, Value, Check) of
                {error, _} = Err -> Err;
                {ok, Valid} -> with_fields_acc(Type, Map, Rest, [Valid | Acc], Build)
            end
    end.

%% --- Per-type decoders ---

-spec decode_token(json_object()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_token(Map) ->
    with_fields(<<"token">>, Map, [
        {<<"id">>, binary, fun is_binary/1},
        {<<"token_id">>, integer, fun is_non_neg_integer/1},
        {<<"text">>, binary, fun is_binary/1},
        {<<"finished">>, boolean, fun is_boolean/1}
    ], fun([Id, TokenId, Text, Finished]) ->
        {ok, {token, Id, TokenId, Text, Finished}}
    end).

-spec decode_done(json_object()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_done(Map) ->
    with_fields(<<"done">>, Map, [
        {<<"id">>, binary, fun is_binary/1},
        {<<"tokens_generated">>, integer, fun is_non_neg_integer/1},
        {<<"time_ms">>, integer, fun is_non_neg_integer/1}
    ], fun([Id, TokensGenerated, TimeMs]) ->
        {ok, {done, Id, TokensGenerated, TimeMs}}
    end).

-spec decode_error_msg(json_object()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_error_msg(Map) ->
    %% ASSUMPTION: OTP 27 json:decode/1 maps JSON null to the atom 'null'.
    %% id is optional: absent key -> undefined, null value -> undefined,
    %% binary value -> keep as-is, anything else -> validation error.
    Id = case maps:get(<<"id">>, Map, undefined) of
        null      -> undefined;
        undefined -> undefined;
        V when is_binary(V) -> V;
        Other -> Other  %% non-binary, non-null: will trigger invalid_field below
    end,
    case {Id, require(<<"code">>, <<"error">>, Map), require(<<"message">>, <<"error">>, Map)} of
        {_, {error, _} = Err, _} -> Err;
        {_, _, {error, _} = Err} -> Err;
        {Id2, {ok, Code}, {ok, Msg}} ->
            case {is_binary(Id2) orelse Id2 =:= undefined, is_binary(Code), is_binary(Msg)} of
                {true,  true,  true}  -> {ok, {error, Id2, Code, Msg}};
                {false, _,     _}     -> {error, {invalid_field, <<"id">>,      binary, Id2}};
                {_,     false, _}     -> {error, {invalid_field, <<"code">>,    binary, Code}};
                {_,     _,     false} -> {error, {invalid_field, <<"message">>, binary, Msg}}
            end
    end.

-spec decode_health(json_object()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_health(Map) ->
    with_fields(<<"health">>, Map, [
        {<<"status">>, binary, fun is_binary/1},
        {<<"gpu_util">>, number, fun is_number/1},
        {<<"mem_used_gb">>, number, fun is_number/1},
        {<<"mem_total_gb">>, number, fun is_number/1}
    ], fun([Status, GpuUtil, MemUsedGb, MemTotalGb]) ->
        {ok, {health_response, Status,
              to_float(GpuUtil), to_float(MemUsedGb), to_float(MemTotalGb)}}
    end).

-spec decode_memory(json_object()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_memory(Map) ->
    Type = <<"memory">>,
    %% Validate required keys exist and are numbers
    Required = [<<"total_gb">>, <<"used_gb">>, <<"available_gb">>],
    case validate_required_numbers(Type, Map, Required) of
        {error, _} = Err -> Err;
        ok ->
            %% Strip the "type" key, coerce required numeric fields to float
            Info0 = maps:remove(<<"type">>, Map),
            Info = Info0#{
                <<"total_gb">> := to_float(maps:get(<<"total_gb">>, Info0)),
                <<"used_gb">> := to_float(maps:get(<<"used_gb">>, Info0)),
                <<"available_gb">> := to_float(maps:get(<<"available_gb">>, Info0))
            },
            {ok, {memory_response, Info}}
    end.

-spec validate_required_numbers(binary(), json_object(), [binary()]) ->
    ok | {error, decode_error()}.
validate_required_numbers(_Type, _Map, []) ->
    ok;
validate_required_numbers(Type, Map, [Field | Rest]) ->
    case maps:get(Field, Map, undefined) of
        undefined -> {error, {missing_field, Field, Type}};
        V when is_number(V) -> validate_required_numbers(Type, Map, Rest);
        V -> {error, {invalid_field, Field, number, V}}
    end.

-spec decode_ready(json_object()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_ready(Map) ->
    with_fields(<<"ready">>, Map, [
        {<<"model">>, binary, fun is_binary/1},
        {<<"backend">>, binary, fun is_binary/1}
    ], fun([Model, Backend]) ->
        {ok, {ready, Model, Backend}}
    end).

-spec decode_heartbeat(json_object()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_heartbeat(Map) ->
    %% ASSUMPTION: status is required; detail is optional and defaults to <<"">>
    %% when absent. A present but non-binary detail triggers {invalid_field, ...}.
    Detail = case maps:get(<<"detail">>, Map, undefined) of
        undefined -> {ok, <<"">>};
        V when is_binary(V) -> {ok, V};
        Other -> {error, {invalid_field, <<"detail">>, binary, Other}}
    end,
    case {require(<<"status">>, <<"heartbeat">>, Map), Detail} of
        {{error, _} = Err, _} -> Err;
        {_, {error, _} = Err} -> Err;
        {{ok, Status}, {ok, _}} when not is_binary(Status) ->
            {error, {invalid_field, <<"status">>, binary, Status}};
        {{ok, Status}, {ok, D}} ->
            {ok, {heartbeat, Status, D}}
    end.

-spec new_buffer() -> buffer().
new_buffer() ->
    <<>>.

%% --- Internal helpers ---

-spec terminate_line(binary()) -> nonempty_binary().
terminate_line(JsonBin) ->
    <<JsonBin/binary, $\n>>.

%% @doc Feed raw bytes into the line buffer. Returns complete lines and the
%% remaining buffer. NOTE: Consecutive newlines produce empty lines (<<>>)
%% in the output -- callers should filter these before passing to decode/1.
-spec feed(binary(), buffer()) -> {[binary()], buffer()}.
feed(Data, Buf) ->
    Combined = <<Buf/binary, Data/binary>>,
    case binary:split(Combined, <<"\n">>, [global]) of
        [NoNewline] ->
            {[], NoNewline};
        Parts ->
            %% ASSUMPTION: binary:split with [global] always produces at least 2
            %% elements when a delimiter is found; the last element is the
            %% remainder after the final \n (empty binary if input ends with \n).
            {Lines, [Remainder]} = lists:split(length(Parts) - 1, Parts),
            {Lines, Remainder}
    end.
