%%%-------------------------------------------------------------------
%%% @doc Common Test suite for loom_engine_sup.
%%%
%%% Tests cover rest_for_one supervision semantics: child ordering,
%%% coordinator crash restarts all monitors, monitor crash restarts
%%% only that monitor, and restart intensity limits.
%%%
%%% ASSUMPTION: python3 is on PATH in the test environment.
%%% ASSUMPTION: The loom application is started in init_per_suite.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_engine_sup_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    start_with_config_test/1,
    start_with_no_gpus_test/1,
    different_configs_test/1,
    coordinator_crash_restarts_all_test/1,
    monitor_crash_restarts_only_monitor_test/1,
    middle_monitor_crash_cascades_test/1,
    max_restart_intensity_test/1,
    monitor_alerts_after_restart_test/1,
    config_missing_engine_id_test/1,
    config_invalid_engine_id_format_test/1,
    config_missing_adapter_cmd_test/1,
    config_invalid_adapter_cmd_test/1,
    config_invalid_gpus_test/1,
    config_invalid_max_restarts_test/1,
    config_invalid_drain_timeout_test/1,
    start_monitor_coordinator_not_found_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        start_with_config_test,
        start_with_no_gpus_test,
        different_configs_test,
        coordinator_crash_restarts_all_test,
        monitor_crash_restarts_only_monitor_test,
        middle_monitor_crash_cascades_test,
        max_restart_intensity_test,
        monitor_alerts_after_restart_test,
        config_missing_engine_id_test,
        config_invalid_engine_id_format_test,
        config_missing_adapter_cmd_test,
        config_invalid_adapter_cmd_test,
        config_invalid_gpus_test,
        config_invalid_max_restarts_test,
        config_invalid_drain_timeout_test,
        start_monitor_coordinator_not_found_test
    ].

init_per_suite(Config) ->
    %% Pre-load config before starting loom so loom_app:start/2 skips
    %% file-based loading (avoids CWD-dependent config resolution in test).
    ok = loom_config:load(fixture_path("minimal.json")),
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
    %% ASSUMPTION: loom_sup starts loom_http_server, which manages a Cowboy
    %% listener (under ranch_sup). Stopping loom triggers loom_http_server:terminate/2,
    %% which stops the Cowboy listener. Explicit stop here ensures cleanup even
    %% if loom_app didn't fully start.
    catch application:stop(loom),
    ok.

init_per_testcase(_TestCase, Config) ->
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_TestCase, _Config) ->
    %% Clean up any supervisor registered under known test engine_ids.
    %% This prevents leaked supervisors on assertion failure.
    lists:foreach(fun(Id) ->
        case whereis(loom_engine_sup:sup_name(Id)) of
            Pid when is_pid(Pid) ->
                exit(Pid, kill),
                wait_dead(Pid, 5000);
            _ -> ok
        end
    end, test_engine_ids()),
    flush_mailbox(),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc Supervisor starts with valid config, coordinator reaches ready,
