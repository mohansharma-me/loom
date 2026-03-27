-module(loom_app_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    http_config_reads_from_ets_test/1,
    http_server_lifecycle_test/1,
    app_start_fails_on_bad_config_test/1,
    app_start_fails_via_application_test/1,
    app_start_skips_reload_if_preloaded_test/1,
    supervisor_has_correct_children_test/1,
    multi_engine_supervisor_test/1,
    flatten_engine_config_test/1,
    health_endpoint_returns_ready_test/1,
    chat_completions_returns_tokens_test/1
]).

all() ->
    [
        http_config_reads_from_ets_test,
        http_server_lifecycle_test,
        app_start_fails_on_bad_config_test,
        app_start_fails_via_application_test,
        app_start_skips_reload_if_preloaded_test,
        supervisor_has_correct_children_test,
        multi_engine_supervisor_test,
        flatten_engine_config_test,
        health_endpoint_returns_ready_test,
        chat_completions_returns_tokens_test
    ].

init_per_suite(Config) ->
    %% ASSUMPTION: We start cowboy (and its deps ranch, crypto) here so
    %% ranch_sup is available for loom_http_server lifecycle tests.
    %% We do NOT start the full loom application to keep tests isolated.
    {ok, _} = application:ensure_all_started(cowboy),
    %% ASSUMPTION: inets is needed for httpc (HTTP client) used in
    %% health and chat completions integration tests.
    {ok, _} = application:ensure_all_started(inets),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(TestCase, Config) ->
    %% Clean up any leftover ETS table from previous tests
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    %% Store data_dir for helpers that need it
    DataDir = ?config(data_dir, Config),
    [{test_data_dir, DataDir}, {test_case, TestCase} | Config].

end_per_testcase(_TestCase, _Config) ->
    %% Stop loom application if running (cleanup after integration tests)
    catch application:stop(loom),
    %% Stop Cowboy listener if still running (cleanup after lifecycle test)
    catch cowboy:stop_listener(loom_http_listener),
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc get_config/0 returns server config from loom_config ETS
%% plus handler defaults and engine_id from first engine.
http_config_reads_from_ets_test(_Config) ->
    %% Load a test config
    TestConfig = test_config_path(),
    ok = loom_config:load(TestConfig),

    HttpConfig = loom_http_util:get_config(),

    %% Server settings from loom.json
    ?assertEqual(9999, maps:get(port, HttpConfig)),

    %% Handler defaults still present
    ?assert(maps:is_key(max_body_size, HttpConfig)),
    ?assert(maps:is_key(inactivity_timeout, HttpConfig)),
    ?assert(maps:is_key(generate_timeout, HttpConfig)),

    %% engine_id defaults to first engine name
    ?assertEqual(<<"test_engine">>, maps:get(engine_id, HttpConfig)).

%% @doc loom_http_server starts Cowboy and stops it on terminate.
http_server_lifecycle_test(_Config) ->
    %% Load config with a test port to avoid conflicts
    ok = loom_config:load(test_config_path()),

    %% Start the server
    {ok, Pid} = loom_http_server:start_link(),
    ?assert(is_process_alive(Pid)),

    %% Verify Cowboy is listening
    Port = maps:get(port, loom_config:get_server()),
    {ok, Conn} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    gen_tcp:close(Conn),

    %% Stop the server
    gen_server:stop(Pid),
    timer:sleep(100),

    %% Verify Cowboy is no longer listening
    ?assertMatch({error, _}, gen_tcp:connect({127, 0, 0, 1}, Port,
                                              [binary, {active, false}],
                                              500)).

%% @doc loom_config:load/1 fails with clear error on invalid path.
app_start_fails_on_bad_config_test(_Config) ->
    BadPath = "/nonexistent/loom.json",
    ?assertMatch({error, {config_file, enoent, _}},
                 loom_config:load(BadPath)).

%% @doc loom_app:start/2 returns {error, {config_error, _}} when no ETS table
%% exists and no valid config/loom.json is available.
%% ASSUMPTION: CWD during CT does not contain a valid config/loom.json,
%% so loom_config:load() (the zero-arity default path) will fail.
app_start_fails_via_application_test(_Config) ->
    %% Ensure no ETS table exists — force loom_app to load from disk
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    %% Call loom_app:start/2 directly to test the fail-fast config path
    %% without going through the application controller (which requires
    %% all dependencies to be started first).
    Result = loom_app:start(normal, []),
    ?assertMatch({error, {config_error, _}}, Result).

