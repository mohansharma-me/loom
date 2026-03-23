-module(loom_protocol).

-export([encode/1, decode/1, new_buffer/0, feed/2]).

%% ASSUMPTION: to_float/1 is added now (unused until Task 7 health decode)
%% but suppressed here to avoid breaking the build; it will be used in Task 7.
-compile([{nowarn_unused_function, [to_float/1]}]).

-export_type([
    outbound_msg/0, inbound_msg/0, generate_params/0,
    buffer/0, decode_error/0
]).

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
  | {memory_response, MemoryInfo :: #{binary() => float() | term()}}
  | {ready, Model :: binary(), Backend :: binary()}.

-type buffer() :: binary().

-type decode_error() ::
    {invalid_json, term()}
  | missing_type
  | {unknown_type, binary()}
  | {missing_field, binary(), binary()}
  | {invalid_field, binary(), atom(), term()}.

%% --- Public API ---

-spec encode(outbound_msg()) -> binary().
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
    %% ASSUMPTION: loom_json:decode/1 raises an exception on invalid JSON rather
    %% than returning an error tuple, so try/catch is required here.
    try loom_json:decode(Bin) of
        Map when is_map(Map) ->
            case maps:get(<<"type">>, Map, undefined) of
                undefined -> {error, missing_type};
                Type -> decode_by_type(Type, Map)
            end;
        _NotMap ->
            {error, missing_type}
    catch
        _:Reason ->
            {error, {invalid_json, Reason}}
    end.

-spec decode_by_type(binary(), map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_by_type(<<"token">>, Map) -> decode_token(Map);
decode_by_type(<<"done">>, Map) -> decode_done(Map);
decode_by_type(<<"error">>, Map) -> decode_error_msg(Map);
decode_by_type(<<"health">>, Map) -> decode_health(Map);
decode_by_type(<<"memory">>, Map) -> decode_memory(Map);
decode_by_type(<<"ready">>, Map) -> decode_ready(Map);
decode_by_type(Type, _Map) -> {error, {unknown_type, Type}}.

%% --- Validation helpers ---

-spec require(binary(), binary(), map()) -> {ok, term()} | {error, decode_error()}.
require(Field, Type, Map) ->
    case maps:get(Field, Map, undefined) of
        undefined -> {error, {missing_field, Field, Type}};
        Value -> {ok, Value}
    end.

-spec require_type(binary(), atom(), term(), fun((term()) -> boolean())) ->
    {ok, term()} | {error, decode_error()}.
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
-spec with_fields(binary(), map(),
    [{binary(), atom(), fun((term()) -> boolean())}],
    fun(([term()]) -> {ok, inbound_msg()})) ->
    {ok, inbound_msg()} | {error, decode_error()}.
with_fields(Type, Map, Fields, Build) ->
    with_fields_acc(Type, Map, Fields, [], Build).

-spec with_fields_acc(binary(), map(),
    [{binary(), atom(), fun((term()) -> boolean())}],
    [term()],
    fun(([term()]) -> {ok, inbound_msg()})) ->
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

-spec decode_token(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_token(Map) ->
    with_fields(<<"token">>, Map, [
        {<<"id">>, binary, fun is_binary/1},
        {<<"token_id">>, integer, fun is_non_neg_integer/1},
        {<<"text">>, binary, fun is_binary/1},
        {<<"finished">>, boolean, fun is_boolean/1}
    ], fun([Id, TokenId, Text, Finished]) ->
        {ok, {token, Id, TokenId, Text, Finished}}
    end).

-spec decode_done(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_done(Map) ->
    with_fields(<<"done">>, Map, [
        {<<"id">>, binary, fun is_binary/1},
        {<<"tokens_generated">>, integer, fun is_non_neg_integer/1},
        {<<"time_ms">>, integer, fun is_non_neg_integer/1}
    ], fun([Id, TokensGenerated, TimeMs]) ->
        {ok, {done, Id, TokensGenerated, TimeMs}}
    end).

-spec decode_error_msg(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_error_msg(Map) ->
    %% ASSUMPTION: OTP 27 json:decode/1 maps JSON null to the atom 'null'.
    %% id is optional: absent key → undefined, null value → undefined,
    %% binary value → keep as-is, anything else → validation error.
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
-spec decode_health(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_health(_) -> erlang:error(not_implemented).
-spec decode_memory(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_memory(_) -> erlang:error(not_implemented).
-spec decode_ready(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_ready(_) -> erlang:error(not_implemented).

-spec new_buffer() -> buffer().
new_buffer() ->
    <<>>.

%% --- Internal helpers ---

-spec terminate_line(binary()) -> binary().
terminate_line(JsonBin) ->
    <<JsonBin/binary, $\n>>.

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
