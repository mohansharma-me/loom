-module(loom_protocol_prop_tests).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit wrapper — runs PropEr tests via rebar3 eunit
%%====================================================================

encode_produces_valid_json_test() ->
    ?assert(proper:quickcheck(prop_encode_produces_valid_json(), [
        {numtests, 200}, {to_file, user}
    ])).

encode_type_field_correct_test() ->
    ?assert(proper:quickcheck(prop_encode_type_field_correct(), [
        {numtests, 200}, {to_file, user}
    ])).

buffer_chunking_test() ->
    ?assert(proper:quickcheck(prop_buffer_chunking(), [
        {numtests, 200}, {to_file, user}
    ])).

%%====================================================================
%% Properties
%%====================================================================

%% Property: For every outbound message, encode produces a binary that
%% ends with \n and whose body (without \n) is valid JSON that decodes
%% to a map.
prop_encode_produces_valid_json() ->
    ?FORALL(Msg, outbound_msg(),
        begin
            Encoded = loom_protocol:encode(Msg),
            %% Must end with newline
            ?assertEqual($\n, binary:last(Encoded)),
            %% Strip trailing newline and decode
            Line = binary:part(Encoded, 0, byte_size(Encoded) - 1),
            Map = loom_json:decode(Line),
            is_map(Map)
        end).

%% Property: The "type" field in encoded JSON matches the outbound message type.
prop_encode_type_field_correct() ->
    ?FORALL(Msg, outbound_msg(),
        begin
            Encoded = loom_protocol:encode(Msg),
            Line = binary:part(Encoded, 0, byte_size(Encoded) - 1),
            Map = loom_json:decode(Line),
            ExpectedType = expected_type(Msg),
            maps:get(<<"type">>, Map) =:= ExpectedType
        end).

%% Property: Feeding encoded data in random-sized chunks through the
%% buffer produces the same complete lines as feeding it all at once.
prop_buffer_chunking() ->
    ?FORALL({Msgs, ChunkSizes}, {non_empty(list(outbound_msg())), non_empty(list(pos_integer()))},
        begin
            Encoded = iolist_to_binary([loom_protocol:encode(M) || M <- Msgs]),
            %% Feed all at once
            {AllLines, _} = loom_protocol:feed(Encoded, loom_protocol:new_buffer()),
            %% Feed in chunks
            Chunks = chunk_binary(Encoded, ChunkSizes),
            {ChunkedLines, _} = lists:foldl(
                fun(Chunk, {AccLines, Buf}) ->
                    {NewLines, NewBuf} = loom_protocol:feed(Chunk, Buf),
                    {AccLines ++ NewLines, NewBuf}
                end,
                {[], loom_protocol:new_buffer()},
                Chunks),
            AllLines =:= ChunkedLines
        end).

%%====================================================================
%% Generators
%%====================================================================

outbound_msg() ->
    oneof([
        {health},
        {memory},
        {shutdown},
        ?LET(Id, gen_id(), {cancel, Id}),
        ?LET({Id, Prompt, Params}, {gen_id(), gen_prompt(), gen_params()},
            {generate, Id, Prompt, Params})
    ]).

gen_id() ->
    ?LET(N, pos_integer(),
        iolist_to_binary(["req-", integer_to_list(N)])).

gen_prompt() ->
    ?LET(Words, non_empty(list(gen_word())),
        iolist_to_binary(lists:join(<<" ">>, Words))).

gen_word() ->
    %% ASSUMPTION: Generate only lowercase ASCII to avoid JSON encoding edge cases.
    ?LET(Chars, non_empty(list(choose($a, $z))),
        list_to_binary(Chars)).

gen_params() ->
    ?LET({MaxTok, Temp, TopP}, {pos_integer(), gen_temperature(), gen_top_p()},
        maps:filter(fun(_, V) -> V =/= undefined end,
            #{max_tokens => MaxTok, temperature => Temp, top_p => TopP})).

gen_temperature() ->
    oneof([undefined, ?LET(N, choose(0, 200), N / 100.0)]).

gen_top_p() ->
    oneof([undefined, ?LET(N, choose(1, 100), N / 100.0)]).

%%====================================================================
%% Helpers
%%====================================================================

%% Map outbound message to expected JSON type field value.
expected_type({health}) -> <<"health">>;
expected_type({memory}) -> <<"memory">>;
expected_type({shutdown}) -> <<"shutdown">>;
expected_type({cancel, _}) -> <<"cancel">>;
expected_type({generate, _, _, _}) -> <<"generate">>.

%% Split a binary into chunks of the given sizes (cycling if needed).
chunk_binary(<<>>, _Sizes) -> [];
chunk_binary(Bin, []) -> [Bin];
chunk_binary(Bin, [Size | Rest]) ->
    case byte_size(Bin) =< Size of
        true -> [Bin];
        false ->
            <<Chunk:Size/binary, Remaining/binary>> = Bin,
            [Chunk | chunk_binary(Remaining, Rest ++ [Size])]
    end.
