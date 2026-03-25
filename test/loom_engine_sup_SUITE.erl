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
    max_restart_intensity_test/1,
    monitor_alerts_after_restart_test/1
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
        max_restart_intensity_test,
        monitor_alerts_after_restart_test
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
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

%%====================================================================
%% Helpers
%%====================================================================

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
     <<"sup_max_restart">>, <<"sup_alert_restart">>].

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
