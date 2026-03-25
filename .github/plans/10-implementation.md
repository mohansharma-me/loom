# loom_engine_sup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `loom_engine_sup` as a `rest_for_one` supervisor managing one coordinator + N GPU monitors per engine.

**Architecture:** Supervisor registers as `{local, loom_engine_sup_<engine_id>}`. Child ordering: coordinator first, then one GPU monitor per GPU. Monitor child specs use `{loom_engine_sup, start_monitor, [EngineId, GpuOpts]}` as MFA so that coordinator PID is resolved dynamically on every restart via `supervisor:which_children/1`.

**Tech Stack:** Erlang/OTP supervisor behaviour, Common Test

**Design Spec:** `.github/plans/10-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/loom_engine_sup.erl` | New — `rest_for_one` supervisor: config validation, config mapping, child specs, `start_monitor/2` helper |
| `test/loom_engine_sup_SUITE.erl` | New — Common Test suite: startup, crash/restart semantics, restart intensity, alerts after restart |

No existing files need modification (`loom.app.src` uses `modules => []` so rebar3 auto-discovers).

## Reference: Key Existing Code

- **Coordinator start:** `loom_engine_coordinator:start_link(Config)` where Config requires `engine_id`, `command`, `model`, `backend`. Optional: `args`, `startup_timeout_ms`, `drain_timeout_ms`, `max_concurrent`, `port_opts`.
- **Coordinator status:** `loom_engine_coordinator:get_status(EngineId)` returns atom (ETS-backed, no message passing).
- **GPU monitor start:** `loom_gpu_monitor:start_link(Opts)` where Opts requires `gpu_id`. Optional: `poll_interval_ms`, `coordinator`, `backend`, `allow_mock_backend`, `thresholds`, `poll_timeout_ms`.
- **Mock adapter:** `priv/scripts/mock_adapter.py` — used by coordinator tests, started via `python3`.
- **Test patterns:** See `test/loom_engine_coordinator_SUITE.erl` and `test/loom_gpu_monitor_SUITE.erl` for CT style: `init_per_suite` starts loom app, `init_per_testcase` traps exits, `end_per_testcase` flushes mailbox.

---

### Task 1: Skeleton supervisor module with config validation

**Files:**
- Create: `src/loom_engine_sup.erl`
- Test: `test/loom_engine_sup_SUITE.erl`

This task creates the module skeleton with config validation and the `sup_name/1` helper. The supervisor's `init/1` returns only the coordinator child (no monitors yet). This lets us verify the basic supervisor starts and registers correctly.

- [ ] **Step 1: Write failing test — supervisor starts with valid config**

Create `test/loom_engine_sup_SUITE.erl`:

```erlang
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
    start_with_no_gpus_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        start_with_config_test,
        start_with_no_gpus_test
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

%% All engine_ids used across test cases — for cleanup.
test_engine_ids() ->
    [<<"sup_test_1">>, <<"sup_test_no_gpu">>, <<"sup_diff_1">>,
     <<"sup_diff_2">>, <<"sup_crash_all">>, <<"sup_crash_mon">>,
     <<"sup_max_restart">>, <<"sup_alert_restart">>].

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

flush_mailbox() ->
    receive _ -> flush_mailbox()
    after 0 -> ok
    end.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rebar3 ct --suite=test/loom_engine_sup_SUITE --case=start_with_config_test`
Expected: FAIL — module `loom_engine_sup` not found.

- [ ] **Step 3: Write minimal implementation**

Create `src/loom_engine_sup.erl`:

