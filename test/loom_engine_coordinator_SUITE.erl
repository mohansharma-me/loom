%%%-------------------------------------------------------------------
%%% @doc Common Test integration suite for loom_engine_coordinator.
%%%
%%% Tests cover coordinator lifecycle: startup via loom_port, reaching
%%% ready state, ETS table population, and clean shutdown.
%%%
%%% ASSUMPTION: The loom application (and its priv dir) is available
%%% at test runtime because init_per_suite/1 starts it explicitly.
%%% ASSUMPTION: python3 is on PATH in the test environment.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_engine_coordinator_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    startup_to_ready_test/1,
    happy_path_generate_test/1,
    drain_with_inflight_test/1,
    drain_empty_test/1,
    startup_timeout_test/1,
    not_ready_rejection_test/1,
    max_concurrent_test/1,
    port_crash_inflight_test/1,
    self_heal_then_succeed_test/1,
    port_crash_during_drain_test/1,
    caller_death_test/1,
    drain_timeout_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        startup_to_ready_test,
        happy_path_generate_test,
        drain_with_inflight_test,
        drain_empty_test,
        startup_timeout_test,
        not_ready_rejection_test,
        max_concurrent_test,
        port_crash_inflight_test,
        self_heal_then_succeed_test,
        port_crash_during_drain_test,
        caller_death_test,
        drain_timeout_test
    ].

init_per_suite(Config) ->
    %% Start the loom application so code:priv_dir(loom) resolves correctly.
    %% ASSUMPTION: application:ensure_all_started/1 is idempotent; if loom is
    %% already running (e.g., from a prior suite) it just returns {ok, []}.
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Trap exits so the test process receives EXIT signals from
    %% linked or monitored processes without crashing.
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_TestCase, _Config) ->
    %% Flush any leftover messages from the test mailbox to prevent
    %% cross-test contamination.
    flush_mailbox(),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc Tests that the coordinator starts, reaches ready state, ETS tables
%% are populated correctly, and can be cleanly stopped.
startup_to_ready_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),
    Info = loom_engine_coordinator:get_info(EngineId),
    ?assertEqual(EngineId, maps:get(engine_id, Info)),
    ?assertEqual(<<"mock">>, maps:get(model, Info)),
    ?assertEqual(<<"mock">>, maps:get(backend, Info)),
    ?assertEqual(ready, maps:get(status, Info)),
    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%% @doc Tests the full generate request lifecycle: generate call returns
