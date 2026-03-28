%%%-------------------------------------------------------------------
%%% @doc loom_cmd - shared utility for running OS commands with timeout.
%%%
%%% Uses open_port/2 instead of os:cmd/1 so the OS subprocess PID can
%%% be captured and force-killed on timeout via loom_os:force_kill/1.
%%% os:cmd/1 would block indefinitely and orphan the subprocess.
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
    %% ASSUMPTION: The os_pid message arrives before any port data because
    %% open_port returns and port_info runs before the shell subprocess
    %% produces output. We receive it first, then wait for the result.

    receive
        {Ref, os_pid, OsPid} ->
            Remaining = max(0, Timeout - (erlang:monotonic_time(millisecond) - T0)),
            wait_result(Ref, MonRef, Pid, OsPid, Cmd, Timeout, Remaining);
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, {process_died, Reason}}
    after Timeout ->
        exit(Pid, kill),
        demonitor(MonRef, [flush]),
        %% ASSUMPTION: The os_pid message arrives nearly instantly after
        %% open_port, but under extreme load it may be queued after the
        %% timeout fires. Flush it so we can force-kill the OS subprocess.
        MaybeOsPid = receive {Ref, os_pid, P} -> P after 0 -> undefined end,
        flush_ref(Ref),
        loom_os:force_kill(MaybeOsPid),
        ?LOG_WARNING(#{msg => command_timed_out, timeout_ms => Timeout, command => Cmd}),
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
        ?LOG_WARNING(#{msg => command_timed_out, timeout_ms => OrigTimeout, command => Cmd}),
        {error, timeout}
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

%% @doc Drain any pending result ({Ref, _}) or os_pid notification
%% ({Ref, os_pid, _}) from the mailbox.
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
