%%%-------------------------------------------------------------------
%%% @doc loom_gpu_backend_apple - Apple Silicon GPU monitoring via
%%% sysctl and vm_stat.
%%%
%%% Apple Silicon uses unified memory shared between CPU and GPU.
%%% There is no public Metal API for per-process GPU utilisation,
%%% so gpu_util is always -1.0. System RAM (via sysctl/vm_stat)
%%% is the correct proxy for model memory since MLX allocates
%%% from the unified pool.
%%%
%%% ASSUMPTION: sysctl hw.memsize returns total physical RAM in
%%% bytes. vm_stat returns page statistics with page size on the
%%% first line. Both commands are available on all macOS versions
%%% since 10.x.
%%%
%%% ASSUMPTION: On Apple Silicon Macs, sysctl -n hw.optional.arm64
%%% returns "1". This distinguishes Apple Silicon from Intel Macs.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_gpu_backend_apple).
-behaviour(loom_gpu_backend).

-export([detect/0, init/1, poll/1, terminate/1]).
-export([parse_sysctl_memsize/1, parse_vm_stat/2, build_metrics/2]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    poll_timeout :: pos_integer()
}).

-spec detect() -> boolean().
detect() ->
    case os:type() of
        {unix, darwin} ->
            is_arm64() andalso has_required_commands();
        _ ->
            false
    end.

-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Opts) ->
    PollTimeout = maps:get(poll_timeout_ms, Opts, 3000),
    {ok, #state{poll_timeout = PollTimeout}}.

-spec poll(#state{}) -> {ok, loom_gpu_backend:metrics(), #state{}} | {error, term()}.
poll(#state{poll_timeout = Timeout} = State) ->
    case run_cmd_with_timeout("sysctl -n hw.memsize", Timeout) of
        {ok, SysctlOut} ->
            case parse_sysctl_memsize(SysctlOut) of
                {ok, TotalBytes} ->
                    case run_cmd_with_timeout("vm_stat", Timeout) of
                        {ok, VmStatOut} ->
                            case parse_vm_stat(VmStatOut, TotalBytes) of
                                {ok, UsedGb, TotalGb} ->
                                    Metrics = build_metrics(UsedGb, TotalGb),
                                    {ok, Metrics, State};
                                {error, _} = Err -> Err
                            end;
                        {error, _} = Err -> Err
                    end;
                {error, _} = Err -> Err
            end;
        {error, _} = Err -> Err
    end.

-spec terminate(#state{}) -> ok.
terminate(_State) ->
    ok.

%%--------------------------------------------------------------------
%% Parsing (exported for testing)
%%--------------------------------------------------------------------

-spec parse_sysctl_memsize(string()) ->
    {ok, non_neg_integer()} | {error, term()}.
parse_sysctl_memsize(Output) ->
    Trimmed = string:trim(Output),
    NumStr = case string:split(Trimmed, ":") of
        [_, After] -> string:trim(After);
        [Single]   -> Single
    end,
    case string:to_integer(NumStr) of
        {N, _} when is_integer(N), N > 0 -> {ok, N};
        _ -> {error, {parse_error, {bad_memsize, Output}}}
    end.

-spec parse_vm_stat(string(), non_neg_integer()) ->
    {ok, float(), float()} | {error, term()}.
parse_vm_stat(Output, TotalBytes) when TotalBytes > 0 ->
    Lines = string:split(Output, "\n", all),
    case parse_page_size(Lines) of
        {ok, PageSize} ->
            PageCounts = extract_page_counts(Lines),
            Free = maps:get("Pages free", PageCounts, 0),
            Inactive = maps:get("Pages inactive", PageCounts, 0),
            Speculative = maps:get("Pages speculative", PageCounts, 0),
            %% ASSUMPTION: Available memory = (free + inactive + speculative) pages.
            AvailableBytes = (Free + Inactive + Speculative) * PageSize,
            TotalGb = TotalBytes / (1024 * 1024 * 1024),
            UsedGb = (TotalBytes - AvailableBytes) / (1024 * 1024 * 1024),
            {ok, max(0.0, UsedGb), TotalGb};
        {error, _} = Err ->
            Err
    end;
parse_vm_stat(_Output, _TotalBytes) ->
    {error, {parse_error, invalid_total_bytes}}.

-spec build_metrics(float(), float()) -> loom_gpu_backend:metrics().
build_metrics(UsedGb, TotalGb) ->
    #{
        gpu_util       => -1.0,
        mem_used_gb    => UsedGb,
        mem_total_gb   => TotalGb,
        temperature_c  => -1.0,
        power_w        => -1.0,
        ecc_errors     => -1
    }.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec is_arm64() -> boolean().
is_arm64() ->
    case string:trim(os:cmd("sysctl -n hw.optional.arm64")) of
        "1" -> true;
        _   -> false
    end.

-spec has_required_commands() -> boolean().
has_required_commands() ->
    string:trim(os:cmd("which sysctl")) =/= "" andalso
    string:trim(os:cmd("which vm_stat")) =/= "".

-spec run_cmd_with_timeout(string(), pos_integer()) ->
    {ok, string()} | {error, term()}.
run_cmd_with_timeout(Cmd, Timeout) ->
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
        {error, timeout}
    end.

-spec collect_port_output(port(), binary(), pid(), reference()) -> ok.
collect_port_output(Port, Acc, Parent, Ref) ->
    receive
        {Port, {data, Data}} ->
            collect_port_output(Port, <<Acc/binary, Data/binary>>, Parent, Ref);
        {Port, {exit_status, 0}} ->
            Parent ! {Ref, {ok, Acc}};
        {Port, {exit_status, Code}} ->
            Parent ! {Ref, {error, {exit_code, Code}}}
    end.

-spec parse_page_size([string()]) -> {ok, pos_integer()} | {error, term()}.
parse_page_size([]) ->
    {error, {parse_error, no_page_size_line}};
parse_page_size([Line | Rest]) ->
    case string:find(Line, "page size of") of
        nomatch ->
            parse_page_size(Rest);
        _ ->
            Tokens = string:tokens(Line, " ()"),
            extract_page_size_value(Tokens)
    end.

-spec extract_page_size_value([string()]) ->
    {ok, pos_integer()} | {error, term()}.
extract_page_size_value([]) ->
    {error, {parse_error, page_size_not_found}};
extract_page_size_value(["page", "size", "of", NumStr | _]) ->
    case string:to_integer(NumStr) of
        {N, _} when is_integer(N), N > 0 -> {ok, N};
        _ -> {error, {parse_error, {bad_page_size, NumStr}}}
    end;
extract_page_size_value([_ | Rest]) ->
    extract_page_size_value(Rest).

-spec extract_page_counts([string()]) -> #{string() => non_neg_integer()}.
extract_page_counts(Lines) ->
    lists:foldl(fun(Line, Acc) ->
        case string:split(Line, ":") of
            [Key, ValPart] ->
                TrimKey = string:trim(Key),
                ValStr = string:trim(
                    string:trim(ValPart, both, " \t."),
                    both, " \t"),
                case string:to_integer(ValStr) of
                    {N, _} when is_integer(N) ->
                        maps:put(TrimKey, N, Acc);
                    _ ->
                        Acc
                end;
            _ ->
                Acc
        end
    end, #{}, Lines).
