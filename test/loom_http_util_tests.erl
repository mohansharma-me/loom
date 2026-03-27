-module(loom_http_util_tests).
-include_lib("eunit/include/eunit.hrl").

generate_request_id_format_test() ->
    Id = loom_http_util:generate_request_id(),
    ?assert(is_binary(Id)),
    ?assertMatch(<<"req-", _/binary>>, Id),
    %% 16 random bytes = 32 hex chars + "req-" prefix = 36 bytes
    ?assertEqual(36, byte_size(Id)).

generate_request_id_unique_test() ->
    Ids = [loom_http_util:generate_request_id() || _ <- lists:seq(1, 100)],
    ?assertEqual(100, length(lists:usort(Ids))).

timestamp_test() ->
    Ts = loom_http_util:unix_timestamp(),
    ?assert(is_integer(Ts)),
    ?assert(Ts > 1700000000).

default_config_test() ->
    Config = loom_http_util:default_config(),
    %% default_config/0 carries only handler-specific defaults
    ?assertEqual(60000, maps:get(inactivity_timeout, Config)),
    ?assertEqual(5000, maps:get(generate_timeout, Config)),
    ?assertEqual(10485760, maps:get(max_body_size, Config)),
    %% Server settings not in default_config
    ?assertEqual(error, maps:find(port, Config)),
    ?assertEqual(error, maps:find(ip, Config)),
    ?assertEqual(error, maps:find(engine_id, Config)).

get_config_crashes_with_no_engines_test() ->
    %% With no ETS table, get_config/0 crashes because no engines are configured
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    ?assertError(no_engines_configured, loom_http_util:get_config()).