```erlang
%%%-------------------------------------------------------------------
%%% @doc loom_engine_sup - rest_for_one supervisor for a single engine.
%%%
%%% Manages one loom_engine_coordinator and N loom_gpu_monitor children.
%%% Child ordering: coordinator first, then one monitor per GPU.
%%%
%%% rest_for_one semantics:
%%% - Coordinator crash: restarts coordinator + all monitors
%%% - Monitor crash: restarts only that monitor
%%%
%%% GPU monitors discover the coordinator pid at start time via
%%% start_monitor/2, which looks up the coordinator from this
%%% supervisor's children list.
%%%
%%% ASSUMPTION: engine_id uniqueness is enforced by the caller
%%% (future loom_engine_pool_sup). Duplicate engine_ids will crash
%%% on supervisor name registration.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_engine_sup).
-behaviour(supervisor).

-export([start_link/1, start_monitor/2, sup_name/1]).
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

%%====================================================================
%% API
%%====================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    case validate_config(Config) of
        ok ->
            EngineId = maps:get(engine_id, Config),
            Name = sup_name(EngineId),
            ?LOG_INFO("loom_engine_sup: starting engine_id=~s "
                      "gpus=~p max_restarts=~b/~bs",
                      [EngineId,
                       maps:get(gpus, Config, []),
                       maps:get(max_restarts, Config, 5),
                       maps:get(max_period, Config, 60)]),
            supervisor:start_link({local, Name}, ?MODULE, Config);
        {error, _} = Err ->
            ?LOG_ERROR("loom_engine_sup: config validation failed: ~p", [Err]),
            Err
    end.

%% @doc Called by the supervisor to start a GPU monitor child.
%% Looks up the coordinator pid from the supervisor's children list.
%% NOT intended to be called directly — used as the MFA in monitor child specs.
-spec start_monitor(binary(), map()) -> {ok, pid()} | {error, term()}.
start_monitor(EngineId, GpuOpts) ->
    SupName = sup_name(EngineId),
    GpuId = maps:get(gpu_id, GpuOpts),
    Children = supervisor:which_children(SupName),
    case lists:keyfind(coordinator, 1, Children) of
        {coordinator, Pid, _, _} when is_pid(Pid) ->
            ?LOG_INFO("loom_engine_sup: starting gpu_monitor engine_id=~s "
                      "gpu_id=~p coordinator=~p",
                      [EngineId, GpuId, Pid]),
            loom_gpu_monitor:start_link(GpuOpts#{coordinator => Pid});
        Other ->
            ?LOG_ERROR("loom_engine_sup: coordinator not found for "
                       "engine_id=~s gpu_id=~p, children=~p",
                       [EngineId, GpuId, Other]),
            {error, coordinator_not_found}
    end.

%% @doc Derive the supervisor registered name from engine_id.
%% ASSUMPTION: engine_id is pre-validated as [a-zA-Z0-9_]+ (max 64 bytes)
%% by loom_engine_coordinator:validate_config/1. The derived atom is safe.
-spec sup_name(binary()) -> atom().
sup_name(EngineId) ->
    binary_to_atom(<<"loom_engine_sup_", EngineId/binary>>).

%%====================================================================
%% supervisor callback
%%====================================================================

-spec init(map()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Config) ->
    EngineId = maps:get(engine_id, Config),
    Gpus = maps:get(gpus, Config, []),

    CoordConfig = build_coordinator_config(Config),
    DrainTimeout = maps:get(drain_timeout_ms, Config, 30000),
    CoordShutdown = DrainTimeout + 5000,

    ?LOG_INFO("loom_engine_sup: building coordinator child spec "
              "engine_id=~s command=~s model=~s backend=~s shutdown=~bms",
              [EngineId,
               maps:get(command, CoordConfig),
               maps:get(model, CoordConfig),
               maps:get(backend, CoordConfig),
               CoordShutdown]),

    CoordChild = #{
        id => coordinator,
        start => {loom_engine_coordinator, start_link, [CoordConfig]},
        restart => permanent,
        shutdown => CoordShutdown,
        type => worker
    },

    MonitorChildren = [monitor_child_spec(EngineId, GpuId, Config)
                       || GpuId <- Gpus],

    MaxRestarts = maps:get(max_restarts, Config, 5),
    MaxPeriod = maps:get(max_period, Config, 60),

    SupFlags = #{
        strategy => rest_for_one,
        intensity => MaxRestarts,
        period => MaxPeriod
    },

    {ok, {SupFlags, [CoordChild | MonitorChildren]}}.

%%====================================================================
%% Internal
%%====================================================================

-spec validate_config(map()) -> ok | {error, term()}.
validate_config(Config) ->
    case maps:find(engine_id, Config) of
        {ok, Id} when is_binary(Id), byte_size(Id) > 0 -> validate_adapter(Config);
        {ok, _} -> {error, {invalid_engine_id, not_binary}};
        error -> {error, {missing_required, engine_id}}
    end.

-spec validate_adapter(map()) -> ok | {error, term()}.
validate_adapter(Config) ->
    case maps:find(adapter_cmd, Config) of
        {ok, Cmd} when is_list(Cmd), length(Cmd) > 0 -> ok;
        {ok, Cmd} when is_binary(Cmd), byte_size(Cmd) > 0 -> ok;
        {ok, _} -> {error, {invalid_adapter_cmd, empty_or_bad_type}};
        error -> {error, {missing_required, adapter_cmd}}
    end.

-spec build_coordinator_config(map()) -> map().
build_coordinator_config(Config) ->
    EngineId = maps:get(engine_id, Config),
    ?LOG_INFO("loom_engine_sup: mapping config for engine_id=~s: "
              "adapter_cmd->command, adapter_args->args, "
              "gpu_poll_interval->poll_interval_ms",
              [EngineId]),
    Base = #{
        engine_id => EngineId,
        command => maps:get(adapter_cmd, Config),
        args => maps:get(adapter_args, Config, []),
        model => maps:get(model, Config, <<>>),
        backend => maps:get(backend, Config, <<>>)
    },
    %% Forward optional coordinator-specific keys
    OptionalKeys = [startup_timeout_ms, drain_timeout_ms, max_concurrent, port_opts],
    lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Config) of
            {ok, Val} -> maps:put(Key, Val, Acc);
            error -> Acc
        end
    end, Base, OptionalKeys).

-spec monitor_child_spec(binary(), term(), map()) -> supervisor:child_spec().
monitor_child_spec(EngineId, GpuId, Config) ->
    GpuOpts = build_monitor_opts(GpuId, Config),
    #{
        id => {gpu_monitor, GpuId},
        start => {loom_engine_sup, start_monitor, [EngineId, GpuOpts]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.

-spec build_monitor_opts(term(), map()) -> map().
build_monitor_opts(GpuId, Config) ->
    Base = #{
        gpu_id => GpuId,
        poll_interval_ms => maps:get(gpu_poll_interval, Config, 5000),
        allow_mock_backend => maps:get(allow_mock_backend, Config, false)
    },
    %% Forward optional monitor-specific keys
    OptionalKeys = [poll_timeout_ms, thresholds, backend],
    lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Config) of
            {ok, Val} -> maps:put(Key, Val, Acc);
            error -> Acc
        end
    end, Base, OptionalKeys).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 ct --suite=test/loom_engine_sup_SUITE`
