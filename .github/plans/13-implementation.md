# Crash Recovery Validation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Validate Loom's core fault-tolerance thesis with comprehensive crash recovery tests covering 6 scenarios across two test suites.

**Architecture:** Two `common_test` suites — `loom_crash_recovery_SUITE` (engine-level, scenarios 1-5) and `loom_http_disconnect_SUITE` (HTTP-level, scenario 6). Engine tests start `loom_engine_sup` directly for full control over adapter args. HTTP test starts the full application. A small mock adapter enhancement adds a `crash` command for controlled exit codes.

**Tech Stack:** Erlang/OTP common_test, gen_statem, supervisor, gen_tcp (HTTP client), Python mock adapter

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `priv/scripts/mock_adapter.py` | Modify | Add `crash` command handler |
| `src/loom_protocol.erl` | Modify | Add `crash` outbound message encode |
| `test/loom_crash_recovery_SUITE.erl` | Create | Engine crash recovery tests (scenarios 1-5) |
| `test/loom_http_disconnect_SUITE.erl` | Create | HTTP client disconnect test (scenario 6) |

---

### Task 1: Add crash command to mock adapter and protocol

**Files:**
- Modify: `priv/scripts/mock_adapter.py` (lines 94-110)
- Modify: `src/loom_protocol.erl` (lines 30-35, 58-73)

- [ ] **Step 1: Add crash handler to mock_adapter.py**

Add the handler function before the `HANDLERS` dict (after `handle_shutdown` at line 100):

```python
def handle_crash(msg):
    """Force-exit with a specific exit code (for crash recovery testing)."""
    exit_code = msg.get("exit_code", 1)
    print(f"[mock_adapter] crash requested, exit_code={exit_code}", file=sys.stderr)
    sys.stderr.flush()
    os._exit(exit_code)
```

Add `"crash"` to the `HANDLERS` dict (line 104-110):

```python
HANDLERS = {
    "health": handle_health,
    "memory": handle_memory,
    "generate": handle_generate,
    "cancel": handle_cancel,
    "shutdown": handle_shutdown,
    "crash": handle_crash,
}
```

- [ ] **Step 2: Add crash outbound message type to loom_protocol.erl**

Add `{crash, ExitCode :: non_neg_integer()}` to the `outbound_msg()` type (line 30-35):

```erlang
-type outbound_msg() ::
    {generate, Id :: binary(), Prompt :: binary(), Params :: generate_params()}
  | {health}
  | {memory}
  | {cancel, Id :: binary()}
  | {shutdown}
  | {crash, ExitCode :: non_neg_integer()}.
```

Add the encode clause after the `generate` encode (line 67-73):

```erlang
encode({crash, ExitCode}) ->
    terminate_line(loom_json:encode(#{type => crash, exit_code => ExitCode}));
```

- [ ] **Step 3: Verify crash command works**

Run: `echo '{"type":"crash","exit_code":42}' | python3 priv/scripts/mock_adapter.py; echo "Exit: $?"`

Expected: Adapter starts, sends heartbeat + ready, receives crash command, exits with code 42. Output ends with `Exit: 42`.

- [ ] **Step 4: Run existing tests to verify no regression**

Run: `rebar3 ct --suite=test/loom_protocol_SUITE`

Expected: All existing protocol tests pass.

- [ ] **Step 5: Commit**

```bash
git add priv/scripts/mock_adapter.py src/loom_protocol.erl
git commit -m "feat(test): add crash command to mock adapter and protocol

Adds a {crash, ExitCode} outbound message type that causes the mock
adapter to os._exit() with the specified code. Used by crash recovery
tests to produce controlled exit codes.

Refs #13"
```

---

### Task 2: Create loom_crash_recovery_SUITE scaffold and helpers

**Files:**
- Create: `test/loom_crash_recovery_SUITE.erl`

- [ ] **Step 1: Create the SUITE file with module declaration, exports, and helpers**

