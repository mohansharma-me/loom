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

%% --- Merge logic ---

merge_defaults_override_hardcoded_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("full.json")),
    {ok, E} = loom_config:get_engine(<<"test_engine">>),
    Port = maps:get(port, E),
    ?assertEqual(20000, maps:get(heartbeat_timeout_ms, Port)),
    ?assertEqual(5000, maps:get(spawn_timeout_ms, Port)),
    GpuMon = maps:get(gpu_monitor, E),
    ?assertEqual(10000, maps:get(poll_interval_ms, GpuMon)),
    Thresholds = maps:get(thresholds, GpuMon),
    ?assertEqual(90.0, maps:get(temperature_c, Thresholds)),
    ?assertEqual(95.0, maps:get(mem_percent, Thresholds)),
    Coord = maps:get(coordinator, E),
    ?assertEqual(128, maps:get(max_concurrent, Coord)),
    ?assertEqual(120000, maps:get(startup_timeout_ms, Coord)),
    Sup = maps:get(engine_sup, E),
    ?assertEqual(10, maps:get(max_restarts, Sup)),
    ?assertEqual(60, maps:get(max_period, Sup)),
    cleanup_ets().

merge_server_section_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("full.json")),
    Server = loom_config:get_server(),
    ?assertEqual(9090, maps:get(port, Server)),
    ?assertEqual(2048, maps:get(max_connections, Server)),
    ?assertEqual({0,0,0,0}, maps:get(ip, Server)),
    cleanup_ets().

per_engine_overrides_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("overrides.json")),
    {ok, A} = loom_config:get_engine(<<"engine_a">>),
    PortA = maps:get(port, A),
    ?assertEqual(30000, maps:get(heartbeat_timeout_ms, PortA)),
    CoordA = maps:get(coordinator, A),
    ?assertEqual(256, maps:get(max_concurrent, CoordA)),
    GpuMonA = maps:get(gpu_monitor, A),
    ?assertEqual(2000, maps:get(poll_interval_ms, GpuMonA)),
    ThresholdsA = maps:get(thresholds, GpuMonA),
    ?assertEqual(80.0, maps:get(mem_percent, ThresholdsA)),
    ?assertEqual(85.0, maps:get(temperature_c, ThresholdsA)),
    {ok, B} = loom_config:get_engine(<<"engine_b">>),
    PortB = maps:get(port, B),
    ?assertEqual(20000, maps:get(heartbeat_timeout_ms, PortB)),
    CoordB = maps:get(coordinator, B),
    ?assertEqual(128, maps:get(max_concurrent, CoordB)),
    cleanup_ets().

engine_names_ordering_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("overrides.json")),
    ?assertEqual([<<"engine_a">>, <<"engine_b">>], loom_config:engine_names()),
    cleanup_ets().

get_engine_not_found_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("minimal.json")),
    ?assertEqual({error, not_found}, loom_config:get_engine(<<"nonexistent">>)),
    cleanup_ets().

get_nested_deep_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("full.json")),
    ?assertEqual(9090, loom_config:get([server, port], 0)),
    ?assertEqual(42, loom_config:get([server, nonexistent], 42)),
    ?assertEqual(99, loom_config:get([totally, missing, path], 99)),
    cleanup_ets().

%% --- Validation ---

