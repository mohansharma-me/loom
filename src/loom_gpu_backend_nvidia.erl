%%%-------------------------------------------------------------------
%%% @doc loom_gpu_backend_nvidia - NVIDIA GPU monitoring via nvidia-smi.
%%%
%%% Polls GPU metrics using nvidia-smi CLI with CSV output format.
%%% Works on Linux and Windows (nvidia-smi ships with NVIDIA drivers
%%% on both platforms).
%%%
%%% ASSUMPTION: nvidia-smi CSV output format (--format=csv,noheader,
%%% nounits) is stable across driver versions. NVIDIA documents this
%%% as a supported query interface.
%%%
%%% ASSUMPTION: nvidia-smi reports memory in MiB. We convert to GiB
%%% (divide by 1024) for the normalized metrics map. Field names use
%%% "gb" for brevity but the unit is technically GiB.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_gpu_backend_nvidia).
-behaviour(loom_gpu_backend).

-export([detect/0, init/1, poll/1, terminate/1, default_thresholds/0]).
-export([parse_nvidia_csv/1]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    gpu_index     :: non_neg_integer(),
    nvidia_smi    :: string(),
    poll_timeout  :: pos_integer()
}).

-spec detect() -> boolean().
detect() ->
    Cmd = case os:type() of
        {win32, _} -> "where nvidia-smi";
        _          -> "which nvidia-smi"
    end,
    case string:trim(os:cmd(Cmd)) of
        "" -> false;
        _Path -> true
    end.

-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Opts) ->
    GpuIndex = maps:get(gpu_index, Opts, 0),
    NvidiaSmi = maps:get(nvidia_smi_path, Opts, "nvidia-smi"),
    PollTimeout = maps:get(poll_timeout_ms, Opts, 3000),
    %% ASSUMPTION: Validate GPU index exists by running a test query.
    %% Uses loom_cmd:run_with_timeout/2 to avoid hanging the supervisor
    %% if nvidia-smi is stuck (e.g., during GPU driver reset).
    TestCmd = NvidiaSmi ++ " --query-gpu=name --id=" ++
              integer_to_list(GpuIndex) ++ " --format=csv,noheader",
    case loom_cmd:run_with_timeout(TestCmd, PollTimeout) of
        {ok, Result} ->
            Trimmed = string:trim(Result),
            case Trimmed of
                "" ->
                    {error, {gpu_index_not_found, GpuIndex}};
                _ ->
                    case string:find(Trimmed, "error") of
                        nomatch ->
                            {ok, #state{
                                gpu_index    = GpuIndex,
                                nvidia_smi   = NvidiaSmi,
                                poll_timeout = PollTimeout
                            }};
                        _ ->
                            {error, {gpu_index_not_found, GpuIndex}}
                    end
            end;
        {error, timeout} ->
            ?LOG_ERROR(#{msg => nvidia_smi_init_timeout, gpu_index => GpuIndex}),
            {error, {nvidia_smi_timeout, GpuIndex}};
        {error, Reason} ->
            {error, {nvidia_smi_failed, Reason}}
    end.

-spec poll(#state{}) -> {ok, loom_gpu_backend:metrics(), #state{}} | {error, term()}.
poll(#state{gpu_index = Idx, nvidia_smi = Smi, poll_timeout = Timeout} = State) ->
    Cmd = Smi ++ " --query-gpu=utilization.gpu,memory.used,memory.total,"
          "temperature.gpu,power.draw,ecc.errors.corrected.aggregate.total"
          " --id=" ++ integer_to_list(Idx) ++
          " --format=csv,noheader,nounits",
    case loom_cmd:run_with_timeout(Cmd, Timeout) of
        {ok, Output} ->
            case parse_nvidia_csv(string:trim(Output)) of
                {ok, Metrics} ->
                    {ok, Metrics, State};
                {error, _} = Err ->
                    Err
            end;
        {error, _} = Err ->
            Err
    end.

-spec terminate(#state{}) -> ok.
terminate(_State) ->
    ok.

-spec default_thresholds() -> #{atom() => number()}.
default_thresholds() ->
    #{temperature_c => 85.0, mem_percent => 95.0}.

%%--------------------------------------------------------------------
%% Parsing
%%--------------------------------------------------------------------

-spec parse_nvidia_csv(string()) -> {ok, loom_gpu_backend:metrics()} | {error, term()}.
parse_nvidia_csv(Line) ->
    Fields = string:tokens(Line, ","),
    case length(Fields) of
        6 ->
            Trimmed = [string:trim(F) || F <- Fields],
            try
                [GpuUtilS, MemUsedS, MemTotalS, TempS, PowerS, EccS] = Trimmed,
                Metrics = #{
                    gpu_util       => parse_float_field(GpuUtilS),
                    mem_used_gb    => mib_to_gb(parse_float_field(MemUsedS)),
                    mem_total_gb   => mib_to_gb(parse_float_field(MemTotalS)),
                    temperature_c  => parse_float_field(TempS),
                    power_w        => parse_float_field(PowerS),
                    ecc_errors     => parse_int_field(EccS)
                },
                {ok, Metrics}
            catch
                error:Reason:_Stacktrace ->
                    {error, {parse_error, Reason}}
            end;
        N ->
            {error, {parse_error, {expected_6_fields, got, N}}}
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec parse_float_field(string()) -> float().
parse_float_field("[Not Supported]") -> -1.0;
parse_float_field(S) ->
    case string:to_float(S) of
        {F, _} when is_float(F) -> F;
        {error, no_float} ->
            case string:to_integer(S) of
                {I, _} when is_integer(I) -> float(I);
                _ -> error({bad_float, S})
            end
    end.

-spec parse_int_field(string()) -> integer().
parse_int_field("[Not Supported]") -> -1;
parse_int_field(S) ->
    case string:to_integer(S) of
        {I, _} when is_integer(I) -> I;
        _ -> error({bad_int, S})
    end.

-spec mib_to_gb(float()) -> float().
mib_to_gb(-1.0) -> -1.0;
mib_to_gb(Mib) -> Mib / 1024.0.
