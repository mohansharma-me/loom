-module(loom_json).

-export([encode/1, decode/1]).

-export_type([json_value/0, json_encodable/0]).

-type json_value() :: null | boolean() | number() | binary()
                    | [json_value()]
                    | #{binary() => json_value()}.

-type json_encodable() :: atom() | binary() | number()
                        | [json_encodable()]
                        | #{atom() | binary() | integer() => json_encodable()}.

%% @doc Encode an Erlang term to a JSON binary.
-spec encode(json_encodable()) -> binary().
encode(Term) ->
    iolist_to_binary(json:encode(Term)).

%% @doc Decode a JSON binary to an Erlang term.
%% ASSUMPTION: Returns maps with binary keys for all JSON objects.
%% This avoids atom table exhaustion from untrusted external input.
-spec decode(binary()) -> json_value().
decode(Binary) ->
    json:decode(Binary).