```erlang
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
    different_exit_codes_test/1
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
        different_exit_codes_test
    ]},
     {intensity, [], [
        rapid_crash_intensity_test
    ]}].

init_per_suite(Config) ->
    ok = application:load(loom),
    %% Pre-load a minimal config so the loom app can start its HTTP server.
    %% We don't rely on app-started engines — we start supervisors directly.
    ok = loom_config:load(fixture_path("minimal.json")),
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
    application:stop(loom),
    loom_test_helpers:cleanup_ets(),
    ok.

init_per_group(default, Config) ->
    %% Start an engine supervisor with slow tokens for crash testing
    EngineId = <<"crash_test">>,
    EngineConfig = engine_config(EngineId, [
        "--token-delay", "0.5"
    ]),
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    ok = wait_status(EngineId, ready, 15000),
    [{engine_id, EngineId}, {sup_pid, SupPid}, {engine_config, EngineConfig} | Config];

init_per_group(intensity, Config) ->
    %% Engine started per-testcase with custom restart intensity
    Config.

end_per_group(default, Config) ->
    SupPid = ?config(sup_pid, Config),
    stop_sup(SupPid),
    ok;

end_per_group(intensity, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_TestCase, _Config) ->
    flush_mailbox(),
    ok.

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
wait_status(_EngineId, Status, _Timeout) ->
    ct:fail(io_lib:format("wait_status: never reached ~p", [Status])).

%% @doc Wait for load to become 0 or timeout.
wait_load_zero(EngineId, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_load(EngineId) of
        0 -> ok;
        _ ->
            timer:sleep(50),
            wait_load_zero(EngineId, Timeout - 50)
    end;
wait_load_zero(_EngineId, _Timeout) ->
    ct:fail("wait_load_zero: load never reached 0").

%% @doc Wait for load to become > 0 or timeout.
wait_load_nonzero(EngineId, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_load(EngineId) of
        N when is_integer(N), N > 0 -> ok;
        _ ->
            timer:sleep(50),
            wait_load_nonzero(EngineId, Timeout - 50)
    end;
wait_load_nonzero(_EngineId, _Timeout) ->
    ct:fail("wait_load_nonzero: load never became > 0").

%% @doc Find the coordinator pid from the engine supervisor.
find_coordinator(EngineId) ->
    SupName = loom_engine_sup:sup_name(EngineId),
    Children = supervisor:which_children(SupName),
    case lists:keyfind(coordinator, 1, Children) of
        {coordinator, Pid, worker, _} when is_pid(Pid) -> Pid;
        _ -> ct:fail("coordinator not found in supervisor")
    end.

%% @doc Find the loom_port pid from the coordinator's links.
find_port_pid(CoordPid, EngineId) ->
    SupPid = whereis(loom_engine_sup:sup_name(EngineId)),
    {links, Links} = process_info(CoordPid, links),
    PortPids = [P || P <- Links, is_pid(P), P =/= SupPid],
    case PortPids of
        [PortPid | _] -> PortPid;
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

%% @doc Measure recovery time: kill adapter, wait for ready, return ms.
measure_recovery(EngineId, OsPid) ->
    T0 = erlang:monotonic_time(millisecond),
    kill_os_pid(OsPid),
    ok = wait_status(EngineId, ready, 30000),
    T1 = erlang:monotonic_time(millisecond),
    RecoveryMs = T1 - T0,
    ct:pal("Recovery time: ~Bms (engine ~s)", [RecoveryMs, EngineId]),
    RecoveryMs.

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

%% @doc Stop a supervisor and wait for it to terminate.
stop_sup(SupPid) ->
    MonRef = erlang:monitor(process, SupPid),
    exit(SupPid, shutdown),
    receive
        {'DOWN', MonRef, process, SupPid, _Reason} -> ok
    after 10000 ->
        ct:fail("supervisor didn't terminate")
    end.

flush_mailbox() ->
    receive _ -> flush_mailbox()
    after 0 -> ok
    end.

drain_messages(Timeout) ->
    receive _ -> drain_messages(Timeout)
    after Timeout -> ok
    end.
```

- [ ] **Step 2: Verify the scaffold compiles**

Run: `rebar3 compile`

Expected: Compiles with no errors (tests have empty function bodies at this point — we add them in subsequent tasks).

Note: The `all/0` references test functions that don't exist yet. That's OK — we'll add them one at a time. If the compiler warns about unused exports, that's expected until all test cases are implemented.

- [ ] **Step 3: Commit scaffold**

```bash
git add test/loom_crash_recovery_SUITE.erl
git commit -m "feat(test): add crash recovery SUITE scaffold and helpers

Scaffolds the common_test suite with helper functions for OS-level
process management, recovery time measurement, and coordinator/port
discovery through the supervisor tree.

Refs #13"
```

---

### Task 3: Implement clean_operation_test (Scenario 1)

**Files:**
- Modify: `test/loom_crash_recovery_SUITE.erl`

- [ ] **Step 1: Add the test function**

