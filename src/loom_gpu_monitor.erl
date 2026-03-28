%%%-------------------------------------------------------------------
%%% @doc loom_gpu_monitor - GenServer for polling GPU health metrics.
%%%
%%% Backend-agnostic: uses a loom_gpu_backend implementation to poll
%%% metrics at a configurable interval. Caches the latest reading,
%%% checks thresholds on transitions, and alerts a coordinator.
%%%
%%% Auto-detection cascade: nvidia -> apple -> mock (if allowed).
%%% Explicit backend selection bypasses detection entirely.
%%%
%%% ASSUMPTION: The poll timer uses erlang:send_after/3 so that a
%%% slow poll does not cause overlapping polls. The next timer is
%%% scheduled AFTER the current poll completes.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_gpu_monitor).
-behaviour(gen_server).

%% API
-export([start_link/1, get_status/1, force_poll/1, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

%% Known threshold keys that check_thresholds/2 understands.
-define(KNOWN_THRESHOLD_KEYS, [temperature_c, mem_percent]).

-record(data, {
    gpu_id             :: loom_gpu_backend:gpu_id(),
    backend_mod        :: module(),
    %% INVARIANT: backend_state was produced by backend_mod:init/1
    backend_state      :: term(),
    poll_interval_ms   :: pos_integer(),
    poll_timeout_ms    :: pos_integer(),
    timer_ref          :: reference() | undefined,
    latest_metrics     :: loom_gpu_backend:metrics() | undefined,
    thresholds         :: #{atom() => number()},
    breached           :: #{atom() => boolean()},
    consecutive_errors :: non_neg_integer(),
    coordinator_pid    :: pid() | undefined,
    coordinator_mon    :: reference() | undefined
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec get_status(pid()) -> {ok, loom_gpu_backend:metrics()} | {error, no_reading}.
get_status(Pid) ->
    gen_server:call(Pid, get_status).

-spec force_poll(pid()) -> {ok, loom_gpu_backend:metrics()} | {error, term()}.
force_poll(Pid) ->
    gen_server:call(Pid, force_poll).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

%%====================================================================
%% gen_server callbacks
%%====================================================================

-spec init(map()) -> {ok, #data{}} | {stop, term()}.
init(Opts) ->
    GpuId = maps:get(gpu_id, Opts),
    EngineId = maps:get(engine_id, Opts, undefined),
    logger:update_process_metadata(#{engine_id => EngineId, gpu_id => GpuId}),
    PollInterval = maps:get(poll_interval_ms, Opts, 5000),
    PollTimeout = maps:get(poll_timeout_ms, Opts, 3000),
    Coordinator = maps:get(coordinator, Opts, undefined),
    AllowMock = maps:get(allow_mock_backend, Opts, false),
    BackendAtom = maps:get(backend, Opts, auto),
    UserThresholds = maps:get(thresholds, Opts, #{}),

    %% Validate poll_timeout < poll_interval
    case PollTimeout >= PollInterval of
        true ->
            ?LOG_ERROR(#{msg => invalid_config_poll_timeout_gte_interval,
                       poll_timeout_ms => PollTimeout,
                       poll_interval_ms => PollInterval}),
            {stop, {invalid_config, poll_timeout_gte_interval}};
        false ->
            init_with_backend(BackendAtom, AllowMock, Opts#{
                gpu_id => GpuId,
                poll_interval_ms => PollInterval,
                poll_timeout_ms => PollTimeout,
                coordinator => Coordinator,
                thresholds => UserThresholds
            })
    end.

-spec handle_call(term(), gen_server:from(), #data{}) ->
    {reply, term(), #data{}}.
handle_call(get_status, _From, #data{latest_metrics = undefined} = Data) ->
    {reply, {error, no_reading}, Data};
handle_call(get_status, _From, #data{latest_metrics = Metrics} = Data) ->
    {reply, {ok, Metrics}, Data};
handle_call(force_poll, _From, Data) ->
    {Result, Data1} = do_poll(Data),
    Reply = case Result of
        {ok, Metrics} -> {ok, Metrics};
        {error, _} = Err -> Err
    end,
    {reply, Reply, Data1};
handle_call(_Request, _From, Data) ->
    {reply, {error, unknown_call}, Data}.

-spec handle_cast(term(), #data{}) -> {noreply, #data{}}.
handle_cast(_Msg, Data) ->
    {noreply, Data}.

-spec handle_info(term(), #data{}) -> {noreply, #data{}}.
handle_info(poll, Data) ->
    {_Result, Data1} = do_poll(Data),
    Data2 = schedule_poll(Data1),
    {noreply, Data2};
handle_info({'DOWN', MonRef, process, Pid, Reason},
            #data{coordinator_mon = MonRef, coordinator_pid = Pid,
                  gpu_id = GpuId} = Data) ->
    ?LOG_WARNING(#{msg => coordinator_died,
                   gpu_id => GpuId,
                   coordinator => Pid,
                   reason => Reason}),
    {noreply, Data#data{coordinator_pid = undefined,
                        coordinator_mon = undefined}};
handle_info(_Info, Data) ->
    {noreply, Data}.

-spec terminate(term(), #data{}) -> ok.
terminate(Reason, #data{gpu_id = GpuId, backend_mod = Mod,
                         backend_state = BState, timer_ref = TRef}) ->
    ?LOG_INFO(#{msg => stopping, gpu_id => GpuId, reason => Reason}),
    cancel_timer(TRef),
    try Mod:terminate(BState)
    catch
        Class:Error:Stacktrace ->
            ?LOG_ERROR(#{msg => backend_terminate_crashed,
                       gpu_id => GpuId,
                       class => Class,
                       error => Error,
                       stacktrace => Stacktrace})
    end,
    ok.

%%====================================================================
%% Internal — init
%%====================================================================

-spec init_with_backend(atom(), boolean(), map()) -> {ok, #data{}} | {stop, term()}.
init_with_backend(auto, AllowMock, Opts) ->
    GpuId = maps:get(gpu_id, Opts),
    ?LOG_INFO(#{msg => auto_detecting_backend, gpu_id => GpuId}),
    case resolve_backend(AllowMock) of
        {ok, Mod} ->
            ?LOG_INFO(#{msg => backend_selected, backend => Mod, gpu_id => GpuId}),
            init_backend(Mod, Opts);
        {error, Reason} ->
            ?LOG_ERROR(#{msg => no_backend_detected, gpu_id => GpuId}),
            {stop, Reason}
    end;
init_with_backend(BackendAtom, _AllowMock, Opts) ->
    case backend_module(BackendAtom) of
        {ok, Mod} ->
            GpuId = maps:get(gpu_id, Opts),
            ?LOG_INFO(#{msg => using_explicit_backend, backend => Mod, gpu_id => GpuId}),
            init_backend(Mod, Opts);
        {error, _} = Err ->
            ?LOG_ERROR(#{msg => unknown_backend,
                       backend => BackendAtom,
                       valid_backends => [nvidia, apple, mock]}),
            {stop, Err}
    end.

-spec init_backend(module(), map()) -> {ok, #data{}} | {stop, term()}.
init_backend(Mod, Opts) ->
    GpuId = maps:get(gpu_id, Opts),
    PollInterval = maps:get(poll_interval_ms, Opts),
    PollTimeout = maps:get(poll_timeout_ms, Opts),
    Coordinator = maps:get(coordinator, Opts),
    UserThresholds = maps:get(thresholds, Opts),

    %% Warn about unrecognized threshold keys
    warn_unknown_threshold_keys(GpuId, UserThresholds),

    case Mod:init(Opts) of
        {ok, BState} ->
            ?LOG_INFO(#{msg => backend_init_succeeded, gpu_id => GpuId}),
            Thresholds = maps:merge(Mod:default_thresholds(), UserThresholds),
            ?LOG_INFO(#{msg => starting_monitor,
                       gpu_id => GpuId,
                       backend => Mod,
                       poll_interval_ms => PollInterval,
                       poll_timeout_ms => PollTimeout,
                       thresholds => Thresholds}),
            CoordMon = case Coordinator of
                undefined -> undefined;
                Pid -> erlang:monitor(process, Pid)
            end,
            Data = #data{
                gpu_id             = GpuId,
                backend_mod        = Mod,
                backend_state      = BState,
                poll_interval_ms   = PollInterval,
                poll_timeout_ms    = PollTimeout,
                timer_ref          = undefined,
                latest_metrics     = undefined,
                thresholds         = Thresholds,
                breached           = #{},
                consecutive_errors = 0,
                coordinator_pid    = Coordinator,
                coordinator_mon    = CoordMon
            },
            {ok, schedule_poll(Data)};
        {error, Reason} ->
            ?LOG_ERROR(#{msg => backend_init_failed,
                       gpu_id => GpuId,
                       backend => Mod,
                       reason => Reason}),
            {stop, {backend_init_failed, Reason}}
    end.

%%====================================================================
%% Internal — polling
%%====================================================================

-spec do_poll(#data{}) -> {{ok, loom_gpu_backend:metrics()} | {error, term()}, #data{}}.
do_poll(#data{gpu_id = GpuId, backend_mod = Mod,
              backend_state = BState} = Data) ->
    case Mod:poll(BState) of
        {ok, Metrics, NewBState} ->
            log_metrics(GpuId, Metrics),
            %% ASSUMPTION: engine_id is available in process metadata set during init/1.
            %% We use the gpu_id from the record which is always available.
            telemetry:execute([loom, gpu, poll],
                #{gpu_util => maps:get(gpu_util, Metrics),
                  mem_used_gb => maps:get(mem_used_gb, Metrics),
                  mem_total_gb => maps:get(mem_total_gb, Metrics),
                  temperature_c => maps:get(temperature_c, Metrics)},
                #{engine_id => get_engine_id_from_metadata(), gpu_id => GpuId}),
            Data1 = Data#data{
                backend_state      = NewBState,
                latest_metrics     = Metrics,
                consecutive_errors = 0
            },
            Data2 = maybe_log_recovery(Data, Data1),
            Data3 = check_thresholds(Metrics, Data2),
            {{ok, Metrics}, Data3};
        {error, Reason} ->
            Errors = Data#data.consecutive_errors + 1,
            ?LOG_WARNING(#{msg => poll_failed,
                         gpu_id => GpuId,
                         reason => Reason,
                         consecutive_errors => Errors}),
            Data1 = Data#data{consecutive_errors = Errors},
            Data2 = maybe_alert_poll_failure(Data1),
            {{error, Reason}, Data2}
    end.

-spec maybe_log_recovery(#data{}, #data{}) -> #data{}.
maybe_log_recovery(#data{consecutive_errors = Old},
                   #data{gpu_id = GpuId} = New) when Old >= 3 ->
    ?LOG_INFO(#{msg => poll_recovered,
               gpu_id => GpuId,
               previous_consecutive_errors => Old}),
    New;
maybe_log_recovery(_Old, New) ->
    New.

%% ASSUMPTION: Alert fires exactly once at 3 consecutive failures, not
%% on every subsequent failure. For sustained outages the coordinator
%% already knows. Recovery is logged separately in maybe_log_recovery/2.
-spec maybe_alert_poll_failure(#data{}) -> #data{}.
maybe_alert_poll_failure(#data{consecutive_errors = 3, gpu_id = GpuId} = Data) ->
    ?LOG_ERROR(#{msg => poll_failed_consecutive,
               gpu_id => GpuId,
               consecutive_errors => 3}),
    send_alert(GpuId, poll_failure, 3, 3, Data),
    Data;
maybe_alert_poll_failure(Data) ->
    Data.

%%====================================================================
%% Internal — thresholds
%%====================================================================

-spec check_thresholds(loom_gpu_backend:metrics(), #data{}) -> #data{}.
check_thresholds(Metrics, Data) ->
    Data1 = check_threshold(temperature, maps:get(temperature_c, Metrics),
                            temperature_c, Data),
    MemPercent = case maps:get(mem_total_gb, Metrics) of
        Total when Total > 0.0 ->
            maps:get(mem_used_gb, Metrics) / Total * 100.0;
        _ -> 0.0
    end,
    check_threshold(memory, MemPercent, mem_percent, Data1).

-spec check_threshold(atom(), number(), atom(), #data{}) -> #data{}.
check_threshold(_AlertType, Value, _ThresholdKey, Data) when Value < 0 ->
    %% Unavailable metric, skip threshold check
    Data;
check_threshold(AlertType, Value, ThresholdKey,
                #data{gpu_id = GpuId, thresholds = Thresholds,
                      breached = Breached} = Data) ->
    case maps:find(ThresholdKey, Thresholds) of
        {ok, Limit} ->
            WasBreached = maps:get(AlertType, Breached, false),
            IsBreached = Value > Limit,
            case {WasBreached, IsBreached} of
                {false, true} ->
                    ?LOG_INFO(#{msg => threshold_breached,
                                gpu_id => GpuId,
                                alert_type => AlertType,
                                value => Value,
                                threshold => Limit,
                                threshold_key => ThresholdKey}),
                    send_alert(GpuId, AlertType, Value, Limit, Data),
                    Data#data{breached = maps:put(AlertType, true, Breached)};
                {true, false} ->
                    ?LOG_INFO(#{msg => threshold_cleared,
                                gpu_id => GpuId,
                                alert_type => AlertType,
                                value => Value,
                                threshold => Limit,
                                threshold_key => ThresholdKey}),
                    Data#data{breached = maps:put(AlertType, false, Breached)};
                _ ->
                    Data
            end;
        error ->
            Data
    end.

-spec warn_unknown_threshold_keys(loom_gpu_backend:gpu_id(), map()) -> ok.
warn_unknown_threshold_keys(GpuId, UserThresholds) ->
    Unknown = maps:keys(UserThresholds) -- ?KNOWN_THRESHOLD_KEYS,
    case Unknown of
        [] -> ok;
        Keys ->
            ?LOG_WARNING(#{msg => unknown_threshold_keys,
                         gpu_id => GpuId,
                         unknown_keys => Keys,
                         known_keys => ?KNOWN_THRESHOLD_KEYS}),
            ok
    end.

%%====================================================================
%% Internal — alerts and logging
%%====================================================================

-spec send_alert(term(), atom(), number(), number(), #data{}) -> ok.
send_alert(GpuId, AlertType, _Value, _Threshold,
           #data{coordinator_pid = undefined}) ->
    ?LOG_WARNING(#{msg => alert_no_coordinator,
                   gpu_id => GpuId,
                   alert_type => AlertType}),
    ok;
send_alert(GpuId, AlertType, Value, Threshold,
           #data{coordinator_pid = Pid}) ->
    case is_process_alive(Pid) of
        true ->
            Pid ! {gpu_alert, GpuId, AlertType, Value, Threshold},
            ok;
        false ->
            ?LOG_WARNING(#{msg => alert_coordinator_dead,
                         gpu_id => GpuId,
                         coordinator => Pid}),
            ok
    end.

-spec log_metrics(term(), loom_gpu_backend:metrics()) -> ok.
log_metrics(GpuId, Metrics) ->
    #{gpu_util := GpuUtil, mem_used_gb := MemUsed, mem_total_gb := MemTotal,
      temperature_c := Temp, power_w := Power, ecc_errors := Ecc} = Metrics,
    MemPct = case MemTotal > 0.0 of
        true -> MemUsed / MemTotal * 100.0;
        false -> 0.0
    end,
    ?LOG_INFO(#{msg => poll_ok,
               gpu_id => GpuId,
               gpu_util => GpuUtil,
               mem_used_gb => MemUsed,
               mem_total_gb => MemTotal,
               mem_percent => MemPct,
               temperature_c => Temp,
               power_w => Power,
               ecc_errors => Ecc}),
    ok.

%%====================================================================
%% Internal — backend resolution
%%====================================================================

-spec resolve_backend(boolean()) ->
    {ok, module()} | {error, no_gpu_backend_detected}.
resolve_backend(AllowMock) ->
    Backends = [
        {loom_gpu_backend_nvidia, "nvidia"},
        {loom_gpu_backend_apple, "apple"}
    ],
    case try_backends(Backends) of
        {ok, Mod} -> {ok, Mod};
        false when AllowMock ->
            ?LOG_WARNING(#{msg => falling_back_to_mock_backend,
                         detail => "GPU metrics are SIMULATED. Set allow_mock_backend => false to fail instead."}),
            {ok, loom_gpu_backend_mock};
        false ->
            {error, no_gpu_backend_detected}
    end.

-spec try_backends([{module(), string()}]) -> {ok, module()} | false.
try_backends([]) -> false;
try_backends([{Mod, Name} | Rest]) ->
    case Mod:detect() of
        true ->
            {ok, Mod};
        false ->
            ?LOG_INFO(#{msg => backend_not_detected, backend => Name}),
            try_backends(Rest)
    end.

-spec backend_module(atom()) -> {ok, module()} | {error, term()}.
backend_module(nvidia) -> {ok, loom_gpu_backend_nvidia};
backend_module(apple)  -> {ok, loom_gpu_backend_apple};
backend_module(mock)   -> {ok, loom_gpu_backend_mock};
backend_module(Other)  -> {error, {unknown_backend, Other, [nvidia, apple, mock]}}.

%%====================================================================
%% Internal — timer
%%====================================================================

-spec schedule_poll(#data{}) -> #data{}.
schedule_poll(#data{poll_interval_ms = Interval} = Data) ->
    TRef = erlang:send_after(Interval, self(), poll),
    Data#data{timer_ref = TRef}.

-spec get_engine_id_from_metadata() -> term().
get_engine_id_from_metadata() ->
    case logger:get_process_metadata() of
        #{engine_id := EngineId} -> EngineId;
        _ -> undefined
    end.

-spec cancel_timer(reference() | undefined) -> ok.
cancel_timer(undefined) -> ok;
cancel_timer(TRef) ->
    _ = erlang:cancel_timer(TRef),
    ok.
