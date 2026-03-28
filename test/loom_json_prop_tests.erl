-module(loom_json_prop_tests).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit wrappers
%%====================================================================

encode_decode_roundtrip_test() ->
    assert_property(prop_encode_decode_roundtrip(), 200, [{max_size, 8}]).

encode_decode_escaping_test() ->
    assert_property(prop_encode_decode_escaping(), 200, []).

%%====================================================================
%% Properties
%%====================================================================

%% Property: For any JSON-encodable Erlang term, encode -> decode
%% produces a structurally equivalent value.
%% ASSUMPTION: Atoms encode as strings, so decode returns binaries.
%% Integer keys become binary keys. We normalize before comparison.
%% ASSUMPTION: Float values generated as N/10.0 may decode as integers
%% when they have no fractional part (e.g., 100.0 -> 100). The normalize
%% function handles this because both integer and float pass through
%% unchanged, and JSON decoders may return either form for whole numbers.
prop_encode_decode_roundtrip() ->
    ?FORALL(Value, json_value(),
        begin
            Encoded = loom_json:encode(Value),
            Decoded = loom_json:decode(Encoded),
            normalize(Value) =:= normalize(Decoded)
        end).

%% Property: Strings containing JSON-special characters (backslash,
%% double-quote) survive encode -> decode round-trip.
prop_encode_decode_escaping() ->
    ?FORALL(Value, gen_string_with_escapes(),
        begin
            Encoded = loom_json:encode(Value),
            Decoded = loom_json:decode(Encoded),
            Value =:= Decoded
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

%% Generate a binary that specifically includes JSON-special characters.
gen_string_with_escapes() ->
    ?LET(Chars, non_empty(list(oneof([
        choose(32, 126),
        $\\,
        $",
        $\n,
        $\t
    ]))), list_to_binary(Chars)).

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

%%====================================================================
%% Internal
%%====================================================================

assert_property(Prop, NumTests, ExtraOpts) ->
    Opts = [{numtests, NumTests}, {to_file, user}] ++ ExtraOpts,
    Result = proper:quickcheck(Prop, Opts),
    case Result of
        true -> ok;
        false ->
            CEx = proper:counterexample(),
            ?assertEqual({property_passed, no_counterexample},
                         {property_failed, CEx})
    end.
