%%%-------------------------------------------------------------------
%%% @doc loom_os - cross-platform OS utilities.
%%%
%%% Provides platform-aware operations that differ between Unix and
%%% Windows. Currently exposes force_kill/1 for sending SIGKILL (Unix)
%%% or taskkill /F (Windows) to an OS process by PID.
%%%
%%% ASSUMPTION: os:type() returns {unix, _} on Linux/macOS/FreeBSD and
%%% {win32, _} on Windows. This covers all platforms Erlang/OTP
%%% officially supports.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_os).

-export([force_kill/1]).

-include_lib("kernel/include/logger.hrl").

%% @doc Force-kill an OS process by PID.
%%
%% Uses `kill -9` on Unix and `taskkill /F /PID` on Windows.
%% Returns `ok` unconditionally — the process may already be dead,
%% and that is not an error. Logs a warning when actually killing;
%% the undefined (no-op) case logs at debug level only.
%%
%% Accepts `undefined` as a no-op (the OS PID was never captured).
-spec force_kill(pos_integer() | undefined) -> ok.
force_kill(undefined) ->
    ?LOG_DEBUG("loom_os: force_kill called with undefined pid, skipping"),
    ok;
force_kill(OsPid) when is_integer(OsPid), OsPid > 0 ->
    ?LOG_WARNING("loom_os: force-killing OS process ~b", [OsPid]),
    Cmd = case os:type() of
        {unix, _} ->
            "kill -9 " ++ integer_to_list(OsPid) ++ " 2>&1";
        {win32, _} ->
            "taskkill /F /PID " ++ integer_to_list(OsPid)
    end,
    %% ASSUMPTION: os:cmd/1 is synchronous but kill/taskkill returns near-
    %% instantly on all supported platforms. This blocks the caller briefly
    %% (~10ms). If this becomes an issue in terminate/3, wrapping in a
    %% spawned process would avoid blocking, but adds complexity.
    case string:trim(os:cmd(Cmd)) of
        "" -> ok;
        Output ->
            ?LOG_DEBUG("loom_os: force_kill output for OS pid ~b: ~s",
                       [OsPid, Output]),
            ok
    end;
force_kill(BadPid) ->
    ?LOG_ERROR("loom_os: force_kill called with invalid pid: ~p", [BadPid]),
    ok.