validate_missing_engines_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{}">>),
    ?assertMatch({error, {validation, {missing_field, root, engines}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engines_empty_list_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": []}">>),
    ?assertMatch({error, {validation, {empty_engines}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engines_not_list_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": \"not a list\"}">>),
    ?assertMatch({error, {validation, {invalid_type, engines, expected_list}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_missing_name_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"backend\": \"mock\", \"model\": \"m\"}]}">>),
    ?assertMatch({error, {validation, {missing_field, engine, name}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_missing_backend_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"e\", \"model\": \"m\"}]}">>),
    ?assertMatch({error, {validation, {missing_field, engine, backend}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_missing_model_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"e\", \"backend\": \"mock\"}]}">>),
    ?assertMatch({error, {validation, {missing_field, engine, model}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_invalid_name_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"bad name!\", \"backend\": \"mock\", \"model\": \"m\"}]}">>),
    ?assertMatch({error, {validation, {invalid_engine_name, _}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_name_with_hyphens_and_dots_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"qwen2.5-1.5b\", \"backend\": \"mock\", \"model\": \"m\"}]}">>),
    ?assertEqual(ok, loom_config:load(Path)),
    ?assertEqual([<<"qwen2.5-1.5b">>], loom_config:engine_names()),
    file:delete(Path),
    cleanup_ets().

validate_duplicate_engine_names_test() ->
    cleanup_ets(),
    Json = <<"{\"engines\": [
        {\"name\": \"e1\", \"backend\": \"mock\", \"model\": \"m\"},
        {\"name\": \"e1\", \"backend\": \"mock\", \"model\": \"m2\"}
    ]}">>,
    Path = write_temp_file(Json),
    ?assertMatch({error, {validation, {duplicate_engine, <<"e1">>}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_unknown_backend_no_adapter_cmd_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"e1\", \"backend\": \"unknown_thing\", \"model\": \"m\"}]}">>),
    ?assertMatch({error, {validation, {unknown_backend, _, engine, _}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_unknown_backend_with_adapter_cmd_test() ->
    cleanup_ets(),
    Json = <<"{\"engines\": [{\"name\": \"e1\", \"backend\": \"custom\", \"model\": \"m\", \"adapter_cmd\": \"/bin/true\"}]}">>,
    Path = write_temp_file(Json),
    ?assertEqual(ok, loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_invalid_gpu_ids_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"e\", \"backend\": \"mock\", \"model\": \"m\", \"gpu_ids\": \"not_a_list\"}]}">>),
    ?assertMatch({error, {validation, {invalid_type, gpu_ids, expected_list}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_invalid_timeout_type_test() ->
    cleanup_ets(),
    Json = <<"{\"engines\": [{\"name\": \"e\", \"backend\": \"mock\", \"model\": \"m\"}], \"defaults\": {\"coordinator\": {\"max_concurrent\": \"not_int\"}}}">>,
    Path = write_temp_file(Json),
    ?assertMatch({error, {validation, _}}, loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

%% --- Adapter resolution ---

resolve_adapter_vllm_test() ->
    Expected = filename:join([code:priv_dir(loom), "python", "loom_adapter.py"]),
    ?assertEqual({ok, Expected},
                 loom_config:resolve_adapter(#{backend => <<"vllm">>})).

resolve_adapter_mlx_test() ->
    Expected = filename:join([code:priv_dir(loom), "python", "loom_adapter_mlx.py"]),
    ?assertEqual({ok, Expected},
                 loom_config:resolve_adapter(#{backend => <<"mlx">>})).

resolve_adapter_tensorrt_test() ->
    Expected = filename:join([code:priv_dir(loom), "python", "loom_adapter_trt.py"]),
    ?assertEqual({ok, Expected},
                 loom_config:resolve_adapter(#{backend => <<"tensorrt">>})).

resolve_adapter_custom_overrides_backend_test() ->
    ?assertEqual({ok, "/custom/adapter.py"},
                 loom_config:resolve_adapter(#{backend => <<"vllm">>,
                                               adapter_cmd => <<"/custom/adapter.py">>})).

resolve_adapter_mock_test() ->
    Expected = filename:join([code:priv_dir(loom), "python", "loom_adapter_mock.py"]),
    ?assertEqual({ok, Expected},
                 loom_config:resolve_adapter(#{backend => <<"mock">>})).

resolve_adapter_unknown_no_cmd_test() ->
    ?assertEqual({error, {unknown_backend, <<"foo">>}},
                 loom_config:resolve_adapter(#{backend => <<"foo">>})).

resolve_adapter_unknown_with_cmd_test() ->
    ?assertEqual({ok, "/my/custom.py"},
                 loom_config:resolve_adapter(#{backend => <<"foo">>,
                                               adapter_cmd => <<"/my/custom.py">>})).

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