```erlang
%% @doc Scenario 1: Baseline — start system, send request, receive all
%% tokens, verify complete response. If this fails, nothing else matters.
clean_operation_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),

    %% Verify engine is ready
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    %% Send generate request
    {ok, RequestId} = loom_engine_coordinator:generate(
        CoordPid, <<"Hello">>, #{max_tokens => 100}),
    ?assert(is_binary(RequestId)),

    %% Collect all 5 tokens from mock adapter
    Tokens = collect_tokens(RequestId, 5, 10000),
    ?assertEqual(5, length(Tokens)),

    %% Receive done message
    receive
        {loom_done, RequestId, Stats} ->
            ?assertEqual(5, maps:get(tokens, Stats)),
            ct:pal("Generate completed: ~p tokens in ~Bms",
                   [maps:get(tokens, Stats), maps:get(time_ms, Stats)])
    after 10000 ->
        ct:fail("no loom_done received")
    end,

    %% Verify load returns to 0
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    %% Verify no orphaned OS process (adapter should still be running)
    OsPid = get_adapter_os_pid(CoordPid, EngineId),
    ?assert(is_os_pid_alive(OsPid)).
```

- [ ] **Step 2: Run test**

Run: `rebar3 ct --suite=test/loom_crash_recovery_SUITE --case=clean_operation_test`

Expected: PASS. This validates the baseline — the engine works correctly.

- [ ] **Step 3: Commit**

```bash
git add test/loom_crash_recovery_SUITE.erl
git commit -m "test: add clean_operation_test (scenario 1)

Baseline test: start system, send request, receive all tokens, verify
complete response. Validates the mock adapter + coordinator path works
before running crash scenarios.

Refs #13"
```

---

### Task 4: Implement crash_idle_test (Scenario 2)

**Files:**
- Modify: `test/loom_crash_recovery_SUITE.erl`

- [ ] **Step 1: Add the test function**

```erlang
%% @doc Scenario 2: Kill the adapter process while no requests are in
%% flight. Verify the coordinator self-heals (ready -> starting -> ready)
%% and a subsequent request succeeds.
crash_idle_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),

    %% Verify engine is ready and idle
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    %% Get the adapter OS PID
    OldOsPid = get_adapter_os_pid(CoordPid, EngineId),
    OldPortPid = find_port_pid(CoordPid, EngineId),

    %% Kill the adapter with SIGKILL
    RecoveryMs = measure_recovery(EngineId, OldOsPid),

    %% Verify old OS process is gone
    ?assertNot(is_os_pid_alive(OldOsPid)),

    %% Verify a new port was created (different pid)
    wait_port_pid_changed(CoordPid, EngineId, OldPortPid, 10000),

    %% Verify new adapter has a different OS PID
    NewOsPid = get_adapter_os_pid(CoordPid, EngineId),
    ?assertNotEqual(OldOsPid, NewOsPid),
    ?assert(is_os_pid_alive(NewOsPid)),

    %% Verify a new request succeeds end-to-end
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
```

- [ ] **Step 2: Run test**

Run: `rebar3 ct --suite=test/loom_crash_recovery_SUITE --case=crash_idle_test`

Expected: PASS. Recovery time logged (typically 500-2000ms with mock adapter).

- [ ] **Step 3: Commit**

```bash
git add test/loom_crash_recovery_SUITE.erl
git commit -m "test: add crash_idle_test (scenario 2)

Kill adapter via SIGKILL during idle, verify self-heal to ready,
measure recovery time, confirm no orphaned OS processes, and validate
subsequent request succeeds.

Refs #13"
```

---

### Task 5: Implement crash_active_request_test (Scenario 3)

**Files:**
- Modify: `test/loom_crash_recovery_SUITE.erl`

- [ ] **Step 1: Add the test function**