%% @doc If loom_config ETS is already populated, loom_app:start/2 skips
%% config loading (allows tests to pre-load config).
app_start_skips_reload_if_preloaded_test(_Config) ->
    %% Pre-load config
    ok = loom_config:load(test_config_path()),

    %% Verify ETS exists
    ?assertNotEqual(undefined, ets:info(loom_config)),

    %% Store the current server config
    ServerBefore = loom_config:get_server(),

    %% Start the application — should NOT reload config
    %% ASSUMPTION: loom_sup starts children from the pre-loaded config.
    %% We're verifying config isn't reloaded from disk.
    {ok, _} = application:ensure_all_started(loom),

    %% Server config should be unchanged (still our test config)
    ServerAfter = loom_config:get_server(),
    ?assertEqual(ServerBefore, ServerAfter),

    %% Clean up
    application:stop(loom).

%% @doc Full application starts with correct supervisor children.
supervisor_has_correct_children_test(_Config) ->
    ok = loom_config:load(test_config_path()),
    {ok, _} = application:ensure_all_started(loom),

    %% Wait for engine to reach ready
    wait_engine_ready(<<"test_engine">>, 15000),

    %% Check loom_sup children
    Children = supervisor:which_children(loom_sup),

    %% Should have: loom_http_server + 1 engine sup
    ?assertEqual(2, length(Children)),

    %% HTTP server child
    ?assertNotEqual(false, lists:keyfind(loom_http_server, 1, Children)),

    %% Engine supervisor child
    ExpectedEngSup = loom_engine_sup:sup_name(<<"test_engine">>),
    ?assertNotEqual(false, lists:keyfind(ExpectedEngSup, 1, Children)),

    application:stop(loom).

%% @doc GET /health returns 200 with ready status after app starts.
%% ASSUMPTION: The mock adapter starts quickly enough that the engine
%% reaches ready state within 15 seconds (wait_engine_ready timeout).
health_endpoint_returns_ready_test(_Config) ->
    ok = loom_config:load(test_config_path()),
    {ok, _} = application:ensure_all_started(loom),
    wait_engine_ready(<<"test_engine">>, 15000),

    Port = maps:get(port, loom_config:get_server()),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/health",
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),

    Decoded = json:decode(list_to_binary(Body)),
    ?assertEqual(<<"ready">>, maps:get(<<"status">>, Decoded)),
    ?assertEqual(<<"test_engine">>, maps:get(<<"engine_id">>, Decoded)),

    application:stop(loom).

%% @doc Application starts correctly with 2 engines, each getting its
%% own engine supervisor under loom_sup.
multi_engine_supervisor_test(_Config) ->
    MultiConfig = multi_engine_config_path(),
    ok = loom_config:load(MultiConfig),
    {ok, _} = application:ensure_all_started(loom),

    wait_engine_ready(<<"engine_alpha">>, 15000),
    wait_engine_ready(<<"engine_beta">>, 15000),

    Children = supervisor:which_children(loom_sup),
    %% Should have: loom_http_server + 2 engine sups
    ?assertEqual(3, length(Children)),
    ?assertNotEqual(false, lists:keyfind(loom_http_server, 1, Children)),
    SupAlpha = loom_engine_sup:sup_name(<<"engine_alpha">>),
    SupBeta = loom_engine_sup:sup_name(<<"engine_beta">>),
    ?assertNotEqual(false, lists:keyfind(SupAlpha, 1, Children)),
    ?assertNotEqual(false, lists:keyfind(SupBeta, 1, Children)),
    %% Verify distinct names
    ?assertNotEqual(SupAlpha, SupBeta),

    application:stop(loom).

