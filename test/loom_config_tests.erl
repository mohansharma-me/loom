-module(loom_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Hardcoded defaults ---

server_defaults_test() ->
    Defaults = loom_config:server_defaults(),
    ?assertEqual(8080, maps:get(port, Defaults)),
    ?assertEqual({0,0,0,0}, maps:get(ip, Defaults)),
    ?assertEqual(1024, maps:get(max_connections, Defaults)),
    ?assertEqual(10485760, maps:get(max_body_size, Defaults)),
    ?assertEqual(60000, maps:get(inactivity_timeout, Defaults)),
    ?assertEqual(5000, maps:get(generate_timeout, Defaults)).

port_defaults_test() ->
    Defaults = loom_config:port_defaults(),
    ?assertEqual(1048576, maps:get(max_line_length, Defaults)),
    ?assertEqual(5000, maps:get(spawn_timeout_ms, Defaults)),
    ?assertEqual(15000, maps:get(heartbeat_timeout_ms, Defaults)),
    ?assertEqual(10000, maps:get(shutdown_timeout_ms, Defaults)),
    ?assertEqual(5000, maps:get(post_close_timeout_ms, Defaults)).

gpu_monitor_defaults_test() ->
    Defaults = loom_config:gpu_monitor_defaults(),
    ?assertEqual(5000, maps:get(poll_interval_ms, Defaults)),
    ?assertEqual(3000, maps:get(poll_timeout_ms, Defaults)),
    ?assertEqual(auto, maps:get(backend, Defaults)),
    Thresholds = maps:get(thresholds, Defaults),
    ?assertEqual(85.0, maps:get(temperature_c, Thresholds)),
    ?assertEqual(95.0, maps:get(mem_percent, Thresholds)).

coordinator_defaults_test() ->
    Defaults = loom_config:coordinator_defaults(),
    ?assertEqual(120000, maps:get(startup_timeout_ms, Defaults)),
    ?assertEqual(30000, maps:get(drain_timeout_ms, Defaults)),
    ?assertEqual(64, maps:get(max_concurrent, Defaults)).

engine_sup_defaults_test() ->
    Defaults = loom_config:engine_sup_defaults(),
    ?assertEqual(5, maps:get(max_restarts, Defaults)),
    ?assertEqual(60, maps:get(max_period, Defaults)).
