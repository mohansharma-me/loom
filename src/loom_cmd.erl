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
    Pid = spawn(fun() ->
        Port = open_port({spawn, Cmd}, [stream, exit_status, binary,
                                         stderr_to_stdout]),
        collect_port_output(Port, <<>>, Parent, Ref)
    end),
    MonRef = monitor(process, Pid),
    receive
        {Ref, {ok, Output}} ->
            demonitor(MonRef, [flush]),
            {ok, binary_to_list(Output)};
        {Ref, {error, _} = Err} ->
            demonitor(MonRef, [flush]),
            Err;
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, {process_died, Reason}}
    after Timeout ->
        exit(Pid, kill),
        demonitor(MonRef, [flush]),
        receive {Ref, _} -> ok after 0 -> ok end,
        ?LOG_WARNING("loom_cmd: command timed out after ~bms: ~s",
                     [Timeout, Cmd]),
        {error, timeout}
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

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
