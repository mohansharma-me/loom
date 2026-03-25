%%%-------------------------------------------------------------------
%%% @doc loom_engine_sup - rest_for_one supervisor for a single engine.
%%%
%%% Manages one loom_engine_coordinator and N loom_gpu_monitor children.
%%% Child ordering: coordinator first, then one monitor per GPU.
%%%
%%% rest_for_one semantics:
%%% - Coordinator crash: restarts coordinator + all monitors
%%% - Monitor crash: restarts only that monitor
%%%
%%% GPU monitors discover the coordinator pid at start time via
%%% start_monitor/2, which looks up the coordinator from this
%%% supervisor's children list.
%%%
%%% ASSUMPTION: engine_id uniqueness is enforced by the caller
%%% (future loom_engine_pool_sup). Duplicate engine_ids will crash
%%% on supervisor name registration.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_engine_sup).
-behaviour(supervisor).

-export([start_link/1, start_monitor/2, sup_name/1]).
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

%%====================================================================
%% API
%%====================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    case validate_config(Config) of
        ok ->
            EngineId = maps:get(engine_id, Config),
            Name = sup_name(EngineId),
            ?LOG_INFO("loom_engine_sup: starting engine_id=~s "
                      "gpus=~p max_restarts=~b/~bs",
                      [EngineId,
                       maps:get(gpus, Config, []),
                       maps:get(max_restarts, Config, 5),
                       maps:get(max_period, Config, 60)]),
            supervisor:start_link({local, Name}, ?MODULE, Config);
        {error, _} = Err ->
            ?LOG_ERROR("loom_engine_sup: config validation failed: ~p", [Err]),
            Err
    end.

%% @doc Called by the supervisor to start a GPU monitor child.
%% Looks up the coordinator pid from the supervisor's children list.
%% NOT intended to be called directly — used as the MFA in monitor child specs.
-spec start_monitor(binary(), map()) -> {ok, pid()} | {error, term()}.
start_monitor(EngineId, GpuOpts) ->
    GpuId = maps:get(gpu_id, GpuOpts),
    %% Look up the coordinator pid via its ETS meta table owner.
    %% ASSUMPTION: The coordinator child starts before any monitor children
    %% (rest_for_one ordering). Its init/1 creates the named ETS table
    %% synchronously, so by the time we start monitors the table exists
    %% and ets:info(Table, owner) returns the coordinator pid.
    %%
    %% We cannot use supervisor:which_children/1 here because this function
    %% is called during the supervisor's own init — that would deadlock
    %% (calling_self).
    MetaTable = loom_engine_coordinator:meta_table_name(EngineId),
    case catch ets:info(MetaTable, owner) of
        Pid when is_pid(Pid) ->
            ?LOG_INFO("loom_engine_sup: starting gpu_monitor engine_id=~s "
                      "gpu_id=~p coordinator=~p",
                      [EngineId, GpuId, Pid]),
            loom_gpu_monitor:start_link(GpuOpts#{coordinator => Pid});
        _ ->
            ?LOG_ERROR("loom_engine_sup: coordinator not found for "
                       "engine_id=~s gpu_id=~p (meta table ~p missing or no owner)",
                       [EngineId, GpuId, MetaTable]),
            {error, coordinator_not_found}
    end.

%% @doc Derive the supervisor registered name from engine_id.
%% ASSUMPTION: engine_id is pre-validated as [a-zA-Z0-9_]+ (max 64 bytes)
%% by loom_engine_coordinator:validate_config/1. The derived atom is safe.
-spec sup_name(binary()) -> atom().
sup_name(EngineId) ->
    binary_to_atom(<<"loom_engine_sup_", EngineId/binary>>).

%%====================================================================
%% supervisor callback
%%====================================================================

-spec init(map()) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init(Config) ->
    EngineId = maps:get(engine_id, Config),
    Gpus = maps:get(gpus, Config, []),

    CoordConfig = build_coordinator_config(Config),
    DrainTimeout = maps:get(drain_timeout_ms, Config, 30000),
    CoordShutdown = DrainTimeout + 5000,

    ?LOG_INFO("loom_engine_sup: building coordinator child spec "
              "engine_id=~s command=~s model=~s backend=~s shutdown=~bms",
              [EngineId,
               maps:get(command, CoordConfig),
               maps:get(model, CoordConfig),
               maps:get(backend, CoordConfig),
               CoordShutdown]),

    CoordChild = #{
        id => coordinator,
        start => {loom_engine_coordinator, start_link, [CoordConfig]},
        restart => permanent,
        shutdown => CoordShutdown,
        type => worker
    },

    MonitorChildren = [monitor_child_spec(EngineId, GpuId, Config)
                       || GpuId <- Gpus],

    MaxRestarts = maps:get(max_restarts, Config, 5),
    MaxPeriod = maps:get(max_period, Config, 60),

    SupFlags = #{
        strategy => rest_for_one,
        intensity => MaxRestarts,
        period => MaxPeriod
    },

    {ok, {SupFlags, [CoordChild | MonitorChildren]}}.

