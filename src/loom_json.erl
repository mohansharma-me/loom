-module(loom_json).

-export([encode/1, decode/1]).

%% @doc Encode an Erlang term to a JSON binary.
%% Supports maps, lists, binaries, numbers, and booleans.
-spec encode(term()) -> binary().
encode(Term) ->
    iolist_to_binary(json:encode(Term)).

%% @doc Decode a JSON binary to an Erlang term.
%% ASSUMPTION: Returns maps with binary keys for all JSON objects.
%% This avoids atom table exhaustion from untrusted external input.
-spec decode(binary()) -> term().
decode(Binary) ->
    json:decode(Binary).
