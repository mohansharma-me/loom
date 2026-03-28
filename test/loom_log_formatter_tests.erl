-module(loom_log_formatter_tests).
-include_lib("eunit/include/eunit.hrl").

format_report_map_test() ->
    Event = #{
        level => info,
        msg => {report, #{msg => engine_started, engine_id => <<"e1">>}},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"info">>, maps:get(<<"level">>, Map)),
    ?assertEqual(<<"engine_started">>, maps:get(<<"msg">>, Map)),
    ?assertEqual(<<"e1">>, maps:get(<<"engine_id">>, Map)),
    ?assert(maps:is_key(<<"time">>, Map)).

format_string_test() ->
    Event = #{
        level => warning,
        msg => {string, "something happened"},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"warning">>, maps:get(<<"level">>, Map)),
    ?assertEqual(<<"something happened">>, maps:get(<<"msg">>, Map)).

format_args_test() ->
    Event = #{
        level => error,
        msg => {"error: ~p", [timeout]},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"error">>, maps:get(<<"level">>, Map)),
    ?assert(is_binary(maps:get(<<"msg">>, Map))).

flatten_nested_test() ->
    Event = #{
        level => info,
        msg => {report, #{msg => test, error => #{reason => timeout, code => 500}}},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"timeout">>, maps:get(<<"error_reason">>, Map)),
    ?assertEqual(500, maps:get(<<"error_code">>, Map)).

check_config_test() ->
    ok = loom_log_formatter:check_config(#{}).

newline_terminated_test() ->
    Event = #{
        level => info,
        msg => {report, #{msg => test}},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    ?assertEqual($\n, binary:last(Bin)).

%% Verify the catch-all clause handles malformed events gracefully.
format_malformed_event_test() ->
    Result = loom_log_formatter:format(#{bad => data}, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"error">>, maps:get(<<"level">>, Map)),
    ?assert(is_binary(maps:get(<<"msg">>, Map))),
    ?assert(maps:is_key(<<"time">>, Map)).

%% Verify unknown message formats produce a msg with msg_format=unknown.
format_unknown_msg_format_test() ->
    Event = #{
        level => info,
        msg => some_unexpected_atom,
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assert(is_binary(maps:get(<<"msg">>, Map))),
    ?assertEqual(<<"unknown">>, maps:get(<<"msg_format">>, Map)).

%% Verify safe_value handles pid, reference, and tuple types.
format_with_pid_and_ref_test() ->
    Event = #{
        level => info,
        msg => {report, #{msg => test,
                          coordinator => self(),
                          ref => make_ref(),
                          reason => {error, timeout}}},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    %% All complex types should be converted to binary strings
    ?assert(is_binary(maps:get(<<"coordinator">>, Map))),
    ?assert(is_binary(maps:get(<<"ref">>, Map))),
    ?assert(is_binary(maps:get(<<"reason">>, Map))).

%% Verify format_time produces correct ISO 8601 timestamp.
format_time_correctness_test() ->
    %% 1711612800000000 microseconds = 2024-03-28T08:00:00.000000Z (UTC)
    Event = #{
        level => info,
        msg => {report, #{msg => test}},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"2024-03-28T08:00:00.000000Z">>, maps:get(<<"time">>, Map)).