```erlang
%% @doc Scenario 3: Start a generation with slow tokens, kill the adapter
%% mid-stream. Verify the caller receives engine_crashed error, the
%% coordinator self-heals, and a new request succeeds.
crash_active_request_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),

    %% Wait for engine to be ready (may have just recovered from prior test)
    wait_status(EngineId, ready, 15000),

    %% Start a slow generate request (0.5s per token)
    {ok, RequestId} = loom_engine_coordinator:generate(
        CoordPid, <<"Hello">>, #{}),

    %% Wait for at least one token to confirm generation started
    receive
        {loom_token, RequestId, _Text, _Finished} -> ok
    after 5000 ->
        ct:fail("no token received before kill")
    end,

    %% Verify request is in-flight
    ?assert(loom_engine_coordinator:get_load(EngineId) > 0),

    %% Kill the adapter with SIGKILL
    OsPid = get_adapter_os_pid(CoordPid, EngineId),
    T0 = erlang:monotonic_time(millisecond),
    kill_os_pid(OsPid),

    %% Verify caller receives engine_crashed error
    receive
        {loom_error, RequestId, <<"engine_crashed">>, _Detail} ->
            ct:pal("Got engine_crashed error for in-flight request")
    after 5000 ->
        ct:fail("no loom_error engine_crashed received")
    end,

    %% Verify self-heal: coordinator returns to ready
    ok = wait_status(EngineId, ready, 30000),
    T1 = erlang:monotonic_time(millisecond),
    ct:pal("Recovery from active crash: ~Bms", [T1 - T0]),

    %% Verify load is back to 0
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    %% Verify old adapter process is gone
    ?assertNot(is_os_pid_alive(OsPid)),

    %% Verify a new request succeeds after recovery
    {ok, RequestId2} = loom_engine_coordinator:generate(
        CoordPid, <<"Post-crash">>, #{}),
    _Tokens = collect_tokens(RequestId2, 5, 10000),
    receive
        {loom_done, RequestId2, _Stats} -> ok
    after 10000 -> ct:fail("no loom_done after active crash recovery")
    end,
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)).
```

- [ ] **Step 2: Run test**

Run: `rebar3 ct --suite=test/loom_crash_recovery_SUITE --case=crash_active_request_test`

Expected: PASS. Caller receives `{loom_error, _, <<"engine_crashed">>, _}` within 5s.

- [ ] **Step 3: Commit**

```bash
git add test/loom_crash_recovery_SUITE.erl
git commit -m "test: add crash_active_request_test (scenario 3)

Kill adapter mid-stream via SIGKILL, verify caller receives
engine_crashed error, coordinator self-heals, and next request
succeeds end-to-end.

Refs #13"
```

---

### Task 6: Implement rapid_crash_intensity_test (Scenario 4)

**Files:**
- Modify: `test/loom_crash_recovery_SUITE.erl`

This test uses the `intensity` group with a per-testcase engine supervisor configured with low restart intensity.

- [ ] **Step 1: Update init_per_group and end_per_group for intensity group**

The intensity group starts/stops the engine per testcase since it needs custom restart limits. Update `init_per_testcase` and `end_per_testcase`:

```erlang
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
```

- [ ] **Step 2: Add the test function**

