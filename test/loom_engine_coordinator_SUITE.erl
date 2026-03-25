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
    drain_empty_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        startup_to_ready_test,
        happy_path_generate_test,
        drain_with_inflight_test,
        drain_empty_test
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