Expected: Both `start_with_config_test` and `start_with_no_gpus_test` PASS.

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_sup.erl test/loom_engine_sup_SUITE.erl
git commit -m "feat(engine_sup): implement loom_engine_sup rest_for_one supervisor (#10)

Adds loom_engine_sup with:
- rest_for_one strategy: coordinator first, then N GPU monitors
- start_monitor/2 helper for dynamic coordinator PID discovery
- Config mapping: adapter_cmd->command, adapter_args->args
- INFO logging at all key decision points
- Coordinator shutdown timeout = drain_timeout_ms + 5s margin

Tests: start_with_config, start_with_no_gpus"
```

---

### Task 2: Different configs test

**Files:**
- Modify: `test/loom_engine_sup_SUITE.erl`

Verify two supervisors with different engine configs operate independently.

- [ ] **Step 1: Write failing test**

Add to exports and `all/0`:

```erlang
different_configs_test/1
```

Add test case:

```erlang
%% @doc Two supervisors with different engine configs start and operate
%% independently without interfering with each other.
different_configs_test(_Config) ->
    Config1 = engine_config(<<"sup_diff_1">>, [0]),
    Config2 = engine_config(<<"sup_diff_2">>, [1]),
    {ok, Sup1} = loom_engine_sup:start_link(Config1),
    {ok, Sup2} = loom_engine_sup:start_link(Config2),

    ?assert(is_process_alive(Sup1)),
    ?assert(is_process_alive(Sup2)),
    ?assertNotEqual(Sup1, Sup2),

    %% Each supervisor registered under its own name
    ?assertEqual(Sup1, whereis(loom_engine_sup:sup_name(<<"sup_diff_1">>))),
    ?assertEqual(Sup2, whereis(loom_engine_sup:sup_name(<<"sup_diff_2">>))),

    %% Each has 2 children (coordinator + 1 monitor)
    ?assertEqual(2, length(supervisor:which_children(Sup1))),
    ?assertEqual(2, length(supervisor:which_children(Sup2))),

    %% Both coordinators reach ready
    wait_status(<<"sup_diff_1">>, ready, 10000),
    wait_status(<<"sup_diff_2">>, ready, 10000),

    stop_sup(Sup1),
    stop_sup(Sup2).