```erlang
%% @doc Scenario 4: Kill the engine multiple times in quick succession.
%% Verify the supervisor respects max_restarts intensity and the system
%% enters a stable error state rather than crash-looping.
%%
%% Strategy: Kill adapter -> coordinator self-heals (ready -> starting).
%% Kill the new adapter while in starting -> coordinator goes to stopped.
%% Supervisor restarts coordinator. Repeat until max_restarts exceeded.
%%
%% With max_restarts=2, the 3rd supervisor restart triggers termination.
rapid_crash_intensity_test(Config) ->
    EngineId = ?config(engine_id, Config),
    SupPid = ?config(sup_pid, Config),

    %% Monitor the supervisor so we know when it terminates
    SupRef = erlang:monitor(process, SupPid),

    %% Track OS PIDs to verify no orphans
    OsPids = [],

    %% Crash loop: we need to force supervisor restarts (not just self-heals).
    %% Kill adapter -> self-heal starts new port -> kill new adapter during
    %% starting state -> coordinator goes to stopped -> supervisor restarts.
    OsPids1 = crash_until_supervisor_dies(EngineId, SupRef, [], 0, 10),

    %% Verify supervisor terminated
    ?assertNot(is_process_alive(SupPid)),

    %% Verify loom_sup (parent) is still alive — fault isolation works
    ?assert(is_process_alive(whereis(loom_sup))),

    %% Verify no orphaned OS processes
    timer:sleep(500), %% Brief delay for OS process cleanup
    lists:foreach(fun(OsPid) ->
        case is_os_pid_alive(OsPid) of
            true ->
                ct:pal("WARNING: orphaned OS process ~B, killing", [OsPid]),
                kill_os_pid(OsPid),
                ct:fail(io_lib:format("orphaned OS process: ~B", [OsPid]));
            false ->
                ok
        end
    end, OsPids1),

    ct:pal("Supervisor terminated after exceeding max_restarts=2, "
           "tracked ~B OS PIDs, all cleaned up", [length(OsPids1)]).

%% @doc Repeatedly crash the adapter until the supervisor dies.
%% Each iteration: kill adapter (trigger self-heal), then immediately kill
%% the NEW adapter while coordinator is in 'starting' state (forcing
%% coordinator to 'stopped', which triggers a supervisor restart).
crash_until_supervisor_dies(_EngineId, SupRef, OsPids, _Iteration, MaxIterations)
        when _Iteration >= MaxIterations ->
    ct:fail(io_lib:format("supervisor didn't die after ~B iterations", [MaxIterations])),
    OsPids;
crash_until_supervisor_dies(EngineId, SupRef, OsPids, Iteration, MaxIterations) ->
    %% Check if supervisor is still alive
    receive
        {'DOWN', SupRef, process, _Pid, _Reason} ->
            ct:pal("Supervisor terminated at iteration ~B", [Iteration]),
            OsPids
    after 0 ->
        %% Supervisor still alive, crash the adapter
        case catch find_coordinator(EngineId) of
            CoordPid when is_pid(CoordPid) ->
                case catch get_adapter_os_pid(CoordPid, EngineId) of
                    OsPid when is_integer(OsPid) ->
                        ct:pal("Iteration ~B: killing adapter OS PID ~B",
                               [Iteration, OsPid]),
                        kill_os_pid(OsPid),
                        %% Brief wait for self-heal to start new port
                        timer:sleep(200),
                        %% Try to kill the new adapter too (while in starting)
                        NewOsPids = case catch get_adapter_os_pid(CoordPid, EngineId) of
                            NewOsPid when is_integer(NewOsPid), NewOsPid =/= OsPid ->
                                ct:pal("Iteration ~B: killing new adapter ~B (in starting)",
                                       [Iteration, NewOsPid]),
                                kill_os_pid(NewOsPid),
                                [NewOsPid, OsPid | OsPids];
                            _ ->
                                [OsPid | OsPids]
                        end,
                        %% Wait for supervisor to restart coordinator or die
                        timer:sleep(500),
                        crash_until_supervisor_dies(EngineId, SupRef, NewOsPids,
                                                   Iteration + 1, MaxIterations);
                    _ ->
                        %% Port not available yet, wait and retry
                        timer:sleep(200),
                        crash_until_supervisor_dies(EngineId, SupRef, OsPids,
                                                   Iteration, MaxIterations)
                end;
            _ ->
                %% Coordinator not found, supervisor may be restarting it
                timer:sleep(200),
                crash_until_supervisor_dies(EngineId, SupRef, OsPids,
                                           Iteration, MaxIterations)
        end
    end.
```

- [ ] **Step 3: Run test**

Run: `rebar3 ct --suite=test/loom_crash_recovery_SUITE --case=rapid_crash_intensity_test`

Expected: PASS. Supervisor terminates after exceeding max_restarts=2. Log shows iterations.

- [ ] **Step 4: Commit**

```bash
git add test/loom_crash_recovery_SUITE.erl
git commit -m "test: add rapid_crash_intensity_test (scenario 4)

Repeatedly kill adapter to force supervisor restarts, verify
max_restarts intensity is respected, supervisor terminates cleanly,
parent loom_sup stays alive, and no orphaned OS processes.

Refs #13"
```

---

### Task 7: Implement different_exit_codes_test (Scenario 5)

**Files:**
- Modify: `test/loom_crash_recovery_SUITE.erl`

- [ ] **Step 1: Add the test function**

```erlang
%% @doc Scenario 5: Verify the system handles different adapter exit
%% scenarios correctly: clean exit (code 0), application error (code 1),
%% and SIGKILL (code 137). Each crash triggers self-heal and recovery.
different_exit_codes_test(Config) ->
    EngineId = ?config(engine_id, Config),
    CoordPid = find_coordinator(EngineId),

    %% Wait for ready (may have just recovered from prior test)
    wait_status(EngineId, ready, 15000),

    %% --- Exit code 0 (clean exit via crash command) ---
    ct:pal("Testing exit code 0 (clean exit)"),
    PortPid0 = find_port_pid(CoordPid, EngineId),
    ok = loom_port:send(PortPid0, {crash, 0}),
    ok = wait_status(EngineId, ready, 15000),
    ct:pal("Recovered from exit code 0"),

    %% --- Exit code 1 (application error via crash command) ---
    ct:pal("Testing exit code 1 (application error)"),
    PortPid1 = find_port_pid(CoordPid, EngineId),
    ok = loom_port:send(PortPid1, {crash, 1}),
    ok = wait_status(EngineId, ready, 15000),
    ct:pal("Recovered from exit code 1"),

    %% --- Exit code 137 (SIGKILL) ---
    ct:pal("Testing SIGKILL (exit code 137)"),
    OsPid = get_adapter_os_pid(CoordPid, EngineId),
    kill_os_pid(OsPid),
    ok = wait_status(EngineId, ready, 15000),
    ?assertNot(is_os_pid_alive(OsPid)),
    ct:pal("Recovered from SIGKILL"),

    %% Verify final state is clean
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    %% Verify a request works after all the crashes
    {ok, RequestId} = loom_engine_coordinator:generate(
        CoordPid, <<"Post-multi-crash">>, #{}),
    _Tokens = collect_tokens(RequestId, 5, 10000),
    receive
        {loom_done, RequestId, _Stats} -> ok
    after 10000 -> ct:fail("no loom_done after multi-exit-code test")
    end,
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)).
```

