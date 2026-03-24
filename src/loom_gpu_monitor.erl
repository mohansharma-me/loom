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

-record(data, {
    gpu_id             :: term(),
    backend_mod        :: module(),
    backend_state      :: term(),
    poll_interval_ms   :: pos_integer(),
    poll_timeout_ms    :: pos_integer(),
    timer_ref          :: reference() | undefined,
    latest_metrics     :: loom_gpu_backend:metrics() | undefined,
    thresholds         :: #{atom() => number()},
    breached           :: #{atom() => boolean()},
    consecutive_errors :: non_neg_integer(),
    coordinator_pid    :: pid() | undefined
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
    PollInterval = maps:get(poll_interval_ms, Opts, 5000),
    PollTimeout = maps:get(poll_timeout_ms, Opts, 3000),
    Coordinator = maps:get(coordinator, Opts, undefined),
    AllowMock = maps:get(allow_mock_backend, Opts, true),
    BackendAtom = maps:get(backend, Opts, auto),
    UserThresholds = maps:get(thresholds, Opts, #{}),

    %% Validate poll_timeout < poll_interval
    case PollTimeout >= PollInterval of
        true ->
            ?LOG_ERROR("loom_gpu_monitor: poll_timeout_ms (~b) must be less "
                       "than poll_interval_ms (~b)",
                       [PollTimeout, PollInterval]),
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
handle_info(_Info, Data) ->
    {noreply, Data}.

-spec terminate(term(), #data{}) -> ok.
terminate(Reason, #data{gpu_id = GpuId, backend_mod = Mod,
                         backend_state = BState, timer_ref = TRef}) ->
    ?LOG_INFO("loom_gpu_monitor: gpu_id=~p stopping, reason=~p",
              [GpuId, Reason]),
    cancel_timer(TRef),
    Mod:terminate(BState),
    ok.

%%====================================================================
%% Internal — init
%%====================================================================

-spec init_with_backend(atom(), boolean(), map()) -> {ok, #data{}} | {stop, term()}.
init_with_backend(auto, AllowMock, Opts) ->
    GpuId = maps:get(gpu_id, Opts),
    ?LOG_INFO("loom_gpu_monitor: auto-detecting backend for gpu_id=~p", [GpuId]),
    case resolve_backend(AllowMock) of
        {ok, Mod} ->
            ?LOG_INFO("loom_gpu_monitor: selected backend=~p for gpu_id=~p",
                      [Mod, GpuId]),
            init_backend(Mod, Opts);
        {error, Reason} ->
            ?LOG_ERROR("loom_gpu_monitor: no backend detected for gpu_id=~p",
                       [GpuId]),
            {stop, Reason}
    end;
init_with_backend(BackendAtom, _AllowMock, Opts) ->
    Mod = backend_module(BackendAtom),
    GpuId = maps:get(gpu_id, Opts),
    ?LOG_INFO("loom_gpu_monitor: using explicitly configured backend=~p "
              "for gpu_id=~p", [Mod, GpuId]),
    init_backend(Mod, Opts).

-spec init_backend(module(), map()) -> {ok, #data{}} | {stop, term()}.
init_backend(Mod, Opts) ->
    GpuId = maps:get(gpu_id, Opts),
    PollInterval = maps:get(poll_interval_ms, Opts),
    PollTimeout = maps:get(poll_timeout_ms, Opts),
    Coordinator = maps:get(coordinator, Opts),
    UserThresholds = maps:get(thresholds, Opts),

    case Mod:init(Opts) of
        {ok, BState} ->
            ?LOG_INFO("loom_gpu_monitor: backend init succeeded for gpu_id=~p, "
                      "scheduling first poll", [GpuId]),
            Thresholds = merge_thresholds(Mod, UserThresholds),
            ?LOG_INFO("loom_gpu_monitor: starting gpu_id=~p backend=~p "
                      "poll_interval=~bms poll_timeout=~bms thresholds=~p",
                      [GpuId, Mod, PollInterval, PollTimeout, Thresholds]),
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
                coordinator_pid    = Coordinator
            },
            {ok, schedule_poll(Data)};
        {error, Reason} ->
            ?LOG_ERROR("loom_gpu_monitor: backend init failed for gpu_id=~p "
                       "backend=~p reason=~p", [GpuId, Mod, Reason]),
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
            ?LOG_WARNING("loom_gpu_monitor: gpu_id=~p poll failed — "
                         "reason=~p, consecutive_errors=~b, serving stale metrics",
                         [GpuId, Reason, Errors]),
            Data1 = Data#data{consecutive_errors = Errors},
            Data2 = maybe_alert_poll_failure(Data1),
            {{error, Reason}, Data2}
    end.

-spec maybe_log_recovery(#data{}, #data{}) -> #data{}.
maybe_log_recovery(#data{consecutive_errors = Old},
                   #data{gpu_id = GpuId} = New) when Old >= 3 ->
    ?LOG_INFO("loom_gpu_monitor: gpu_id=~p poll recovered after ~b "
              "consecutive failures, resetting error counter",
              [GpuId, Old]),
    New;
maybe_log_recovery(_Old, New) ->
    New.

%% ASSUMPTION: Alert fires exactly once at 3 consecutive failures, not
%% on every subsequent failure. For sustained outages the coordinator
%% already knows. Recovery is logged separately in maybe_log_recovery/2.
-spec maybe_alert_poll_failure(#data{}) -> #data{}.
maybe_alert_poll_failure(#data{consecutive_errors = 3, gpu_id = GpuId} = Data) ->
    ?LOG_ERROR("loom_gpu_monitor: gpu_id=~p poll failed 3 consecutive "
               "times, alerting coordinator", [GpuId]),
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
                    Unit = threshold_unit(ThresholdKey),
                    ?LOG_INFO("loom_gpu_monitor: gpu_id=~p threshold BREACHED — "
                              "~s=~.1f~s (threshold=~.1f~s), alerting coordinator",
                              [GpuId, AlertType, Value, Unit, Limit, Unit]),
                    send_alert(GpuId, AlertType, Value, Limit, Data),
                    Data#data{breached = maps:put(AlertType, true, Breached)};
                {true, false} ->
                    Unit = threshold_unit(ThresholdKey),
                    ?LOG_INFO("loom_gpu_monitor: gpu_id=~p threshold CLEARED — "
                              "~s=~.1f~s (threshold=~.1f~s)",
                              [GpuId, AlertType, Value, Unit, Limit, Unit]),
                    Data#data{breached = maps:put(AlertType, false, Breached)};
                _ ->
                    Data
            end;
        error ->
            Data
    end.

-spec threshold_unit(atom()) -> string().
threshold_unit(temperature_c) -> "C";
threshold_unit(mem_percent)   -> "%".

%%====================================================================
%% Internal — alerts and logging
%%====================================================================

-spec send_alert(term(), atom(), number(), number(), #data{}) -> ok.
send_alert(GpuId, AlertType, _Value, _Threshold,
           #data{coordinator_pid = undefined}) ->
    ?LOG_WARNING("loom_gpu_monitor: gpu_id=~p ~p breached but no "
                 "coordinator configured, alert not sent",
                 [GpuId, AlertType]),
    ok;
send_alert(GpuId, AlertType, Value, Threshold,
           #data{coordinator_pid = Pid}) ->
    case is_process_alive(Pid) of
        true ->
            Pid ! {gpu_alert, GpuId, AlertType, Value, Threshold},
            ok;
        false ->
            ?LOG_WARNING("loom_gpu_monitor: gpu_id=~p coordinator ~p "
                         "is dead, alert not sent", [GpuId, Pid]),
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
    ?LOG_INFO("loom_gpu_monitor: gpu_id=~p poll ok — "
              "gpu_util=~s mem=~.1f/~.1fGB(~.1f%) "
              "temp=~s power=~s ecc=~s",
              [GpuId,
               format_metric_float(GpuUtil, "%"),
               MemUsed, MemTotal, MemPct,
               format_metric_float(Temp, "C"),
               format_metric_float(Power, "W"),
               format_metric_int(Ecc)]),
    ok.

-spec format_metric_float(float(), string()) -> io_lib:chars().
format_metric_float(V, _Unit) when V < 0 -> "n/a";
format_metric_float(V, Unit) ->
    io_lib:format("~.1f~s", [V, Unit]).

-spec format_metric_int(integer()) -> io_lib:chars().
format_metric_int(V) when V < 0 -> "n/a";
format_metric_int(V) ->
    integer_to_list(V).

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
            ?LOG_INFO("loom_gpu_monitor: no real backend detected, "
                      "falling back to mock (allow_mock_backend=true)"),
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
            ?LOG_INFO("loom_gpu_monitor: trying ~s backend — not detected",
                      [Name]),
            try_backends(Rest)
    end.

-spec backend_module(atom()) -> module().
backend_module(nvidia) -> loom_gpu_backend_nvidia;
backend_module(apple)  -> loom_gpu_backend_apple;
backend_module(mock)   -> loom_gpu_backend_mock.

-spec merge_thresholds(module(), map()) -> #{atom() => number()}.
merge_thresholds(loom_gpu_backend_nvidia, User) ->
    maps:merge(#{temperature_c => 85.0, mem_percent => 95.0}, User);
merge_thresholds(loom_gpu_backend_apple, User) ->
    maps:merge(#{mem_percent => 90.0}, User);
merge_thresholds(loom_gpu_backend_mock, User) ->
    User;
merge_thresholds(_, User) ->
    User.

%%====================================================================
%% Internal — timer
%%====================================================================

-spec schedule_poll(#data{}) -> #data{}.
schedule_poll(#data{poll_interval_ms = Interval} = Data) ->
    TRef = erlang:send_after(Interval, self(), poll),
    Data#data{timer_ref = TRef}.

-spec cancel_timer(reference() | undefined) -> ok.
cancel_timer(undefined) -> ok;
cancel_timer(TRef) ->
    erlang:cancel_timer(TRef),
    ok.
