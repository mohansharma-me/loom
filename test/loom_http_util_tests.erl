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
    %% default_config/0 now only carries handler-specific defaults
    ?assertEqual(60000, maps:get(inactivity_timeout, Config)),
    ?assertEqual(5000, maps:get(generate_timeout, Config)),
    ?assertEqual(10485760, maps:get(max_body_size, Config)),
    %% Server settings no longer in default_config
    ?assertEqual(error, maps:find(port, Config)),
    ?assertEqual(error, maps:find(ip, Config)),
    ?assertEqual(error, maps:find(engine_id, Config)).

get_config_defaults_test() ->
    %% With no ETS table, get_config falls back to loom_config:get_server/0 defaults
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    Config = loom_http_util:get_config(),
    %% Server defaults from loom_config:server_defaults/0
    ?assertEqual(8080, maps:get(port, Config)),
    %% engine_id falls back to <<"engine_0">> when no engines configured
    ?assertEqual(<<"engine_0">>, maps:get(engine_id, Config)).