- [ ] **Step 2: Run test**

Run: `rebar3 ct --suite=test/loom_crash_recovery_SUITE --case=different_exit_codes_test`

Expected: PASS. Three crashes with different exit codes, all recovered.

- [ ] **Step 3: Commit**

```bash
git add test/loom_crash_recovery_SUITE.erl
git commit -m "test: add different_exit_codes_test (scenario 5)

Verify self-heal after exit code 0 (clean), exit code 1 (error),
and SIGKILL (code 137). Uses the new crash protocol command for
controlled exit codes.

Refs #13"
```

---

### Task 8: Run full crash recovery suite and fix issues

- [ ] **Step 1: Run the complete crash recovery suite**

Run: `rebar3 ct --suite=test/loom_crash_recovery_SUITE --verbose`

Expected: All 5 tests pass. If any fail, diagnose and fix.

- [ ] **Step 2: Run Dialyzer on modified files**

Run: `rebar3 dialyzer`

Expected: No new warnings in `loom_protocol.erl` or test files.

- [ ] **Step 3: Run all existing tests to verify no regressions**

Run: `rebar3 ct`

Expected: All existing suites pass alongside the new suite.

- [ ] **Step 4: Commit if any fixes were needed**

Only if fixes were applied in steps 1-3. Otherwise skip.

---

### Task 9: Create loom_http_disconnect_SUITE (Scenario 6)

**Files:**
- Create: `test/loom_http_disconnect_SUITE.erl`

- [ ] **Step 1: Create the HTTP disconnect test suite**

