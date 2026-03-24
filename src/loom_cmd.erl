%%%-------------------------------------------------------------------
%%% @doc loom_cmd - shared utility for running OS commands with timeout.
%%%
%%% Uses open_port/2 instead of os:cmd/1 so the OS subprocess can be
%%% killed cleanly on timeout via port_close/1. os:cmd/1 would block
%%% indefinitely and orphan the subprocess if killed.
%%%
%%% ASSUMPTION: Commands are run via {spawn, Cmd} which goes through
%%% the system shell. This is appropriate for well-known system tools
%%% (nvidia-smi, sysctl, vm_stat) but not for untrusted input.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_cmd).

-export([run_with_timeout/2]).

-include_lib("kernel/include/logger.hrl").

-spec run_with_timeout(string(), pos_integer()) ->
    {ok, string()} | {error, term()}.
run_with_timeout(Cmd, Timeout) ->
    Parent = self(),
    Ref = make_ref(),
    T0 = erlang:monotonic_time(millisecond),
    Pid = spawn(fun() ->
        Port = open_port({spawn, Cmd}, [stream, exit_status, binary,
                                         stderr_to_stdout]),
        OsPid = case erlang:port_info(Port, os_pid) of
            {os_pid, P} -> P;
            undefined   -> undefined
        end,
        Parent ! {Ref, os_pid, OsPid},
        collect_port_output(Port, <<>>, Parent, Ref)
    end),
    MonRef = monitor(process, Pid),
    %% Wait for the OS PID first (arrives immediately after port opens).
    %% Then wait for the command result with the remaining timeout.
    receive
        {Ref, os_pid, OsPid} ->
            Remaining = max(0, Timeout - (erlang:monotonic_time(millisecond) - T0)),
            wait_result(Ref, MonRef, Pid, OsPid, Cmd, Timeout, Remaining);
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, {process_died, Reason}}
    after Timeout ->
        exit(Pid, kill),
        demonitor(MonRef, [flush]),
        flush_ref(Ref),
        ?LOG_WARNING("loom_cmd: command timed out after ~bms: ~s",
                     [Timeout, Cmd]),
        {error, timeout}
    end.

%% @doc Wait for the command result. On timeout or process death, force-kill
%% the OS subprocess to prevent orphans.
-spec wait_result(reference(), reference(), pid(),
                  pos_integer() | undefined, string(),
                  pos_integer(), non_neg_integer()) ->
    {ok, string()} | {error, term()}.
wait_result(Ref, MonRef, Pid, OsPid, Cmd, OrigTimeout, Remaining) ->
    receive
        {Ref, {ok, Output}} ->
            demonitor(MonRef, [flush]),
            {ok, binary_to_list(Output)};
        {Ref, {error, _} = Err} ->
            demonitor(MonRef, [flush]),
            Err;
        {'DOWN', MonRef, process, Pid, Reason} ->
            loom_os:force_kill(OsPid),
            {error, {process_died, Reason}}
    after Remaining ->
        exit(Pid, kill),
        demonitor(MonRef, [flush]),
        flush_ref(Ref),
        loom_os:force_kill(OsPid),
        ?LOG_WARNING("loom_cmd: command timed out after ~bms: ~s",
                     [OrigTimeout, Cmd]),
        {error, timeout}
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec flush_ref(reference()) -> ok.
flush_ref(Ref) ->
    receive {Ref, _} -> ok after 0 -> ok end,
    receive {Ref, _, _} -> ok after 0 -> ok end.

-spec collect_port_output(port(), binary(), pid(), reference()) -> ok.
collect_port_output(Port, Acc, Parent, Ref) ->
    receive
        {Port, {data, Data}} ->
            collect_port_output(Port, <<Acc/binary, Data/binary>>, Parent, Ref);
        {Port, {exit_status, 0}} ->
            Parent ! {Ref, {ok, Acc}},
            ok;
        {Port, {exit_status, Code}} ->
            Parent ! {Ref, {error, {exit_code, Code}}},
            ok
    end.
