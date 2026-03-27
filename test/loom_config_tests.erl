-module(loom_config_tests).
-include_lib("eunit/include/eunit.hrl").

-define(TABLE, loom_config).

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

%% --- JSON parsing tests ---

load_minimal_config_test() ->
    cleanup_ets(),
    Path = fixture_path("minimal.json"),
    ?assertEqual(ok, loom_config:load(Path)),
    ?assertNotEqual(undefined, ets:info(?TABLE)),
    cleanup_ets().

load_file_not_found_test() ->
    cleanup_ets(),
    ?assertMatch({error, {config_file, enoent, _}},
                 loom_config:load("/nonexistent/path.json")),
    cleanup_ets().

load_invalid_json_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{ not valid json">>),
    ?assertMatch({error, {json_parse, _}}, loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

get_engine_names_test() ->
    cleanup_ets(),
    Path = fixture_path("minimal.json"),
    ok = loom_config:load(Path),
    ?assertEqual([<<"test_engine">>], loom_config:engine_names()),
    cleanup_ets().

get_server_defaults_when_no_server_section_test() ->
    cleanup_ets(),
    Path = fixture_path("minimal.json"),
    ok = loom_config:load(Path),
    Server = loom_config:get_server(),
    ?assertEqual(8080, maps:get(port, Server)),
    ?assertEqual({0,0,0,0}, maps:get(ip, Server)),
    cleanup_ets().

get_with_default_test() ->
    cleanup_ets(),
    Path = fixture_path("minimal.json"),
    ok = loom_config:load(Path),
    ?assertEqual(42, loom_config:get([nonexistent, key], 42)),
    cleanup_ets().

%% --- Helpers ---

fixture_path(Name) ->
    %% ASSUMPTION: ?FILE resolves to the test source file path at compile time,
    %% so we navigate from the test directory to fixtures/.
    TestDir = filename:dirname(?FILE),
    filename:join([TestDir, "fixtures", Name]).

write_temp_file(Content) ->
    Path = filename:join(["/tmp", "loom_config_test_" ++
                          integer_to_list(erlang:unique_integer([positive]))
                          ++ ".json"]),
    ok = file:write_file(Path, Content),
    Path.

cleanup_ets() ->
    case ets:info(?TABLE) of
        undefined -> ok;
        _ -> ets:delete(?TABLE)
    end.