```erlang
%%%-------------------------------------------------------------------
%%% @doc HTTP client disconnect test suite.
%%%
%%% Validates that abrupt HTTP client disconnection during SSE streaming
%%% is handled gracefully: in-flight requests are cleaned up, the engine
%%% stays ready, and subsequent requests succeed.
%%%
%%% Starts the full loom application with an engine supervisor started
%%% directly (for control over adapter args). Uses raw gen_tcp for
%%% precise connection lifecycle control.
%%%
%%% ASSUMPTION: python3 is on PATH in the test environment.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_http_disconnect_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([client_disconnect_test/1]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [client_disconnect_test].

init_per_suite(Config) ->
    ok = application:load(loom),
    %% Load config so HTTP server starts. Use minimal.json as base.
    ok = loom_config:load(fixture_path("minimal.json")),
    {ok, _} = application:ensure_all_started(loom),

    %% Start our own engine supervisor with slow tokens for disconnect testing.
    %% Use the same engine_id as the first configured engine so the HTTP
    %% handler can find it via loom_http_util:lookup_coordinator/1.
    [FirstEngine | _] = loom_config:engine_names(),
    EngineConfig = #{
        engine_id => FirstEngine,
        adapter_cmd => python_cmd(),
        adapter_args => [mock_adapter_path(), "--token-delay", "0.5"],
        model => <<"test-model">>,
        backend => <<"mock">>,
        gpus => [],
        max_concurrent => 64,
        startup_timeout_ms => 10000,
        drain_timeout_ms => 5000,
        allow_mock_backend => true
    },
    {ok, SupPid} = loom_engine_sup:start_link(EngineConfig),
    ok = wait_status(FirstEngine, ready, 15000),

    %% Get actual HTTP port from ranch
    HttpPort = ranch:get_port(loom_http_listener),

    [{engine_id, FirstEngine}, {sup_pid, SupPid},
     {http_port, HttpPort} | Config].

end_per_suite(Config) ->
    case ?config(sup_pid, Config) of
        Pid when is_pid(Pid), is_process_alive(Pid) ->
            stop_sup(Pid);
        _ -> ok
    end,
    application:stop(loom),
    loom_test_helpers:cleanup_ets(),
    ok.

init_per_testcase(_TestCase, Config) ->
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_TestCase, _Config) ->
    flush_mailbox(),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc Scenario 6: Start an SSE stream via HTTP, disconnect the client
%% mid-stream. Verify the in-flight request is cleaned up, the engine
%% stays ready, and a new HTTP request succeeds.
client_disconnect_test(Config) ->
    EngineId = ?config(engine_id, Config),
    Port = ?config(http_port, Config),

    %% Verify engine is ready before test
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    %% Open raw TCP connection and send streaming request
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port,
        [binary, {active, false}, {packet, raw}]),

    Body = loom_json:encode(#{
        model => <<"test-model">>,
        messages => [#{role => <<"user">>, content => <<"Hello">>}],
        stream => true
    }),
    BodyLen = byte_size(Body),

    HttpReq = iolist_to_binary([
        <<"POST /v1/chat/completions HTTP/1.1\r\n">>,
        <<"Host: localhost:", (integer_to_binary(Port))/binary, "\r\n">>,
        <<"Content-Type: application/json\r\n">>,
        <<"Content-Length: ", (integer_to_binary(BodyLen))/binary, "\r\n">>,
        <<"\r\n">>,
        Body
    ]),

    ok = gen_tcp:send(Socket, HttpReq),

    %% Read response until we get at least one SSE data event
    %% (confirms streaming has started and a request is in-flight)
    {ok, ResponseData} = read_until_sse_data(Socket, <<>>, 10000),
    ct:pal("Received SSE data before disconnect: ~s",
           [truncate(ResponseData, 200)]),

    %% Verify the coordinator has an in-flight request
    %% ASSUMPTION: The request is still in-flight because --token-delay 0.5s
    %% means 5 tokens take ~2.5s total.
    ?assert(loom_engine_coordinator:get_load(EngineId) > 0),

    %% Abruptly close the TCP connection
    gen_tcp:close(Socket),
    ct:pal("TCP connection closed abruptly"),

    %% Wait for the coordinator to clean up the in-flight request.
    %% When Cowboy detects the closed connection, it terminates the handler
    %% process. The coordinator's DOWN monitor fires and cleans up.
    wait_load_zero(EngineId, 10000),

    %% Verify engine is still ready (not crashed)
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),

    %% Verify a new HTTP request succeeds
    {ok, Socket2} = gen_tcp:connect({127, 0, 0, 1}, Port,
        [binary, {active, false}, {packet, raw}]),

    Body2 = loom_json:encode(#{
        model => <<"test-model">>,
        messages => [#{role => <<"user">>, content => <<"World">>}],
        stream => false
    }),
    BodyLen2 = byte_size(Body2),

    HttpReq2 = iolist_to_binary([
        <<"POST /v1/chat/completions HTTP/1.1\r\n">>,
        <<"Host: localhost:", (integer_to_binary(Port))/binary, "\r\n">>,
        <<"Content-Type: application/json\r\n">>,
        <<"Content-Length: ", (integer_to_binary(BodyLen2))/binary, "\r\n">>,
        <<"\r\n">>,
        Body2
    ]),

    ok = gen_tcp:send(Socket2, HttpReq2),

    %% Read the full response (non-streaming)
    {ok, Response2} = read_full_response(Socket2, <<>>, 15000),
    ct:pal("Post-disconnect response: ~s", [truncate(Response2, 300)]),

    %% Verify we got a 200 OK response
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Response2),

    gen_tcp:close(Socket2),
    ct:pal("Client disconnect test passed").

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

wait_status(EngineId, Status, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_status(EngineId) of
        Status -> ok;
        _ ->
            timer:sleep(50),
            wait_status(EngineId, Status, Timeout - 50)
    end;
wait_status(_EngineId, Status, _Timeout) ->
    ct:fail(io_lib:format("wait_status: never reached ~p", [Status])).

wait_load_zero(EngineId, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_load(EngineId) of
        0 -> ok;
        _ ->
            timer:sleep(50),
            wait_load_zero(EngineId, Timeout - 50)
    end;
wait_load_zero(_EngineId, _Timeout) ->
    ct:fail("wait_load_zero: load never reached 0").

stop_sup(SupPid) ->
    MonRef = erlang:monitor(process, SupPid),
    exit(SupPid, shutdown),
    receive
        {'DOWN', MonRef, process, SupPid, _Reason} -> ok
    after 10000 -> ct:fail("supervisor didn't terminate")
    end.

flush_mailbox() ->
    receive _ -> flush_mailbox()
    after 0 -> ok
    end.

%% @doc Read from socket until we find "data: " (SSE event) or timeout.
read_until_sse_data(Socket, Acc, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            Combined = <<Acc/binary, Data/binary>>,
            case binary:match(Combined, <<"data: ">>) of
                nomatch ->
                    read_until_sse_data(Socket, Combined, Timeout);
                _ ->
                    {ok, Combined}
            end;
        {error, timeout} ->
            ct:fail("timeout waiting for SSE data");
        {error, Reason} ->
            ct:fail(io_lib:format("socket error: ~p", [Reason]))
    end.

%% @doc Read full HTTP response from socket.
read_full_response(Socket, Acc, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} ->
            Combined = <<Acc/binary, Data/binary>>,
            %% For non-streaming, check if we've received the full body.
            %% Simple heuristic: look for double CRLF (end of headers)
            %% then check Content-Length.
            case is_response_complete(Combined) of
                true -> {ok, Combined};
                false -> read_full_response(Socket, Combined, Timeout)
            end;
        {error, closed} ->
            %% Server closed connection after sending response
            {ok, Acc};
        {error, timeout} ->
            %% Return what we have
            {ok, Acc};
        {error, Reason} ->
            ct:fail(io_lib:format("socket error: ~p", [Reason]))
    end.

%% @doc Simple check if an HTTP response is complete.
%% Looks for the end of a JSON body (closing brace after headers).
is_response_complete(Data) ->
    case binary:match(Data, <<"\r\n\r\n">>) of
        nomatch -> false;
        {Pos, _Len} ->
            %% We have headers. Check if body looks complete.
            Body = binary:part(Data, Pos + 4, byte_size(Data) - Pos - 4),
            %% ASSUMPTION: Non-streaming responses are JSON objects.
            %% Check for closing brace followed by potential whitespace.
            byte_size(Body) > 0 andalso
            binary:last(string:trim(Body, trailing)) =:= $}
    end.

%% @doc Truncate binary for logging.
truncate(Bin, MaxLen) when byte_size(Bin) =< MaxLen -> Bin;
truncate(Bin, MaxLen) ->
    <<Prefix:MaxLen/binary, _/binary>> = Bin,
    <<Prefix/binary, "...">>.
```

