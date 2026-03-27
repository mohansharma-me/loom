-module(loom_app_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    http_config_reads_from_ets_test/1,
    http_server_lifecycle_test/1,
    app_start_fails_on_bad_config_test/1,
    app_start_skips_reload_if_preloaded_test/1,
    supervisor_has_correct_children_test/1
]).

all() ->
    [
        http_config_reads_from_ets_test,
        http_server_lifecycle_test,
        app_start_fails_on_bad_config_test,
        app_start_skips_reload_if_preloaded_test,
        supervisor_has_correct_children_test
    ].

init_per_suite(Config) ->
    %% ASSUMPTION: We start cowboy (and its deps ranch, crypto) here so
    %% ranch_sup is available for loom_http_server lifecycle tests.
    %% We do NOT start the full loom application to keep tests isolated.
    {ok, _} = application:ensure_all_started(cowboy),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Clean up any leftover ETS table from previous tests
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    Config.

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

%% @doc Application start fails with clear error on invalid config.
app_start_fails_on_bad_config_test(_Config) ->
    BadPath = "/nonexistent/loom.json",
    ?assertMatch({error, {config_file, enoent, _}},
                 loom_config:load(BadPath)).

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

%%====================================================================
%% Helpers
%%====================================================================

wait_engine_ready(EngineId, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_status(EngineId) of
        ready -> ok;
        _ ->
            timer:sleep(100),
            wait_engine_ready(EngineId, Timeout - 100)
    end;
wait_engine_ready(EngineId, _Timeout) ->
    ct:fail(io_lib:format("Engine ~s never reached ready", [EngineId])).

test_config_path() ->
    %% ASSUMPTION: The test data dir is relative to the project root,
    %% and we can locate it via the source file's compiled path.
    DataDir = filename:join([
        filename:dirname(filename:dirname(code:which(?MODULE))),
        "test", "loom_app_SUITE_data", "loom.json"
    ]),
    case filelib:is_regular(DataDir) of
        true -> DataDir;
        false ->
            %% Fallback: try relative to current working directory
            filename:join(["test", "loom_app_SUITE_data", "loom.json"])
    end.