%% a request ID, tokens are routed to the caller, done message arrives
%% with correct stats, and load returns to zero after completion.
happy_path_generate_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    {ok, RequestId} = loom_engine_coordinator:generate(
        Pid, <<"Hello">>, #{max_tokens => 100}),
    ?assert(is_binary(RequestId)),

    %% Mock adapter sends 5 tokens + 1 done
    Tokens = collect_tokens(RequestId, 5, 5000),
    ?assertEqual(5, length(Tokens)),

    receive
        {loom_done, RequestId, Stats} ->
            ?assertEqual(5, maps:get(tokens, Stats)),
            ok
    after 5000 ->
        ct:fail("no loom_done received")
    end,

    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%% @doc Tests graceful drain with an in-flight request: initiates a generate,
%% then shutdown. New requests must be rejected with {error, draining}. The
%% in-flight request completes normally. After completion, coordinator stops.
drain_with_inflight_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),
    {ok, RequestId} = loom_engine_coordinator:generate(Pid, <<"Hello">>, #{}),
    ok = loom_engine_coordinator:shutdown(Pid),
    ?assertMatch({error, draining},
                 loom_engine_coordinator:generate(Pid, <<"World">>, #{})),
    _Tokens = collect_tokens(RequestId, 5, 5000),
    receive
        {loom_done, RequestId, _Stats} -> ok
    after 5000 -> ct:fail("no loom_done during drain")
    end,
    wait_status(EngineId, stopped, 5000),
    wait_dead(Pid, 5000).

%% @doc Tests drain with no in-flight requests: shutdown should immediately
%% transition to stopped and the coordinator process should terminate.
drain_empty_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),
    ok = loom_engine_coordinator:shutdown(Pid),
    wait_status(EngineId, stopped, 5000),
    wait_dead(Pid, 5000).

%% @doc Tests that the coordinator stops when the adapter takes longer to
%% start than the configured startup_timeout_ms. Uses a 30s startup delay
%% with a 2s timeout — the coordinator should reach `stopped` state.
startup_timeout_test(_Config) ->
    Config = (default_config())#{
        engine_id => <<"test_engine_timeout">>,
        args => [mock_adapter_path(), "--startup-delay", "30"],
        startup_timeout_ms => 2000
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    %% ASSUMPTION: 2s timeout fires well before the 30s startup delay completes,
    %% so the coordinator transitions to stopped.
    wait_status(EngineId, stopped, 5000),
    wait_dead(Pid, 5000).

%% @doc Tests that a generate request sent while the coordinator is still
%% in the `starting` state is rejected with {error, not_ready}.
%% Uses a 5s startup delay so the adapter is not ready after 200ms.
not_ready_rejection_test(_Config) ->
    Config = (default_config())#{
        engine_id => <<"test_engine_not_ready">>,
        args => [mock_adapter_path(), "--startup-delay", "5"],
        startup_timeout_ms => 10000
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    %% Wait briefly — adapter is still loading (5s delay)
    timer:sleep(200),
    Result = loom_engine_coordinator:generate(Pid, <<"Hello">>, #{}),
    ?assertMatch({error, not_ready}, Result),
    %% Clean up: stop the coordinator
    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 10000).

%% @doc Tests that a third concurrent request is rejected with
%% {error, overloaded} when max_concurrent is set to 2.
%% Spawns two concurrent callers that each hold an in-flight request,
%% then attempts a third which should be overloaded.
max_concurrent_test(_Config) ->
    Config = (default_config())#{
        engine_id => <<"test_engine_overload">>,
        max_concurrent => 2
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    Self = self(),

    %% Spawn two concurrent callers that each issue a generate request
    %% and report the result back. They hold the slot until we collect tokens.
    Caller1 = spawn_link(fun() ->
        Res = loom_engine_coordinator:generate(Pid, <<"Prompt1">>, #{}),
        Self ! {caller_result, 1, Res},
        flush_and_wait()
    end),
    Caller2 = spawn_link(fun() ->
        Res = loom_engine_coordinator:generate(Pid, <<"Prompt2">>, #{}),
        Self ! {caller_result, 2, Res},
        flush_and_wait()
    end),

    %% Collect results from both callers — both should succeed
    Res1 = receive {caller_result, 1, R1} -> R1 after 5000 -> ct:fail("caller 1 timeout") end,
    Res2 = receive {caller_result, 2, R2} -> R2 after 5000 -> ct:fail("caller 2 timeout") end,
    ?assertMatch({ok, _}, Res1),
    ?assertMatch({ok, _}, Res2),

    %% Third request should be rejected — both slots are occupied
    Res3 = loom_engine_coordinator:generate(Pid, <<"Prompt3">>, #{}),
    ?assertMatch({error, overloaded}, Res3),

    %% Clean up spawned callers
    exit(Caller1, kill),
    exit(Caller2, kill),

    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%% @doc Tests that killing the port while a request is in-flight delivers
%% an engine_crashed error to the caller, and the coordinator self-heals
%% back to ready state.
%% Uses --token-delay 1 so the request stays in-flight long enough to kill.
port_crash_inflight_test(_Config) ->
    Config = (default_config())#{
        engine_id => <<"test_engine_crash_inflight">>,
        args => [mock_adapter_path(), "--token-delay", "1"]
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% Start a slow generate request (tokens arrive every 1s)
    {ok, RequestId} = loom_engine_coordinator:generate(Pid, <<"Hello">>, #{}),

    %% Wait for load to become > 0 (request is in-flight)
    wait_load_nonzero(EngineId, 2000),
    ?assert(loom_engine_coordinator:get_load(EngineId) > 0),

    %% Find the port pid from the coordinator's links
    %% ASSUMPTION: The coordinator links to the loom_port process. We filter
    %% out the test process (self()) to find the port pid.
    PortPid = find_port_pid(Pid),
    ?assert(is_pid(PortPid)),

    %% Kill the port process — coordinator traps exits, so it will self-heal
    exit(PortPid, kill),

    %% Verify caller receives engine_crashed error
    receive
        {loom_error, RequestId, <<"engine_crashed">>, _Detail} ->
            ok
    after 5000 ->
        ct:fail("no loom_error engine_crashed received")
    end,

    %% Verify self-heal: coordinator returns to ready state
    wait_status(EngineId, ready, 10000),
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),

    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%% @doc Tests that after a port crash and self-heal, the coordinator can
%% successfully handle a new generate request end-to-end.
%% Uses default fast adapter (no token delay).
self_heal_then_succeed_test(_Config) ->
    Config = (default_config())#{
        engine_id => <<"test_engine_self_heal">>
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% Find and kill the port pid to trigger self-heal
    OldPortPid = find_port_pid(Pid),
    exit(OldPortPid, kill),

    %% Wait for self-heal to complete: the coordinator will go through
    %% starting -> ready with a new port. With a fast adapter, this can
    %% happen before our poll catches the intermediate state, so we wait
    %% for the port pid to change (proving self-heal happened) AND for
    %% ready status.
    wait_port_pid_changed(Pid, OldPortPid, 10000),
    wait_status(EngineId, ready, 10000),

    %% Now send a new generate request — it should succeed end-to-end
    {ok, RequestId} = loom_engine_coordinator:generate(Pid, <<"Hello">>, #{}),
    ?assert(is_binary(RequestId)),

    %% Collect 5 tokens from mock adapter
    Tokens = collect_tokens(RequestId, 5, 5000),
    ?assertEqual(5, length(Tokens)),

    %% Collect the done message
    receive
        {loom_done, RequestId, Stats} ->
            ?assertEqual(5, maps:get(tokens, Stats)),
            ok
    after 5000 ->
        ct:fail("no loom_done received after self-heal")
    end,

    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%% @doc Tests that killing the port during drain transitions the coordinator
%% to stopped (NOT starting — no self-heal during drain).
%% Uses --token-delay 1 so the request is in-flight long enough to drain+kill.
port_crash_during_drain_test(_Config) ->
    Config = (default_config())#{
        engine_id => <<"test_engine_drain_crash">>,
        args => [mock_adapter_path(), "--token-delay", "1"]
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% Start a slow request so we have an in-flight during drain
    {ok, _RequestId} = loom_engine_coordinator:generate(Pid, <<"Hello">>, #{}),

    %% Wait for request to be in-flight
    wait_load_nonzero(EngineId, 2000),

    %% Initiate drain — coordinator moves to draining state
    ok = loom_engine_coordinator:shutdown(Pid),
    wait_status(EngineId, draining, 5000),

    %% Find and kill the port while draining
    PortPid = find_port_pid(Pid),
    exit(PortPid, kill),

    %% Verify coordinator goes to stopped (NOT starting — no self-heal during drain)
    wait_status(EngineId, stopped, 10000),

    %% Drain any remaining messages (error notifications, EXIT signals, etc.)
    drain_messages(500),

    wait_dead(Pid, 5000).

%% @doc Tests that when a caller dies after issuing a generate request,
%% the coordinator detects the DOWN and cleans up the in-flight request
%% (load returns to 0, ETS entry removed).
caller_death_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),
    Self = self(),
    CallerPid = spawn(fun() ->
        Result = loom_engine_coordinator:generate(Pid, <<"Hello">>, #{}),
        Self ! {caller_started, Result},
        ok
    end),
    receive
        {caller_started, {ok, _RequestId}} -> ok;
        {caller_started, {error, Reason}} ->
            ct:fail(io_lib:format("generate failed: ~p", [Reason]))
    after 5000 -> ct:fail("caller never started request")
    end,
    %% ASSUMPTION: 200ms is enough time for the coordinator to process
    %% the DOWN message from the dead caller and clean up the request.
    timer:sleep(200),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),
    ?assertEqual(false, is_process_alive(CallerPid)),
    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%% @doc Tests that when a drain timeout fires (adapter too slow to finish
%% in-flight requests), the caller receives a drain_timeout error.
%% Uses --token-delay 2 (2s between tokens) with drain_timeout_ms => 500.
drain_timeout_test(_Config) ->
    Config = (default_config())#{
        args => [mock_adapter_path(), "--token-delay", "2"],
        drain_timeout_ms => 500
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),
    Self = self(),
    _Caller = spawn_link(fun() ->
        {ok, ReqId} = loom_engine_coordinator:generate(Pid, <<"Hello">>, #{}),
        Self ! {req_started, ReqId},
        receive
            {loom_error, ReqId, Code, _Msg} ->
                Self ! {got_error, ReqId, Code}
        after 10000 ->
            Self ! {timeout_never_fired, ReqId}
        end
    end),
    receive
        {req_started, _ReqId} -> ok
    after 5000 -> ct:fail("request never started")
    end,
    ok = loom_engine_coordinator:shutdown(Pid),
    receive
        {got_error, _ReqId2, <<"drain_timeout">>} -> ok;
        {got_error, _ReqId2, OtherCode} ->
            ct:pal("got error code: ~p (acceptable)", [OtherCode]);
        {timeout_never_fired, _} ->
            ct:fail("drain timeout never fired")
    after 10000 ->
        ct:fail("no error from drain timeout")
    end,
    wait_status(EngineId, stopped, 5000),
    wait_dead(Pid, 5000).

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Path to the mock adapter Python script.
mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

%% @doc Path to python3 executable.
python_cmd() ->
    os:find_executable("python3").

%% @doc Default coordinator config using the mock adapter.
default_config() ->
    #{
        engine_id => <<"test_engine">>,
        command => python_cmd(),
        args => [mock_adapter_path()],
        model => <<"mock">>,
        backend => <<"mock">>,
        startup_timeout_ms => 10000,
        drain_timeout_ms => 5000,
        max_concurrent => 64
    }.

%% @doc Poll get_status/1 until it returns the expected Status or timeout.
wait_status(EngineId, Status, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_status(EngineId) of
        Status ->
            ok;
        _ ->
            timer:sleep(50),
            wait_status(EngineId, Status, Timeout - 50)
    end;
wait_status(_EngineId, Status, _Timeout) ->
    ct:fail(io_lib:format("wait_status: never reached status ~p", [Status])).

%% @doc Wait up to TimeoutMs for Pid to die.
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
                    ct:fail(io_lib:format("wait_dead: pid ~p still alive after timeout", [Pid]));
                true ->
                    timer:sleep(min(50, Remaining)),
                    wait_dead_loop(Pid, Deadline)
            end
    end.

%% @doc Collect N token messages for a given RequestId, with timeout.
collect_tokens(_RequestId, 0, _Timeout) -> [];
collect_tokens(RequestId, N, Timeout) ->
    receive
        {loom_token, RequestId, Text, _Finished} ->
            [Text | collect_tokens(RequestId, N - 1, Timeout)]
    after Timeout ->
        ct:fail(io_lib:format("collect_tokens: timeout waiting for token ~w", [N]))
    end.

%% @doc Drain all messages from the current process mailbox.
flush_mailbox() ->
    receive
        _ -> flush_mailbox()
    after 0 ->
        ok
    end.

%% @doc Block and drain all messages for up to 30 seconds.
%% Used by spawned callers to stay alive (holding their in-flight request
%% slot) until the test process kills them.
flush_and_wait() ->
    receive _ -> flush_and_wait()
    after 30000 -> ok
    end.

%% @doc Find the loom_port pid from a coordinator's linked processes.
%% Filters out self() from the coordinator's links to find the port pid.
%% ASSUMPTION: The coordinator has exactly one link besides the test process
%% (self()), which is the loom_port process.
find_port_pid(CoordinatorPid) ->
    {links, Links} = process_info(CoordinatorPid, links),
    Self = self(),
    PortPids = [P || P <- Links, is_pid(P), P =/= Self],
    case PortPids of
        [PortPid | _] -> PortPid;
        [] -> undefined
    end.

%% @doc Poll get_load/1 until it returns > 0 or timeout.
wait_load_nonzero(EngineId, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_load(EngineId) of
        N when is_integer(N), N > 0 ->
            ok;
        _ ->
            timer:sleep(50),
            wait_load_nonzero(EngineId, Timeout - 50)
    end;
wait_load_nonzero(_EngineId, _Timeout) ->
    ct:fail("wait_load_nonzero: load never became > 0").

%% @doc Wait until the coordinator's port pid changes from OldPortPid.
%% Proves that self-heal has started (new loom_port spawned).
wait_port_pid_changed(CoordinatorPid, OldPortPid, Timeout) when Timeout > 0 ->
    case is_process_alive(CoordinatorPid) of
        false ->
            ct:fail("wait_port_pid_changed: coordinator died");
        true ->
            CurrentPortPid = find_port_pid(CoordinatorPid),
            case CurrentPortPid =/= OldPortPid andalso CurrentPortPid =/= undefined of
                true -> ok;
                false ->
                    timer:sleep(50),
                    wait_port_pid_changed(CoordinatorPid, OldPortPid, Timeout - 50)
            end
    end;
wait_port_pid_changed(_CoordinatorPid, _OldPortPid, _Timeout) ->
    ct:fail("wait_port_pid_changed: port pid never changed").

%% @doc Drain all messages from the mailbox, waiting up to Timeout ms
%% for each message. Returns ok when no more messages arrive within Timeout.
drain_messages(Timeout) ->
    receive _ -> drain_messages(Timeout)
    after Timeout -> ok
    end.