- [ ] **Step 2: Run test**

Run: `rebar3 ct --suite=test/loom_http_disconnect_SUITE --verbose`

Expected: PASS. Log shows SSE data received, disconnect, cleanup, and successful follow-up request.

- [ ] **Step 3: Commit**

```bash
git add test/loom_http_disconnect_SUITE.erl
git commit -m "test: add loom_http_disconnect_SUITE (scenario 6)

Tests HTTP client disconnect during SSE streaming: open connection,
read SSE data, close socket abruptly, verify coordinator cleans up
in-flight request, engine stays ready, and next request succeeds.

Refs #13"
```

---

### Task 10: Full verification and final commit

- [ ] **Step 1: Run all tests**

Run: `rebar3 ct --verbose`

Expected: All suites pass, including the two new ones.

- [ ] **Step 2: Run Dialyzer**

Run: `rebar3 dialyzer`

Expected: No new warnings.

- [ ] **Step 3: Verify no orphaned test processes**

Run: `rebar3 ct --suite=test/loom_crash_recovery_SUITE,test/loom_http_disconnect_SUITE --repeat 2`

Expected: Running twice confirms no state leakage between runs.

- [ ] **Step 4: Review test output for recovery time measurements**

Check CT logs for `Recovery time:` entries. Typical expectations:
- Idle crash recovery: 500-2000ms
- Active crash recovery: 500-2000ms
- Different exit codes: similar range per recovery

- [ ] **Step 5: Final commit (if any last fixes)**

Only if fixes were applied. Otherwise the work is complete.

---

## Assumptions

- `loom_port:get_os_pid/1` is a public API that returns the OS PID of the managed subprocess.
- `loom_engine_sup:sup_name/1` is exported and returns the registered supervisor atom name.
- The `loom_config:engine_names/0` function returns engine names in config order, and the first name matches the `fixture_engine` from `minimal.json`.
- `ranch:get_port(loom_http_listener)` returns the actual bound port for the HTTP listener.
- `os:cmd("kill -9 " ++ Pid)` works on macOS and Linux CI environments.
- The mock adapter's heartbeat + ready sequence completes within 15 seconds.
- Starting `loom_engine_sup` directly (outside `loom_sup`) is supported and the coordinator's ETS tables are findable by the HTTP handler.
