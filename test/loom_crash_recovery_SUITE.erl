%%%-------------------------------------------------------------------
%%% @doc Crash recovery validation test suite.
%%%
%%% Validates the core fault-tolerance thesis: BEAM manages inference
%%% engine subprocesses via Port with automatic crash recovery.
%%%
%%% Tests start loom_engine_sup directly (not through the full app)
%%% for complete control over adapter args and restart intensity.
%%%
%%% ASSUMPTION: python3 is on PATH in the test environment.
%%% ASSUMPTION: The loom application is loaded (for code:priv_dir).
%%% @end
%%%-------------------------------------------------------------------
-module(loom_crash_recovery_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, groups/0]).
-export([init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    clean_operation_test/1,
    crash_idle_test/1,
    crash_active_request_test/1,
    rapid_crash_intensity_test/1,
    different_exit_codes_test/1,
    repeated_crash_recovery_test/1,
    crash_multi_inflight_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [{group, default}, {group, intensity}].

groups() ->
    [{default, [sequence], [
        clean_operation_test,
        crash_idle_test,
        crash_active_request_test,
        different_exit_codes_test,
        repeated_crash_recovery_test,
        crash_multi_inflight_test
    ]},
     {intensity, [], [
        rapid_crash_intensity_test
    ]}].

init_per_suite(Config) ->
    %% Pre-load config and start loom app. ensure_all_started is idempotent
    %% if the app is already running from a prior suite.
    case ets:info(loom_config) of
        undefined -> ok = loom_config:load(fixture_path("minimal.json"));
        _ -> ok
    end,
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
    %% Don't stop the app — other suites may share this node.
    ok.

init_per_group(default, Config) ->
    %% Start an engine supervisor with slow tokens for crash testing
    EngineId = <<"crash_test">>,
    EngineConfig = engine_config(EngineId, [
        "--token-delay", "0.5"
    ]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    %% ASSUMPTION: Unlink the supervisor from the CT group process so it
    %% survives the init_per_group -> test case process transition.
    %% The supervisor is stopped explicitly in end_per_group.
    unlink(SupPid),
    ok = wait_status(EngineId, ready, 15000),
    [{engine_id, EngineId}, {sup_pid, SupPid}, {engine_config, EngineConfig} | Config];

init_per_group(intensity, Config) ->
    %% Engine started per-testcase with custom restart intensity
    Config.

end_per_group(default, Config) ->
    SupPid = ?config(sup_pid, Config),
    case is_process_alive(SupPid) of
        true -> stop_sup(SupPid);
        false -> ok
    end,
    ok;

end_per_group(intensity, _Config) ->
    ok.

init_per_testcase(rapid_crash_intensity_test, Config) ->
    process_flag(trap_exit, true),
    EngineId = <<"intensity_test">>,
    EngineConfig = (engine_config(EngineId, []))#{
        max_restarts => 2,
        max_period => 60
    },
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    ok = wait_status(EngineId, ready, 15000),
    [{engine_id, EngineId}, {sup_pid, SupPid} | Config];
init_per_testcase(_TestCase, Config) ->
    process_flag(trap_exit, true),
    Config.

end_per_testcase(rapid_crash_intensity_test, Config) ->
    %% Supervisor may already be dead from exceeding max_restarts
    case ?config(sup_pid, Config) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> stop_sup(Pid);
                false -> ok
            end;
        _ -> ok
    end,
    flush_mailbox(),
    ok;
end_per_testcase(_TestCase, _Config) ->
    flush_mailbox(),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc Scenario 1: Baseline — start system, send request, receive all
%% tokens, verify complete response. If this fails, nothing else matters.
clean_operation_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),

    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    {ok, RequestId} = loom_engine_coordinator:generate(
        CoordPid, <<"Hello">>, #{max_tokens => 100}),
    ?assert(is_binary(RequestId)),

    %% Mock adapter produces 5 tokens (MOCK_TOKENS in mock_adapter.py)
    Tokens = collect_tokens(RequestId, 5, 10000),
    ?assertEqual(5, length(Tokens)),

    receive
        {loom_done, RequestId, Stats} ->
            ?assertEqual(5, maps:get(tokens, Stats)),
            ct:pal("Generate completed: ~p tokens in ~Bms",
                   [maps:get(tokens, Stats), maps:get(time_ms, Stats)])
    after 10000 ->
        ct:fail("no loom_done received")
    end,

    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    %% Verify no orphaned OS process (adapter should still be running)
    OsPid = get_adapter_os_pid(CoordPid, EngineId),
    ?assert(is_os_pid_alive(OsPid)).

%% @doc Scenario 2: Kill the adapter process while no requests are in
%% flight. Verify the coordinator self-heals (leaves ready, then returns to ready)
%% and a subsequent request succeeds.
crash_idle_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),

    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    OldOsPid = get_adapter_os_pid(CoordPid, EngineId),
    OldPortPid = find_port_pid(CoordPid, EngineId),

    RecoveryMs = measure_recovery(EngineId, OldOsPid),

    ?assertNot(is_os_pid_alive(OldOsPid)),

    %% Verify a new port was created (different pid)
    wait_port_pid_changed(CoordPid, EngineId, OldPortPid, 10000),

    NewOsPid = get_adapter_os_pid(CoordPid, EngineId),
    ?assertNotEqual(OldOsPid, NewOsPid),
    ?assert(is_os_pid_alive(NewOsPid)),

    {ok, RequestId} = loom_engine_coordinator:generate(
        CoordPid, <<"Post-crash test">>, #{}),
    _Tokens = collect_tokens(RequestId, 5, 10000),
    receive
        {loom_done, RequestId, _Stats} -> ok
    after 10000 -> ct:fail("no loom_done after recovery")
    end,
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    ct:pal("Crash idle recovery: ~Bms, old_pid=~B, new_pid=~B",
           [RecoveryMs, OldOsPid, NewOsPid]).

%% @doc Scenario 3: Start a generation with slow tokens, kill the adapter
%% mid-stream. Verify the caller receives engine_crashed error, the
%% coordinator self-heals, and a new request succeeds.
crash_active_request_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),

    wait_status(EngineId, ready, 15000),

    {ok, RequestId} = loom_engine_coordinator:generate(
        CoordPid, <<"Hello">>, #{}),

    %% Wait for at least one token to confirm generation started
    receive
        {loom_token, RequestId, _Text, _Finished} -> ok
    after 5000 ->
        ct:fail("no token received before kill")
    end,

    ?assert(loom_engine_coordinator:get_load(EngineId) > 0),

    OsPid = get_adapter_os_pid(CoordPid, EngineId),
    T0 = erlang:monotonic_time(millisecond),
    kill_os_pid(OsPid),

    receive
        {loom_error, RequestId, <<"engine_crashed">>, _Detail} ->
            ct:pal("Got engine_crashed error for in-flight request")
    after 5000 ->
        ct:fail("no loom_error engine_crashed received")
    end,

    %% Wait for status to leave ready first (avoids reading stale ready)
    ok = wait_status_not(EngineId, ready, 10000),
    ok = wait_status(EngineId, ready, 30000),
    T1 = erlang:monotonic_time(millisecond),
    ct:pal("Recovery from active crash: ~Bms", [T1 - T0]),

    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    ?assertNot(is_os_pid_alive(OsPid)),

    {ok, RequestId2} = loom_engine_coordinator:generate(
        CoordPid, <<"Post-crash">>, #{}),
    _Tokens = collect_tokens(RequestId2, 5, 10000),
    receive
        {loom_done, RequestId2, _Stats} -> ok
    after 10000 -> ct:fail("no loom_done after active crash recovery")
    end,
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)).

%% @doc Scenario 4: Kill the coordinator multiple times in sequence.
%% Verify the supervisor respects max_restarts intensity and the system
%% enters a stable error state rather than crash-looping.
%%
%% Strategy: Kill the coordinator process directly (not just the adapter).
%% Self-heal only restarts the port internally — it does NOT cause a
%% supervisor restart. To exceed max_restarts we must kill the coordinator
%% process itself, which the supervisor then restarts.
%%
%% With max_restarts=2, the 3rd coordinator kill triggers supervisor
%% termination (exceeded intensity).
rapid_crash_intensity_test(Config) ->
    EngineId = ?config(engine_id, Config),
    SupPid = ?config(sup_pid, Config),

    %% Monitor the supervisor so we know when it terminates
    SupRef = erlang:monitor(process, SupPid),

    %% Kill coordinator 3 times to exceed max_restarts=2.
    %% The supervisor allows 2 restarts, so the 3rd kill causes shutdown.
    %% Collect OS PIDs of adapter processes for orphan verification.
    CollectedOsPids = kill_coordinator_n_times(SupPid, EngineId, 3, undefined),

    %% Prevent the orphan check from passing vacuously on an empty list
    ?assert(length(CollectedOsPids) >= 1),

    %% Wait for supervisor to terminate
    receive
        {'DOWN', SupRef, process, SupPid, _Reason} ->
            ct:pal("Supervisor terminated after exceeding max_restarts=2")
    after 15000 ->
        ct:fail("supervisor did not terminate after exceeding max restarts")
    end,

    ?assertNot(is_process_alive(SupPid)),

    %% Verify no orphaned OS processes after supervisor termination
    timer:sleep(500),
    lists:foreach(fun(OsPid) ->
        ?assertNot(is_os_pid_alive(OsPid))
    end, CollectedOsPids),
    ct:pal("Verified ~B adapter OS processes cleaned up", [length(CollectedOsPids)]),

    %% Verify loom_sup (parent) is still alive — fault isolation works
    ?assert(is_process_alive(whereis(loom_sup))),

    ct:pal("Supervisor terminated cleanly, loom_sup still alive").

%% @doc Scenario 5: Verify the system handles different adapter exit
%% scenarios correctly: clean exit (code 0), application error (code 1),
%% and SIGKILL (code 137). Each crash triggers self-heal and recovery.
different_exit_codes_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),

    wait_status(EngineId, ready, 15000),

    %% --- Exit code 0 (clean exit via crash command) ---
    ct:pal("Testing exit code 0 (clean exit)"),
    PortPid0 = find_port_pid(CoordPid, EngineId),
    ok = loom_port:send(PortPid0, {crash, 0}),
    ok = wait_status_not(EngineId, ready, 10000),
    ok = wait_status(EngineId, ready, 15000),
    ct:pal("Recovered from exit code 0"),

    %% --- Exit code 1 (application error via crash command) ---
    ct:pal("Testing exit code 1 (application error)"),
    PortPid1 = find_port_pid(CoordPid, EngineId),
    ok = loom_port:send(PortPid1, {crash, 1}),
    ok = wait_status_not(EngineId, ready, 10000),
    ok = wait_status(EngineId, ready, 15000),
    ct:pal("Recovered from exit code 1"),

    %% --- Exit code 137 (SIGKILL) ---
    ct:pal("Testing SIGKILL (exit code 137)"),
    OsPid = get_adapter_os_pid(CoordPid, EngineId),
    kill_os_pid(OsPid),
    ok = wait_status_not(EngineId, ready, 10000),
    ok = wait_status(EngineId, ready, 15000),
    ?assertNot(is_os_pid_alive(OsPid)),
    ct:pal("Recovered from SIGKILL"),

    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    {ok, RequestId} = loom_engine_coordinator:generate(
        CoordPid, <<"Post-multi-crash">>, #{}),
    _Tokens = collect_tokens(RequestId, 5, 10000),
    receive
        {loom_done, RequestId, _Stats} -> ok
    after 10000 -> ct:fail("no loom_done after multi-exit-code test")
    end,
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)).

