-module(loom_log_formatter).

%% Logger formatter callbacks
-export([format/2, check_config/1]).

%% @doc Format a log event as a single JSON line.
%% ASSUMPTION: The OTP logger framework provides Meta containing both process
%% metadata and per-call metadata already merged. This formatter filters
%% internal keys, converts report messages to map fields, and flattens
%% nested maps one level using underscore-joined keys.
-spec format(logger:log_event(), logger:formatter_config()) -> unicode:chardata().
format(#{level := Level, msg := Msg, meta := Meta}, _Config) ->
    Time = format_time(maps:get(time, Meta, erlang:system_time(microsecond))),
    MsgFields = extract_msg(Msg),
    FilteredMeta = maps:without([time, pid, gl, mfa, file, line, domain,
                                  report_cb, error_logger], Meta),
    Base = #{<<"time">> => Time, <<"level">> => atom_to_binary(Level)},
    Merged = maps:merge(Base, maps:merge(to_binary_keys(FilteredMeta),
                                          to_binary_keys(MsgFields))),
    Flattened = flatten_one_level(Merged),
    try
        [loom_json:encode(Flattened), $\n]
    catch
        _:_ ->
            %% Fallback: emit a safe representation rather than crash the formatter
            Safe = #{<<"time">> => Time, <<"level">> => atom_to_binary(Level),
                     <<"msg">> => iolist_to_binary(io_lib:format("~p", [MsgFields])),
                     <<"_encoding_error">> => <<"true">>},
            [loom_json:encode(Safe), $\n]
    end;
format(Event, _Config) ->
    %% Catch-all for malformed events — never crash the formatter
    Fallback = #{<<"time">> => format_time(erlang:system_time(microsecond)),
                 <<"level">> => <<"error">>,
                 <<"msg">> => iolist_to_binary(io_lib:format("malformed_log_event: ~p", [Event]))},
    [loom_json:encode(Fallback), $\n].

%% @doc No-op config validation — all configs accepted.
-spec check_config(logger:formatter_config()) -> ok | {error, term()}.
check_config(_Config) ->
    ok.

%%% Internal

-spec extract_msg(term()) -> map().
extract_msg({report, Report}) when is_map(Report) ->
    Report;
extract_msg({report, Report}) when is_list(Report) ->
    maps:from_list(Report);
extract_msg({string, String}) ->
    #{msg => iolist_to_binary([String])};
extract_msg({Format, Args}) when is_list(Format) ->
    #{msg => iolist_to_binary(io_lib:format(Format, Args))};
extract_msg(Other) ->
    #{msg => iolist_to_binary(io_lib:format("~p", [Other])),
      msg_format => <<"unknown">>}.

-spec format_time(integer()) -> binary().
format_time(TimeMicros) ->
    Seconds = TimeMicros div 1000000,
    Micros = TimeMicros rem 1000000,
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~6..0BZ",
                                    [Y, Mo, D, H, Mi, S, Micros])).

-spec to_binary_keys(map()) -> map().
to_binary_keys(Map) ->
    maps:fold(fun(K, V, Acc) ->
        maps:put(to_bin_key(K), safe_value(V), Acc)
    end, #{}, Map).

-spec safe_value(term()) -> term().
safe_value(V) when is_binary(V) -> V;
safe_value(V) when is_atom(V) -> atom_to_binary(V);
safe_value(V) when is_integer(V) -> V;
safe_value(V) when is_float(V) -> V;
safe_value(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> list_to_binary(V);
        false -> [safe_value(E) || E <- V]
    end;
safe_value(V) when is_map(V) -> to_binary_keys(V);
safe_value(V) when is_pid(V) -> list_to_binary(pid_to_list(V));
safe_value(V) when is_reference(V) -> list_to_binary(ref_to_list(V));
safe_value(V) when is_port(V) -> list_to_binary(port_to_list(V));
safe_value(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%% ASSUMPTION: Log report values are at most one level deep. Nested maps
%% beyond one level are preserved as JSON objects, not flattened.
-spec flatten_one_level(map()) -> map().
flatten_one_level(Map) ->
    maps:fold(fun(K, V, Acc) when is_map(V) ->
        maps:fold(fun(InnerK, InnerV, InnerAcc) ->
            FlatKey = <<K/binary, "_", (to_bin_key(InnerK))/binary>>,
            maps:put(FlatKey, safe_value(InnerV), InnerAcc)
        end, Acc, to_binary_keys(V));
    (K, V, Acc) ->
        maps:put(K, V, Acc)
    end, #{}, Map).

-spec to_bin_key(term()) -> binary().
to_bin_key(K) when is_binary(K) -> K;
to_bin_key(K) when is_atom(K) -> atom_to_binary(K);
to_bin_key(K) -> iolist_to_binary(io_lib:format("~p", [K])).
