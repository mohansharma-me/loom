-module(loom_config_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    load_and_read_full_cycle_test/1,
    multiple_engines_test/1,
    concurrent_reads_test/1,
    reload_replaces_config_test/1,
    ets_table_is_public_test/1
]).

all() ->
    [
        load_and_read_full_cycle_test,
        multiple_engines_test,
        concurrent_reads_test,
        reload_replaces_config_test,
        ets_table_is_public_test
    ].

init_per_suite(Config) ->
    %% Pre-load config before starting loom so loom_app:start/2 skips
    %% file-based loading (avoids CWD-dependent config resolution in test).
    ok = loom_config:load(fixture_path("minimal.json")),
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    cleanup_ets(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    cleanup_ets(),
    ok.

%% --- Tests ---

load_and_read_full_cycle_test(_Config) ->
    Path = fixture_path("full.json"),
    ?assertEqual(ok, loom_config:load(Path)),
    {ok, Engine} = loom_config:get_engine(<<"test_engine">>),
    ?assertEqual(<<"test_engine">>, maps:get(engine_id, Engine)),
    ?assertEqual(<<"mock">>, maps:get(backend, Engine)),
    ?assertEqual(<<"test-model">>, maps:get(model, Engine)),
    ?assertEqual([0, 1], maps:get(gpu_ids, Engine)),
    Server = loom_config:get_server(),
    ?assertEqual(9090, maps:get(port, Server)),
    ?assertEqual(9090, loom_config:get([server, port], 0)).

multiple_engines_test(_Config) ->
    Path = fixture_path("overrides.json"),
    ok = loom_config:load(Path),
    ?assertEqual([<<"engine_a">>, <<"engine_b">>], loom_config:engine_names()),
    {ok, A} = loom_config:get_engine(<<"engine_a">>),
    {ok, B} = loom_config:get_engine(<<"engine_b">>),
    ?assertEqual(<<"model-a">>, maps:get(model, A)),
    ?assertEqual(<<"model-b">>, maps:get(model, B)),
    CoordA = maps:get(coordinator, A),
    CoordB = maps:get(coordinator, B),
    ?assertEqual(256, maps:get(max_concurrent, CoordA)),
    ?assertEqual(128, maps:get(max_concurrent, CoordB)).

concurrent_reads_test(_Config) ->
    Path = fixture_path("full.json"),
    ok = loom_config:load(Path),
    Self = self(),
    NumReaders = 50,
    Pids = [spawn_link(fun() ->
        lists:foreach(fun(_) ->
            {ok, _} = loom_config:get_engine(<<"test_engine">>),
            _ = loom_config:get_server(),
            _ = loom_config:engine_names()
        end, lists:seq(1, 100)),
        Self ! {done, self()}
    end) || _ <- lists:seq(1, NumReaders)],
    lists:foreach(fun(Pid) ->
        receive {done, Pid} -> ok
        after 5000 -> ct:fail({timeout, Pid})
        end
    end, Pids).

reload_replaces_config_test(_Config) ->
    ok = loom_config:load(fixture_path("minimal.json")),
    ?assertEqual([<<"test_engine">>], loom_config:engine_names()),
    Server1 = loom_config:get_server(),
    ?assertEqual(8080, maps:get(port, Server1)),
    ok = loom_config:load(fixture_path("full.json")),
    ?assertEqual([<<"test_engine">>], loom_config:engine_names()),
    Server2 = loom_config:get_server(),
    ?assertEqual(9090, maps:get(port, Server2)).

ets_table_is_public_test(_Config) ->
    ok = loom_config:load(fixture_path("minimal.json")),
    Self = self(),
    spawn_link(fun() ->
        Result = loom_config:engine_names(),
        Self ! {result, Result}
    end),
    receive
        {result, Names} -> ?assertEqual([<<"test_engine">>], Names)
    after 5000 -> ct:fail(timeout)
    end.

%% --- Helpers ---

%% ASSUMPTION: ?FILE resolves to the test source file path at compile time,
%% consistent with the approach used in loom_config_tests.erl (EUnit).
fixture_path(Name) ->
    TestDir = filename:dirname(?FILE),
    filename:join([TestDir, "fixtures", Name]).

cleanup_ets() ->
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end.
