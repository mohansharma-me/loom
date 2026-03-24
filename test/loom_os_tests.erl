%%%-------------------------------------------------------------------
%%% @doc Unit tests for loom_os.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_os_tests).

-include_lib("eunit/include/eunit.hrl").

%% ASSUMPTION: Tests run on a Unix-like system (macOS or Linux) where
%% the `sleep` and `kill` commands are available. Windows CI would
%% need separate test cases.

force_kill_undefined_test() ->
    %% Calling with undefined is a no-op, must not crash.
    ?assertEqual(ok, loom_os:force_kill(undefined)).

force_kill_live_process_test() ->
    %% Spawn a real OS process (sleep 60), then force-kill it.
    Port = open_port({spawn, "sleep 60"}, [exit_status]),
    OsPid = case erlang:port_info(Port, os_pid) of
        {os_pid, P} -> P;
        undefined -> error(no_os_pid)
    end,
    ?assertEqual(ok, loom_os:force_kill(OsPid)),
    %% Wait for exit_status to confirm the process died.
    receive
        {Port, {exit_status, _}} -> ok
    after 3000 ->
        port_close(Port),
        error(process_not_killed)
    end.

force_kill_dead_process_test() ->
    %% Killing an already-dead PID should return ok (not crash).
    %% Use a PID that almost certainly doesn't exist.
    ?assertEqual(ok, loom_os:force_kill(999999999)).

force_kill_zero_pid_test() ->
    %% PID 0 would send SIGKILL to the entire process group on Unix.
    %% The catch-all clause must handle this safely (log + return ok).
    ?assertEqual(ok, loom_os:force_kill(0)).

force_kill_negative_pid_test() ->
    %% Negative PIDs are invalid; catch-all clause returns ok.
    ?assertEqual(ok, loom_os:force_kill(-1)).