%% supervisor is registered under the expected name.
start_with_config_test(_Config) ->
    EngineConfig = engine_config(<<"sup_test_1">>, [0, 1]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    ?assert(is_process_alive(SupPid)),

    %% Supervisor should be registered
    ExpectedName = loom_engine_sup:sup_name(<<"sup_test_1">>),
    ?assertEqual(SupPid, whereis(ExpectedName)),

    %% Should have coordinator + 2 GPU monitors = 3 children
    Children = supervisor:which_children(SupPid),
    ?assertEqual(3, length(Children)),

    %% Verify coordinator is present (rest_for_one depends on ordering)
    ?assertNotEqual(false, lists:keyfind(coordinator, 1, Children)),

    %% Coordinator should reach ready
    wait_status(<<"sup_test_1">>, ready, 10000),

    %% Clean shutdown
    stop_sup(SupPid).

%% @doc Supervisor starts with empty gpus list — only coordinator, no monitors.
start_with_no_gpus_test(_Config) ->
    EngineConfig = engine_config(<<"sup_test_no_gpu">>, []),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    ?assert(is_process_alive(SupPid)),

    %% Should have only the coordinator child
    Children = supervisor:which_children(SupPid),
    ?assertEqual(1, length(Children)),

    %% Coordinator should reach ready
    wait_status(<<"sup_test_no_gpu">>, ready, 10000),

    stop_sup(SupPid).

%% @doc Two supervisors with different engine configs start and operate
%% independently.
different_configs_test(_Config) ->
    Config1 = engine_config(<<"sup_diff_1">>, [0]),
    Config2 = engine_config(<<"sup_diff_2">>, [1]),
    {ok, Sup1} = loom_engine_sup:start_link(Config1),
    {ok, Sup2} = loom_engine_sup:start_link(Config2),
    ?assert(is_process_alive(Sup1)),
    ?assert(is_process_alive(Sup2)),
    ?assertNotEqual(Sup1, Sup2),
    ?assertEqual(Sup1, whereis(loom_engine_sup:sup_name(<<"sup_diff_1">>))),
    ?assertEqual(Sup2, whereis(loom_engine_sup:sup_name(<<"sup_diff_2">>))),
    ?assertEqual(2, length(supervisor:which_children(Sup1))),
    ?assertEqual(2, length(supervisor:which_children(Sup2))),
    wait_status(<<"sup_diff_1">>, ready, 10000),
    wait_status(<<"sup_diff_2">>, ready, 10000),
    stop_sup(Sup1),
    stop_sup(Sup2).

%% @doc Kill coordinator, verify ALL children get new pids (rest_for_one).
coordinator_crash_restarts_all_test(_Config) ->
    EngineId = <<"sup_crash_all">>,
    EngineConfig = engine_config(EngineId, [0, 1]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    wait_status(EngineId, ready, 10000),
    OldCoordPid = find_child(SupPid, coordinator),
    OldMon0Pid = find_child(SupPid, {gpu_monitor, 0}),
    OldMon1Pid = find_child(SupPid, {gpu_monitor, 1}),
    ?assert(is_pid(OldCoordPid)),
    ?assert(is_pid(OldMon0Pid)),
    ?assert(is_pid(OldMon1Pid)),
    exit(OldCoordPid, kill),
    %% Wait for the coordinator to actually be replaced before checking status
    NewCoordPid = wait_child_changed(SupPid, coordinator, OldCoordPid, 15000),
    wait_status(EngineId, ready, 15000),
    NewMon0Pid = find_child(SupPid, {gpu_monitor, 0}),
    NewMon1Pid = find_child(SupPid, {gpu_monitor, 1}),
    ?assertNotEqual(OldCoordPid, NewCoordPid),
    ?assertNotEqual(OldMon0Pid, NewMon0Pid),
    ?assertNotEqual(OldMon1Pid, NewMon1Pid),
    ?assertNot(is_process_alive(OldCoordPid)),
    ?assertNot(is_process_alive(OldMon0Pid)),
    ?assertNot(is_process_alive(OldMon1Pid)),
    ?assert(is_process_alive(NewCoordPid)),
    ?assert(is_process_alive(NewMon0Pid)),
    ?assert(is_process_alive(NewMon1Pid)),
    stop_sup(SupPid).

%% @doc Kill the last monitor, verify coordinator and earlier monitor keep
%% their pids. Under rest_for_one, only children started AFTER the crashed
%% child are restarted — killing the last monitor leaves all others intact.
monitor_crash_restarts_only_monitor_test(_Config) ->
    EngineId = <<"sup_crash_mon">>,
    EngineConfig = engine_config(EngineId, [0, 1]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    wait_status(EngineId, ready, 10000),
    OldCoordPid = find_child(SupPid, coordinator),
    OldMon0Pid = find_child(SupPid, {gpu_monitor, 0}),
    OldMon1Pid = find_child(SupPid, {gpu_monitor, 1}),
    %% Kill the LAST monitor (gpu 1) so rest_for_one doesn't cascade
    exit(OldMon1Pid, kill),
    NewMon1Pid = wait_child_changed(SupPid, {gpu_monitor, 1}, OldMon1Pid, 5000),
    ?assertEqual(OldCoordPid, find_child(SupPid, coordinator)),
    ?assertEqual(OldMon0Pid, find_child(SupPid, {gpu_monitor, 0})),
    ?assertNotEqual(OldMon1Pid, NewMon1Pid),
    ?assert(is_process_alive(NewMon1Pid)),
    stop_sup(SupPid).

%% @doc Crash coordinator past max_restarts=2, verify supervisor terminates.
max_restart_intensity_test(_Config) ->
    EngineId = <<"sup_max_restart">>,
    EngineConfig = (engine_config(EngineId, []))#{
        max_restarts => 2,
        max_period => 60,
        adapter_args => [mock_adapter_path(), "--startup-delay", "30"],
        startup_timeout_ms => 60000
    },
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    SupMonRef = erlang:monitor(process, SupPid),
    kill_coordinator_n_times(SupPid, 3, undefined),
    receive
        {'DOWN', SupMonRef, process, SupPid, shutdown} -> ok;
        {'DOWN', SupMonRef, process, SupPid, _Reason} -> ok
    after 15000 ->
        ct:fail("supervisor did not terminate after exceeding max restarts")
    end.

%% @doc After coordinator crash + restart, verify monitors are functional
%% with new coordinator.
monitor_alerts_after_restart_test(_Config) ->
    EngineId = <<"sup_alert_restart">>,
    EngineConfig = engine_config(EngineId, [0]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    wait_status(EngineId, ready, 10000),
    OldCoordPid = find_child(SupPid, coordinator),
    exit(OldCoordPid, kill),
    %% Wait for the coordinator to actually be replaced before checking status
    NewCoordPid = wait_child_changed(SupPid, coordinator, OldCoordPid, 15000),
    wait_status(EngineId, ready, 15000),
    ?assertNotEqual(OldCoordPid, NewCoordPid),
    NewMonPid = find_child(SupPid, {gpu_monitor, 0}),
    ?assert(is_process_alive(NewMonPid)),
    {ok, Metrics} = loom_gpu_monitor:force_poll(NewMonPid),
    ?assert(is_map(Metrics)),
    ?assertNot(is_process_alive(OldCoordPid)),
    ?assert(is_process_alive(NewCoordPid)),
    ?assert(is_process_alive(NewMonPid)),
    stop_sup(SupPid).

%% @doc Kill a middle monitor (gpu 0 out of [0, 1, 2]) and verify that
%% rest_for_one cascades: monitors 1 and 2 also restart, but the
%% coordinator is unaffected.
middle_monitor_crash_cascades_test(_Config) ->
    EngineId = <<"sup_crash_mid">>,
    EngineConfig = engine_config(EngineId, [0, 1, 2]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    wait_status(EngineId, ready, 10000),
    OldCoordPid = find_child(SupPid, coordinator),
    OldMon0Pid = find_child(SupPid, {gpu_monitor, 0}),
    OldMon1Pid = find_child(SupPid, {gpu_monitor, 1}),
    OldMon2Pid = find_child(SupPid, {gpu_monitor, 2}),
    %% Kill the FIRST monitor — rest_for_one should cascade to monitors 1 and 2
    exit(OldMon0Pid, kill),
    NewMon0Pid = wait_child_changed(SupPid, {gpu_monitor, 0}, OldMon0Pid, 5000),
    %% Wait for monitor 2 to also be replaced (it's after monitor 0)
    NewMon2Pid = wait_child_changed(SupPid, {gpu_monitor, 2}, OldMon2Pid, 5000),
    NewMon1Pid = find_child(SupPid, {gpu_monitor, 1}),
    %% Coordinator should be unaffected
    ?assertEqual(OldCoordPid, find_child(SupPid, coordinator)),
    %% All three monitors should have new pids
    ?assertNotEqual(OldMon0Pid, NewMon0Pid),
    ?assertNotEqual(OldMon1Pid, NewMon1Pid),
    ?assertNotEqual(OldMon2Pid, NewMon2Pid),
    ?assert(is_process_alive(NewMon0Pid)),
    ?assert(is_process_alive(NewMon1Pid)),
    ?assert(is_process_alive(NewMon2Pid)),
    stop_sup(SupPid).

%%--------------------------------------------------------------------
%% Config validation rejection tests
%%--------------------------------------------------------------------

%% @doc Missing engine_id is rejected.
config_missing_engine_id_test(_Config) ->
    Config = maps:remove(engine_id, engine_config(<<"dummy">>, [])),
    ?assertMatch({error, {missing_required, engine_id}},
                 loom_engine_sup:start_link(Config)).

%% @doc engine_id with invalid characters is rejected.
config_invalid_engine_id_format_test(_Config) ->
    Config = (engine_config(<<"dummy">>, []))#{engine_id => <<"hello world">>},
    ?assertMatch({error, {invalid_engine_id, bad_format}},
                 loom_engine_sup:start_link(Config)).

%% @doc Missing adapter_cmd is rejected.
config_missing_adapter_cmd_test(_Config) ->
    Config = maps:remove(adapter_cmd, engine_config(<<"dummy">>, [])),
    ?assertMatch({error, {missing_required, adapter_cmd}},
                 loom_engine_sup:start_link(Config)).

%% @doc Non-string adapter_cmd is rejected.
config_invalid_adapter_cmd_test(_Config) ->
    Config = (engine_config(<<"dummy">>, []))#{adapter_cmd => [1, 2, 3]},
    ?assertMatch({error, {invalid_adapter_cmd, not_printable_string}},
                 loom_engine_sup:start_link(Config)).

%% @doc Non-list gpus value is rejected.
config_invalid_gpus_test(_Config) ->
    Config = (engine_config(<<"dummy">>, []))#{gpus => "not_a_list"},
    %% "not_a_list" is a charlist which IS a list in Erlang, so use an atom
    Config2 = Config#{gpus => not_a_list},
    ?assertMatch({error, {invalid_gpus, expected_list, not_a_list}},
                 loom_engine_sup:start_link(Config2)).

%% @doc Non-integer max_restarts is rejected.
config_invalid_max_restarts_test(_Config) ->
    Config = (engine_config(<<"dummy">>, []))#{max_restarts => -1},
    ?assertMatch({error, {invalid_max_restarts, expected_non_neg_integer, -1}},
                 loom_engine_sup:start_link(Config)).

%% @doc Non-integer drain_timeout_ms is rejected.
config_invalid_drain_timeout_test(_Config) ->
    Config = (engine_config(<<"dummy">>, []))#{drain_timeout_ms => <<"30000">>},
    ?assertMatch({error, {invalid_drain_timeout_ms, expected_pos_integer, <<"30000">>}},
                 loom_engine_sup:start_link(Config)).

%%--------------------------------------------------------------------
%% Direct error path tests
%%--------------------------------------------------------------------

%% @doc start_monitor/2 with a nonexistent engine returns coordinator_not_found.
start_monitor_coordinator_not_found_test(_Config) ->
    ?assertMatch({error, coordinator_not_found},
                 loom_engine_sup:start_monitor(<<"nonexistent_engine">>,
                                               #{gpu_id => 0})).

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Path to test fixture JSON files.
fixture_path(Name) ->
    TestDir = filename:dirname(?FILE),
    filename:join([TestDir, "fixtures", Name]).

mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

python_cmd() ->
    os:find_executable("python3").

engine_config(EngineId, Gpus) ->
    #{
        engine_id => EngineId,
        model => <<"mock">>,
        backend => <<"mock">>,
        adapter_cmd => python_cmd(),
        adapter_args => [mock_adapter_path()],
        gpus => Gpus,
        gpu_poll_interval => 5000,
        allow_mock_backend => true,
        startup_timeout_ms => 10000,
        drain_timeout_ms => 5000
    }.

%% All engine_ids used across test cases — for cleanup.
test_engine_ids() ->
    [<<"sup_test_1">>, <<"sup_test_no_gpu">>, <<"sup_diff_1">>,
     <<"sup_diff_2">>, <<"sup_crash_all">>, <<"sup_crash_mon">>,
     <<"sup_crash_mid">>, <<"sup_max_restart">>, <<"sup_alert_restart">>].

wait_status(EngineId, Status, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_status(EngineId) of
        Status -> ok;
        _ ->
            timer:sleep(50),
            wait_status(EngineId, Status, Timeout - 50)
    end;
wait_status(_EngineId, Status, _Timeout) ->
    ct:fail(io_lib:format("wait_status: never reached ~p", [Status])).

wait_dead(Pid, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_dead_loop(Pid, Deadline).

wait_dead_loop(Pid, Deadline) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining > 0 of
                false ->
                    ct:fail(io_lib:format("wait_dead: ~p still alive", [Pid]));
                true ->
                    timer:sleep(min(50, Remaining)),
                    wait_dead_loop(Pid, Deadline)
            end
    end.

stop_sup(SupPid) ->
    erlang:unlink(SupPid),
    MonRef = erlang:monitor(process, SupPid),
    exit(SupPid, shutdown),
    receive
        {'DOWN', MonRef, process, SupPid, _} -> ok
    after 10000 ->
        ct:fail("supervisor did not stop")
    end.

%% @doc Find a child pid by id from a supervisor.
find_child(SupPid, ChildId) ->
    Children = supervisor:which_children(SupPid),
    case lists:keyfind(ChildId, 1, Children) of
        {ChildId, Pid, _, _} when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

%% @doc Wait until a child's pid changes from OldPid.
wait_child_changed(SupPid, ChildId, OldPid, Timeout) when Timeout > 0 ->
    case find_child(SupPid, ChildId) of
        Pid when is_pid(Pid), Pid =/= OldPid -> Pid;
        _ ->
            timer:sleep(50),
            wait_child_changed(SupPid, ChildId, OldPid, Timeout - 50)
    end;
wait_child_changed(_SupPid, ChildId, _OldPid, _Timeout) ->
    ct:fail(io_lib:format("wait_child_changed: ~p never changed", [ChildId])).

%% @doc Kill the coordinator N times, waiting for each restart.
kill_coordinator_n_times(_SupPid, 0, _LastPid) -> ok;
kill_coordinator_n_times(SupPid, N, LastPid) ->
    case is_process_alive(SupPid) of
        false -> ok;
        true ->
            CoordPid = wait_child_changed(SupPid, coordinator, LastPid, 10000),
            exit(CoordPid, kill),
            kill_coordinator_n_times(SupPid, N - 1, CoordPid)
    end.

flush_mailbox() ->
    receive _ -> flush_mailbox()
    after 0 -> ok
    end.
