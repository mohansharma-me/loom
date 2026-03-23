-module(loom_protocol).

-export([encode/1, decode/1, new_buffer/0, feed/2]).

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
decode(_Bin) ->
    erlang:error(not_implemented).

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