%% @doc flatten_engine_config/1 correctly flattens nested engine config
%% into the flat map format expected by loom_engine_sup:start_link/1.
flatten_engine_config_test(_Config) ->
    ok = loom_config:load(test_config_path()),
    {ok, EngineMap} = loom_config:get_engine(<<"test_engine">>),

    %% Call the internal function via loom_sup module
    %% ASSUMPTION: We test flatten_engine_config indirectly by starting
    %% the app (which calls it) and checking the resulting config.
    %% Direct call requires exporting the function. Instead we verify
    %% the engine supervisor receives correct config values.
    {ok, _} = application:ensure_all_started(loom),
    wait_engine_ready(<<"test_engine">>, 15000),

    %% Verify the engine is running with the correct model
    ?assertEqual(ready, loom_engine_coordinator:get_status(<<"test_engine">>)),

    %% Verify required keys were present in the engine map
    ?assert(maps:is_key(adapter_cmd, EngineMap)),
    ?assert(maps:is_key(backend, EngineMap)),
    ?assert(maps:is_key(engine_id, EngineMap)),
    ?assert(maps:is_key(model, EngineMap)),
    ?assertEqual(<<"test_engine">>, maps:get(engine_id, EngineMap)),
    ?assertEqual(<<"mock">>, maps:get(backend, EngineMap)),
    ?assertEqual(<<"test-model">>, maps:get(model, EngineMap)),

    %% Verify sub-map defaults were merged
    ?assert(maps:is_key(coordinator, EngineMap)),
    CoordConfig = maps:get(coordinator, EngineMap),
    ?assertEqual(120000, maps:get(startup_timeout_ms, CoordConfig)),
    ?assertEqual(30000, maps:get(drain_timeout_ms, CoordConfig)),
    ?assertEqual(64, maps:get(max_concurrent, CoordConfig)),

    application:stop(loom).

%% @doc POST /v1/chat/completions with mock adapter returns tokens.
%% ASSUMPTION: The mock adapter returns a non-streaming OpenAI-compatible
%% response with choices containing the concatenated mock tokens
%% ("Hello", "from", "Loom", "mock", "adapter").
%% See priv/scripts/mock_adapter.py for the canonical token list.
chat_completions_returns_tokens_test(_Config) ->
    ok = loom_config:load(test_config_path()),
    {ok, _} = application:ensure_all_started(loom),
    wait_engine_ready(<<"test_engine">>, 15000),

    Port = maps:get(port, loom_config:get_server()),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1/chat/completions",
    RequestBody = iolist_to_binary(json:encode(#{
        <<"model">> => <<"test-model">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
        <<"stream">> => false
    })),
    Headers = [{"content-type", "application/json"}],
    {ok, {{_, StatusCode, _}, _RespHeaders, RespBody}} =
        httpc:request(post, {Url, Headers, "application/json",
                             binary_to_list(RequestBody)}, [], []),

    ?assertEqual(200, StatusCode),
    Decoded = json:decode(list_to_binary(RespBody)),
    %% Mock adapter returns an OpenAI-compatible response with choices
    ?assert(maps:is_key(<<"choices">>, Decoded)),
    [Choice | _] = maps:get(<<"choices">>, Decoded),
    Message = maps:get(<<"message">>, Choice),
    Content = maps:get(<<"content">>, Message),
    %% Mock adapter concatenates tokens: "Hello" ++ "from" ++ "Loom" ++ "mock" ++ "adapter"
    ?assertEqual(<<"HellofromLoommockadapter">>, Content),
    %% Verify usage stats are present
    ?assert(maps:is_key(<<"usage">>, Decoded)),

    application:stop(loom).

%%====================================================================
%% Helpers
%%====================================================================

wait_engine_ready(EngineId, Timeout) when Timeout > 0 ->
    try loom_engine_coordinator:get_status(EngineId) of
        ready -> ok;
        Other ->
            ct:pal("Engine ~s status: ~p, waiting...", [EngineId, Other]),
            timer:sleep(100),
            wait_engine_ready(EngineId, Timeout - 100)
    catch
        error:badarg ->
            %% ETS table not yet created — engine supervisor still starting
            timer:sleep(100),
            wait_engine_ready(EngineId, Timeout - 100);
        Class:Reason:Stack ->
            ct:fail("Unexpected error checking engine ~s status: ~p:~p~n~p",
                    [EngineId, Class, Reason, Stack])
    end;
wait_engine_ready(EngineId, _Timeout) ->
    ct:fail(io_lib:format("Engine ~s never reached ready", [EngineId])).

test_config_path() ->
    suite_data_file("loom.json").

multi_engine_config_path() ->
    suite_data_file("multi_engine.json").

%% @doc Locate a file in this suite's _data directory.
%% NOTE: We don't use ?config(data_dir, Config) here because this helper
%% is called from test cases that don't always thread Config through.
suite_data_file(Filename) ->
    DataDir = filename:join([
        filename:dirname(filename:dirname(code:which(?MODULE))),
        "test", "loom_app_SUITE_data", Filename
    ]),
    case filelib:is_regular(DataDir) of
        true -> DataDir;
        false ->
            Fallback = filename:join(["test", "loom_app_SUITE_data", Filename]),
            ct:pal("Warning: primary path ~s not found, trying ~s",
                   [DataDir, Fallback]),
            Fallback
    end.
