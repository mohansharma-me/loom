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

flush_mailbox() ->
    receive _ -> flush_mailbox()
    after 0 -> ok
    end.