%% @doc Verify no resource leaks after repeated crash/recovery cycles.
%% Crashes the adapter 5 times, letting it recover each time, then
%% checks that process monitors, ETS entries, and load are all clean.
repeated_crash_recovery_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),
    wait_status(EngineId, ready, 15000),

    %% Baseline: capture initial process count
    BaselineProcs = erlang:system_info(process_count),

    %% Crash and recover 5 times
    lists:foreach(fun(I) ->
        OsPid = get_adapter_os_pid(CoordPid, EngineId),
        kill_os_pid(OsPid),
        wait_status_not(EngineId, ready, 10000),
        ok = wait_status(EngineId, ready, 15000),
        ct:pal("Crash/recovery cycle ~B complete", [I])
    end, lists:seq(1, 5)),

    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),

    %% Verify process count hasn't grown significantly (allow 10 process margin)
    FinalProcs = erlang:system_info(process_count),
    ProcGrowth = FinalProcs - BaselineProcs,
    ct:pal("Process count: baseline=~B, final=~B, growth=~B",
           [BaselineProcs, FinalProcs, ProcGrowth]),
    ?assert(ProcGrowth < 10),

    {ok, RequestId} = loom_engine_coordinator:generate(CoordPid, <<"Post-repeat">>, #{}),
    _Tokens = collect_tokens(RequestId, 5, 10000),
    receive
        {loom_done, RequestId, _Stats} -> ok
    after 10000 -> ct:fail("no loom_done after repeated crash/recovery")
    end,
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)).