%%====================================================================
%% Internal
%%====================================================================

-spec validate_config(map()) -> ok | {error, term()}.
validate_config(Config) ->
    case maps:find(engine_id, Config) of
        {ok, Id} when is_binary(Id), byte_size(Id) > 0 -> validate_adapter(Config);
        {ok, _} -> {error, {invalid_engine_id, not_binary}};
        error -> {error, {missing_required, engine_id}}
    end.

-spec validate_adapter(map()) -> ok | {error, term()}.
validate_adapter(Config) ->
    case maps:find(adapter_cmd, Config) of
        {ok, Cmd} when is_list(Cmd), length(Cmd) > 0 -> ok;
        {ok, Cmd} when is_binary(Cmd), byte_size(Cmd) > 0 -> ok;
        {ok, _} -> {error, {invalid_adapter_cmd, empty_or_bad_type}};
        error -> {error, {missing_required, adapter_cmd}}
    end.

-spec build_coordinator_config(map()) -> map().
build_coordinator_config(Config) ->
    EngineId = maps:get(engine_id, Config),
    ?LOG_INFO("loom_engine_sup: mapping config for engine_id=~s: "
              "adapter_cmd->command, adapter_args->args, "
              "gpu_poll_interval->poll_interval_ms",
              [EngineId]),
    Base = #{
        engine_id => EngineId,
        command => maps:get(adapter_cmd, Config),
        args => maps:get(adapter_args, Config, []),
        model => maps:get(model, Config, <<>>),
        backend => maps:get(backend, Config, <<>>)
    },
    %% Forward optional coordinator-specific keys
    OptionalKeys = [startup_timeout_ms, drain_timeout_ms, max_concurrent, port_opts],
    lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Config) of
            {ok, Val} -> maps:put(Key, Val, Acc);
            error -> Acc
        end
    end, Base, OptionalKeys).

-spec monitor_child_spec(binary(), term(), map()) -> supervisor:child_spec().
monitor_child_spec(EngineId, GpuId, Config) ->
    GpuOpts = build_monitor_opts(GpuId, Config),
    #{
        id => {gpu_monitor, GpuId},
        start => {loom_engine_sup, start_monitor, [EngineId, GpuOpts]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.

-spec build_monitor_opts(term(), map()) -> map().
build_monitor_opts(GpuId, Config) ->
    Base = #{
        gpu_id => GpuId,
        poll_interval_ms => maps:get(gpu_poll_interval, Config, 5000),
        allow_mock_backend => maps:get(allow_mock_backend, Config, false)
    },
    %% Forward optional monitor-specific keys.
    %% NOTE: We do NOT forward the top-level 'backend' key here because the
    %% engine config stores it as a binary (e.g., <<"mock">>) for the
    %% coordinator, while loom_gpu_monitor expects an atom (e.g., mock).
    %% The monitor uses auto-detection by default (with allow_mock_backend).
    OptionalKeys = [poll_timeout_ms, thresholds],
    lists:foldl(fun(Key, Acc) ->
        case maps:find(Key, Config) of
            {ok, Val} -> maps:put(Key, Val, Acc);
            error -> Acc
        end
    end, Base, OptionalKeys).