%% Note: Tests 2-6 add test coverage for behavior that is already implemented
%% in Task 1. The supervisor delegates to OTP rest_for_one semantics, so there
%% is no incremental production code — only verification of correct child spec
%% construction and supervision strategy.
```

- [ ] **Step 2: Run test to verify it passes**

Run: `rebar3 ct --suite=test/loom_engine_sup_SUITE --case=different_configs_test`
Expected: PASS (implementation already supports this).

- [ ] **Step 3: Commit**

```bash
git add test/loom_engine_sup_SUITE.erl
git commit -m "test(engine_sup): add different_configs_test (#10)"
```

---

### Task 3: Coordinator crash restarts all monitors

**Files:**
- Modify: `test/loom_engine_sup_SUITE.erl`

This is the core `rest_for_one` test. Kill the coordinator, verify all monitors die and restart with the new coordinator's pid.

- [ ] **Step 1: Write failing test**

Add to exports and `all/0`:

```erlang
coordinator_crash_restarts_all_test/1
```

Add helpers:

```erlang
%% @doc Find a child pid by id from a supervisor.
find_child(SupPid, ChildId) ->
    Children = supervisor:which_children(SupPid),
    case lists:keyfind(ChildId, 1, Children) of
        {ChildId, Pid, _, _} when is_pid(Pid) -> Pid;
        _ -> undefined
    end.

%% @doc Wait until a child's pid changes from OldPid (or appears if undefined).
wait_child_changed(SupPid, ChildId, OldPid, Timeout) when Timeout > 0 ->
    case find_child(SupPid, ChildId) of
        Pid when is_pid(Pid), Pid =/= OldPid -> Pid;
        _ ->
            timer:sleep(50),
            wait_child_changed(SupPid, ChildId, OldPid, Timeout - 50)
    end;
wait_child_changed(_SupPid, ChildId, _OldPid, _Timeout) ->
    ct:fail(io_lib:format("wait_child_changed: ~p never changed", [ChildId])).

%% @doc Kill the coordinator N times, waiting for each restart before the next kill.
%% Used by max_restart_intensity_test. Tolerates the supervisor dying mid-loop.
kill_coordinator_n_times(_SupPid, 0, _LastPid) -> ok;
kill_coordinator_n_times(SupPid, N, LastPid) ->
    case is_process_alive(SupPid) of
        false -> ok;  %% Supervisor already died from restart intensity
        true ->
            CoordPid = wait_child_changed(SupPid, coordinator, LastPid, 10000),
            exit(CoordPid, kill),
            kill_coordinator_n_times(SupPid, N - 1, CoordPid)
    end.