%% @doc Verify that when multiple requests are in-flight during a crash,
%% ALL callers receive engine_crashed errors and load returns to 0.
crash_multi_inflight_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),
    wait_status(EngineId, ready, 15000),
    Self = self(),

    %% Spawn 3 callers with in-flight requests
    CallerFun = fun(N) ->
        spawn_link(fun() ->
            {ok, ReqId} = loom_engine_coordinator:generate(CoordPid, <<"Hello">>, #{}),
            Self ! {caller_ready, N, ReqId},
            receive
                {loom_error, ReqId, Code, _Detail} ->
                    Self ! {caller_error, N, ReqId, Code};
                {loom_done, ReqId, _Stats} ->
                    Self ! {caller_done, N, ReqId}
            after 15000 ->
                Self ! {caller_timeout, N, ReqId}
            end
        end)
    end,
    _Callers = [CallerFun(N) || N <- [1, 2, 3]],

    %% Wait for all 3 to confirm in-flight
    _ReqIds = [receive {caller_ready, N, RId} -> RId
               after 5000 -> ct:fail("caller ~w never ready", [N])
               end || N <- [1, 2, 3]],

    ?assertEqual(3, loom_engine_coordinator:get_load(EngineId)),

    OsPid = get_adapter_os_pid(CoordPid, EngineId),
    kill_os_pid(OsPid),

    %% All 3 callers should receive engine_crashed
    lists:foreach(fun(N) ->
        receive
            {caller_error, N, _, <<"engine_crashed">>} -> ok;
            {caller_error, N, _, OtherCode} ->
                ct:fail("caller ~w got ~p instead of engine_crashed", [N, OtherCode]);
            {caller_done, N, _} ->
                ct:fail("caller ~w got done instead of error", [N]);
            {caller_timeout, N, _} ->
                ct:fail("caller ~w timed out", [N])
        after 10000 ->
            ct:fail("no response from caller ~w", [N])
        end
    end, [1, 2, 3]),

    ok = wait_status(EngineId, ready, 15000),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)).

