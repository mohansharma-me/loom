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
    ?assertEqual(8080, maps:get(port, Config)),
    ?assertEqual({0,0,0,0}, maps:get(ip, Config)),
    ?assertEqual(1024, maps:get(max_connections, Config)),
    ?assertEqual(60000, maps:get(inactivity_timeout, Config)),
    ?assertEqual(5000, maps:get(generate_timeout, Config)),
    ?assertEqual(10485760, maps:get(max_body_size, Config)),
    ?assertEqual(<<"engine_0">>, maps:get(engine_id, Config)).

merge_config_test() ->
    Config = loom_http_util:get_config(),
    %% With no app env set, should return defaults
    ?assertEqual(8080, maps:get(port, Config)).
