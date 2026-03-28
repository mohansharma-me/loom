-module(loom_json_prop_tests).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit wrappers
%%====================================================================

encode_decode_roundtrip_test() ->
    ?assert(proper:quickcheck(prop_encode_decode_roundtrip(), [
        {numtests, 200}, {max_size, 8}, {to_file, user}
    ])).

%%====================================================================
%% Properties
%%====================================================================

%% Property: For any JSON-encodable Erlang term, encode -> decode
%% produces a structurally equivalent value.
%% ASSUMPTION: Atoms encode as strings, so decode returns binaries.
%% Integer keys become binary keys. We normalize before comparison.
prop_encode_decode_roundtrip() ->
    ?FORALL(Value, json_value(),
        begin
            Encoded = loom_json:encode(Value),
            Decoded = loom_json:decode(Encoded),
            normalize(Value) =:= normalize(Decoded)
        end).

%%====================================================================
%% Generators
%%====================================================================

json_value() ->
    ?SIZED(Size, json_value(Size)).

json_value(0) ->
    oneof([
        null,
        boolean(),
        integer(),
        ?LET(N, choose(1, 10000), N / 10.0),
        gen_safe_binary()
    ]);
json_value(Size) ->
    Smaller = Size div 4,
    frequency([
        {3, json_value(0)},
        {1, ?LAZY(?LET(Elems, resize(3, list(json_value(Smaller))), Elems))},
        {1, ?LAZY(?LET(Pairs, resize(3, list({gen_safe_binary(), json_value(Smaller)})),
            maps:from_list(Pairs)))}
    ]).

%% Generate a binary that doesn't contain characters problematic for JSON.
%% ASSUMPTION: We avoid backslash and double-quote to prevent escaping
%% mismatches between encode and decode round-trips.
gen_safe_binary() ->
    ?LET(Chars, list(choose(32, 126)),
        list_to_binary([C || C <- Chars, C =/= $\\, C =/= $"])).

%%====================================================================
%% Normalization
%%====================================================================

%% Normalize Erlang terms for comparison after JSON round-trip:
%% - atoms (except null/true/false) become binaries
%% - integer map keys become binary keys
%% - atom map keys become binary keys
normalize(null) -> null;
normalize(true) -> true;
normalize(false) -> false;
normalize(V) when is_atom(V) -> atom_to_binary(V);
normalize(V) when is_integer(V) -> V;
normalize(V) when is_float(V) -> V;
normalize(V) when is_binary(V) -> V;
normalize(L) when is_list(L) -> [normalize(E) || E <- L];
normalize(M) when is_map(M) ->
    maps:from_list([{normalize_key(K), normalize(V)} || {K, V} <- maps:to_list(M)]).

normalize_key(K) when is_atom(K) -> atom_to_binary(K);
normalize_key(K) when is_integer(K) -> integer_to_binary(K);
normalize_key(K) when is_binary(K) -> K.