```

Add test case:

```erlang
%% @doc Kill the coordinator and verify that rest_for_one restarts
%% all children: coordinator gets a new pid, all monitors get new pids
%% bound to the new coordinator.
coordinator_crash_restarts_all_test(_Config) ->
    EngineId = <<"sup_crash_all">>,
    EngineConfig = engine_config(EngineId, [0, 1]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    wait_status(EngineId, ready, 10000),

    %% Record pids before crash
    OldCoordPid = find_child(SupPid, coordinator),
    OldMon0Pid = find_child(SupPid, {gpu_monitor, 0}),
    OldMon1Pid = find_child(SupPid, {gpu_monitor, 1}),
    ?assert(is_pid(OldCoordPid)),
    ?assert(is_pid(OldMon0Pid)),
    ?assert(is_pid(OldMon1Pid)),

    %% Kill coordinator
    exit(OldCoordPid, kill),

    %% Wait for coordinator to restart and reach ready
    wait_status(EngineId, ready, 15000),

    %% All pids should be different
    NewCoordPid = find_child(SupPid, coordinator),
    NewMon0Pid = find_child(SupPid, {gpu_monitor, 0}),
    NewMon1Pid = find_child(SupPid, {gpu_monitor, 1}),

    ?assertNotEqual(OldCoordPid, NewCoordPid),
    ?assertNotEqual(OldMon0Pid, NewMon0Pid),
    ?assertNotEqual(OldMon1Pid, NewMon1Pid),

    %% Old pids should be dead
    ?assertNot(is_process_alive(OldCoordPid)),
    ?assertNot(is_process_alive(OldMon0Pid)),
    ?assertNot(is_process_alive(OldMon1Pid)),

    %% New pids should be alive
    ?assert(is_process_alive(NewCoordPid)),
    ?assert(is_process_alive(NewMon0Pid)),
    ?assert(is_process_alive(NewMon1Pid)),

    stop_sup(SupPid).
```

- [ ] **Step 2: Run test to verify it passes**

Run: `rebar3 ct --suite=test/loom_engine_sup_SUITE --case=coordinator_crash_restarts_all_test`
Expected: PASS (rest_for_one semantics handle this).

- [ ] **Step 3: Commit**

```bash
git add test/loom_engine_sup_SUITE.erl
git commit -m "test(engine_sup): add coordinator_crash_restarts_all_test (#10)"
```

---

### Task 4: Monitor crash restarts only that monitor

**Files:**
- Modify: `test/loom_engine_sup_SUITE.erl`

- [ ] **Step 1: Write failing test**

Add to exports and `all/0`:

```erlang
monitor_crash_restarts_only_monitor_test/1
```

Add test case:

```erlang
%% @doc Kill one GPU monitor and verify only that monitor restarts.
%% Coordinator and the other monitor keep their original pids.
monitor_crash_restarts_only_monitor_test(_Config) ->
    EngineId = <<"sup_crash_mon">>,
    EngineConfig = engine_config(EngineId, [0, 1]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    wait_status(EngineId, ready, 10000),

    %% Record all pids
    OldCoordPid = find_child(SupPid, coordinator),
    OldMon0Pid = find_child(SupPid, {gpu_monitor, 0}),
    OldMon1Pid = find_child(SupPid, {gpu_monitor, 1}),

    %% Kill monitor 0 and wait for it to be replaced
    exit(OldMon0Pid, kill),
    NewMon0Pid = wait_child_changed(SupPid, {gpu_monitor, 0}, OldMon0Pid, 5000),

    %% Coordinator and monitor 1 should keep same pids
    ?assertEqual(OldCoordPid, find_child(SupPid, coordinator)),
    ?assertEqual(OldMon1Pid, find_child(SupPid, {gpu_monitor, 1})),

    %% Monitor 0 should have a new pid
    ?assertNotEqual(OldMon0Pid, NewMon0Pid),
    ?assert(is_process_alive(NewMon0Pid)),

    stop_sup(SupPid).
```

- [ ] **Step 2: Run test to verify it passes**

Run: `rebar3 ct --suite=test/loom_engine_sup_SUITE --case=monitor_crash_restarts_only_monitor_test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/loom_engine_sup_SUITE.erl
git commit -m "test(engine_sup): add monitor_crash_restarts_only_monitor_test (#10)"
```

---

### Task 5: Max restart intensity test

**Files:**
- Modify: `test/loom_engine_sup_SUITE.erl`

- [ ] **Step 1: Write failing test**

Add to exports and `all/0`:

```erlang
max_restart_intensity_test/1
```

Add test case:

```erlang
%% @doc Crash the coordinator repeatedly past the max restart intensity.
%% Verify the supervisor itself terminates.
max_restart_intensity_test(_Config) ->
    EngineId = <<"sup_max_restart">>,
    EngineConfig = (engine_config(EngineId, []))#{
        max_restarts => 2,
        max_period => 60,
        %% Use a long startup delay so the coordinator never reaches ready,
        %% making it easy to kill repeatedly during startup.
        adapter_args => [mock_adapter_path(), "--startup-delay", "30"],
        startup_timeout_ms => 60000
    },
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    SupMonRef = erlang:monitor(process, SupPid),

    %% Kill the coordinator 3 times (exceeding max_restarts=2).
    %% After the 3rd crash the supervisor should terminate.
    %% We wait for the coordinator to appear before each kill to
    %% avoid timing races.
    kill_coordinator_n_times(SupPid, 3, undefined),

    %% Supervisor should be dead
    receive
        {'DOWN', SupMonRef, process, SupPid, shutdown} -> ok;
        {'DOWN', SupMonRef, process, SupPid, _Reason} -> ok
    after 15000 ->
        ct:fail("supervisor did not terminate after exceeding max restarts")
    end.
```

- [ ] **Step 2: Run test to verify it passes**

Run: `rebar3 ct --suite=test/loom_engine_sup_SUITE --case=max_restart_intensity_test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/loom_engine_sup_SUITE.erl
git commit -m "test(engine_sup): add max_restart_intensity_test (#10)"
```

---

### Task 6: Monitor alerts reach new coordinator after restart

**Files:**
- Modify: `test/loom_engine_sup_SUITE.erl`

This validates the core design decision: after coordinator crash + restart, monitors are bound to the new coordinator pid and can send alerts to it.

- [ ] **Step 1: Write failing test**

Add to exports and `all/0`:

```erlang
monitor_alerts_after_restart_test/1
```

Add test case:

```erlang
%% @doc After coordinator crash + restart, verify monitors have the
%% new coordinator's pid and can send alerts to it.
%% We verify this by checking that the monitor's coordinator reference
%% points to the current (new) coordinator pid.
monitor_alerts_after_restart_test(_Config) ->
    EngineId = <<"sup_alert_restart">>,
    EngineConfig = engine_config(EngineId, [0]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    wait_status(EngineId, ready, 10000),

    %% Record original coordinator pid
    OldCoordPid = find_child(SupPid, coordinator),

    %% Kill coordinator to trigger rest_for_one restart
    exit(OldCoordPid, kill),
    wait_status(EngineId, ready, 15000),

    %% Get the new coordinator pid
    NewCoordPid = find_child(SupPid, coordinator),
    ?assertNotEqual(OldCoordPid, NewCoordPid),

    %% Get the new monitor pid
    NewMonPid = find_child(SupPid, {gpu_monitor, 0}),
    ?assert(is_process_alive(NewMonPid)),

    %% Force a poll on the monitor — this proves the monitor is functional
    %% after the restart. If start_monitor failed to bind the new coordinator
    %% pid, the monitor would not be alive at all (start_monitor returns
    %% {error, coordinator_not_found}).
    {ok, Metrics} = loom_gpu_monitor:force_poll(NewMonPid),
    ?assert(is_map(Metrics)),

    %% Verify the old coordinator is dead and new one is alive — combined
    %% with the monitor being alive and functional, this proves the
    %% rest_for_one restart correctly rebound the monitor to the new
    %% coordinator via start_monitor/2.
    ?assertNot(is_process_alive(OldCoordPid)),
    ?assert(is_process_alive(NewCoordPid)),
    ?assert(is_process_alive(NewMonPid)),

    stop_sup(SupPid).
```

- [ ] **Step 2: Run test — may need adjustment**

Run: `rebar3 ct --suite=test/loom_engine_sup_SUITE --case=monitor_alerts_after_restart_test`

The record field position for `coordinator_pid` in `#data{}` may need adjustment. Check `loom_gpu_monitor.erl` record definition — the `coordinator_pid` field is at position 12 (1-indexed including the record tag). If this fails, count the fields and adjust the `element(N, MonState)` call.

Expected: PASS after field position is correct.

- [ ] **Step 3: Commit**

```bash
git add test/loom_engine_sup_SUITE.erl
git commit -m "test(engine_sup): add monitor_alerts_after_restart_test (#10)

Validates core design: after coordinator crash + rest_for_one restart,
GPU monitors are bound to the new coordinator pid."
```

---

### Task 7: Run full suite, Dialyzer, and verify

**Files:**
- None new — verification only

- [ ] **Step 1: Run full CT suite**

Run: `rebar3 ct --suite=test/loom_engine_sup_SUITE`
Expected: All 7 tests pass.

- [ ] **Step 2: Run Dialyzer**

Run: `rebar3 dialyzer`
Expected: No warnings for `loom_engine_sup`.

- [ ] **Step 3: Run all project tests to check for regressions**

Run: `rebar3 ct`
Expected: All suites pass — no regressions.

- [ ] **Step 4: Final commit if any fixes were needed**

Only if steps 1-3 required code changes.