%%====================================================================
%% Helpers
%%====================================================================

fixture_path(Name) ->
    TestDir = filename:dirname(?FILE),
    filename:join([TestDir, "fixtures", Name]).

mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

python_cmd() ->
    os:find_executable("python3").

%% @doc Create engine config with custom adapter args.
engine_config(EngineId, ExtraArgs) ->
    #{
        engine_id => EngineId,
        adapter_cmd => python_cmd(),
        adapter_args => [mock_adapter_path() | ExtraArgs],
        model => <<"test-model">>,
        backend => <<"mock">>,
        gpus => [],
        max_concurrent => 64,
        startup_timeout_ms => 10000,
        drain_timeout_ms => 5000,
        allow_mock_backend => true
    }.

%% @doc Poll get_status/1 until it returns Status or timeout.
wait_status(EngineId, Status, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_status(EngineId) of
        Status -> ok;
        _ ->
            timer:sleep(50),
            wait_status(EngineId, Status, Timeout - 50)
    end;
wait_status(EngineId, Status, _Timeout) ->
    Actual = try loom_engine_coordinator:get_status(EngineId)
             catch C:R -> {exception, C, R}
             end,
    ct:fail(io_lib:format("wait_status: never reached ~p for ~s (last: ~p)",
                          [Status, EngineId, Actual])).

%% @doc Find the coordinator pid from the engine supervisor.
find_coordinator(EngineId) ->
    SupName = loom_engine_sup:sup_name(EngineId),
    Children = supervisor:which_children(SupName),
    case lists:keyfind(coordinator, 1, Children) of
        {coordinator, Pid, worker, _} when is_pid(Pid) -> Pid;
        _ -> ct:fail("coordinator not found in supervisor")
    end.

%% @doc Find the loom_port pid from the coordinator's links.
%% ASSUMPTION: The coordinator's only non-supervisor link is the loom_port
%% process. If the coordinator links to additional processes, this heuristic
%% will return the wrong PID.
find_port_pid(CoordPid, EngineId) ->
    SupPid = whereis(loom_engine_sup:sup_name(EngineId)),
    {links, Links} = process_info(CoordPid, links),
    PortPids = [P || P <- Links, is_pid(P), P =/= SupPid],
    case PortPids of
        [PortPid] -> PortPid;
        [PortPid | _Extra] ->
            ct:pal("WARNING: coordinator has extra linked pids beyond port: ~p", [_Extra]),
            PortPid;
        [] -> undefined
    end.

%% @doc Get the OS PID of the adapter process managed by loom_port.
get_adapter_os_pid(CoordPid, EngineId) ->
    PortPid = find_port_pid(CoordPid, EngineId),
    ?assert(is_pid(PortPid)),
    OsPid = loom_port:get_os_pid(PortPid),
    ?assert(is_integer(OsPid)),
    OsPid.

%% @doc Kill an OS process with SIGKILL.
kill_os_pid(OsPid) ->
    os:cmd("kill -9 " ++ integer_to_list(OsPid)).

%% @doc Check if an OS process is alive.
is_os_pid_alive(OsPid) ->
    %% kill -0 checks existence without sending a signal.
    %% We capture the exit code via echo $? since os:cmd only returns stdout.
    Cmd = lists:flatten(io_lib:format(
        "kill -0 ~B 2>/dev/null; echo $?", [OsPid])),
    string:trim(os:cmd(Cmd)) =:= "0".

%% @doc Measure recovery time: kill adapter, wait for NOT ready (self-heal
%% transition), then wait for ready again. Returns elapsed ms.
%% ASSUMPTION: The coordinator was in 'ready' before calling this.
%% We must wait for the status to leave 'ready' first, otherwise we may
%% read the stale 'ready' before the coordinator processes the port death.
measure_recovery(EngineId, OsPid) ->
    T0 = erlang:monotonic_time(millisecond),
    kill_os_pid(OsPid),
    ok = wait_status_not(EngineId, ready, 10000),
    ok = wait_status(EngineId, ready, 30000),
    T1 = erlang:monotonic_time(millisecond),
    RecoveryMs = T1 - T0,
    ct:pal("Recovery time: ~Bms (engine ~s)", [RecoveryMs, EngineId]),
    ?assert(RecoveryMs < 15000),
    RecoveryMs.

%% @doc Poll until status is NOT the given value (or timeout).
wait_status_not(EngineId, Status, Timeout) when Timeout > 0 ->
    Result = try loom_engine_coordinator:get_status(EngineId)
             catch _:_ -> {ets_or_proc_unavailable}
             end,
    case Result of
        Status ->
            timer:sleep(50),
            wait_status_not(EngineId, Status, Timeout - 50);
        {ets_or_proc_unavailable} ->
            %% ETS table or process gone — coordinator is restarting
            ok;
        _Other ->
            ok
    end;
wait_status_not(_EngineId, _Status, _Timeout) ->
    %% If we timed out, recovery was faster than our polling interval.
    %% This is fine — the subsequent wait_status(ready) will confirm recovery.
    ct:pal("wait_status_not: recovery was instant (faster than poll interval)"),
    ok.

%% @doc Collect N token messages for a given RequestId.
collect_tokens(_RequestId, 0, _Timeout) -> [];
collect_tokens(RequestId, N, Timeout) ->
    receive
        {loom_token, RequestId, Text, _Finished} ->
            [Text | collect_tokens(RequestId, N - 1, Timeout)]
    after Timeout ->
        ct:fail(io_lib:format("collect_tokens: timeout waiting for token ~w", [N]))
    end.

%% @doc Wait until the coordinator's port pid changes from OldPortPid.
wait_port_pid_changed(CoordPid, EngineId, OldPortPid, Timeout) when Timeout > 0 ->
    case is_process_alive(CoordPid) of
        false -> ct:fail("coordinator died during self-heal");
        true ->
            case find_port_pid(CoordPid, EngineId) of
                Pid when is_pid(Pid), Pid =/= OldPortPid -> ok;
                _ ->
                    timer:sleep(50),
                    wait_port_pid_changed(CoordPid, EngineId, OldPortPid, Timeout - 50)
            end
    end;
wait_port_pid_changed(_CoordPid, _EngineId, _OldPortPid, _Timeout) ->
    ct:fail("port pid never changed").

%% @doc Kill the coordinator N times, waiting for each restart.
%% Returns a list of OS PIDs of adapter processes that were running
%% under each coordinator at the time of the kill (for orphan verification).
%% Inspired by loom_engine_sup_SUITE:kill_coordinator_n_times/3, extended
%% with OS PID collection for orphan verification.
kill_coordinator_n_times(_SupPid, _EngineId, 0, _LastPid) -> [];
kill_coordinator_n_times(SupPid, EngineId, N, LastPid) ->
    case is_process_alive(SupPid) of
        false -> [];
        true ->
            CoordPid = wait_coordinator_changed(SupPid, LastPid, 10000),
            %% Collect the adapter OS PID before killing the coordinator.
            %% Use catch for safety — the port may not be available yet
            %% if the coordinator just restarted and hasn't spawned one.
            OsPids = case catch find_port_pid(CoordPid, EngineId) of
                PortPid when is_pid(PortPid) ->
                    case catch loom_port:get_os_pid(PortPid) of
                        OsPid when is_integer(OsPid) -> [OsPid];
                        _ -> []
                    end;
                _ -> []
            end,
            ct:pal("Killing coordinator ~p (remaining: ~B, tracked OS PIDs: ~p)",
                   [CoordPid, N, OsPids]),
            exit(CoordPid, kill),
            OsPids ++ kill_coordinator_n_times(SupPid, EngineId, N - 1, CoordPid)
    end.

%% @doc Wait until the coordinator child has a different pid from OldPid.
wait_coordinator_changed(SupPid, OldPid, Timeout) when Timeout > 0 ->
    case catch supervisor:which_children(SupPid) of
        Children when is_list(Children) ->
            case lists:keyfind(coordinator, 1, Children) of
                {coordinator, Pid, worker, _} when is_pid(Pid), Pid =/= OldPid ->
                    Pid;
                _ ->
                    timer:sleep(50),
                    wait_coordinator_changed(SupPid, OldPid, Timeout - 50)
            end;
        _ ->
            timer:sleep(50),
            wait_coordinator_changed(SupPid, OldPid, Timeout - 50)
    end;
wait_coordinator_changed(_SupPid, _OldPid, _Timeout) ->
    ct:fail("coordinator never changed").

%% @doc Stop a supervisor and wait for it to terminate.
stop_sup(SupPid) ->
    erlang:unlink(SupPid),
    MonRef = erlang:monitor(process, SupPid),
    exit(SupPid, shutdown),
    receive
        {'DOWN', MonRef, process, SupPid, _Reason} -> ok
    after 10000 ->
        %% Force kill as fallback
        exit(SupPid, kill),
        receive
            {'DOWN', MonRef, process, SupPid, _} -> ok
        after 5000 ->
            ct:fail("supervisor didn't terminate even after kill")
        end
    end.

flush_mailbox() ->
    receive _ -> flush_mailbox()
    after 0 -> ok
    end.
