%%%-------------------------------------------------------------------
%%% @doc loom_engine_sup - rest_for_one supervisor for a single engine.
%%%
%%% Manages one loom_engine_coordinator and N loom_gpu_monitor children.
%%% Child ordering: coordinator first, then one monitor per GPU.
%%%
%%% rest_for_one semantics:
%%% - Coordinator crash: restarts coordinator + all monitors
%%% - Monitor crash: restarts that monitor + any monitors after it
%%%   in the child list. Coordinator and earlier monitors are unaffected.
%%%
%%% GPU monitors discover the coordinator pid at start time via
%%% start_monitor/2, which reads the owner of the coordinator's
%%% named ETS meta table. We cannot use supervisor:which_children/1
%%% because start_monitor is called during the supervisor's own
%%% child startup sequence, which would deadlock (calling_self).
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
            ?LOG_INFO(#{msg => starting,
                       engine_id => EngineId,
                       gpus => maps:get(gpus, Config, []),
                       max_restarts => maps:get(max_restarts, Config, 5),
                       max_period => maps:get(max_period, Config, 60)}),
            supervisor:start_link({local, Name}, ?MODULE, Config);
        {error, _} = Err ->
            ?LOG_ERROR(#{msg => config_validation_failed, error => Err}),
            Err
    end.

%% @doc Called by the supervisor to start a GPU monitor child.
%% Looks up the coordinator pid via its ETS meta table owner.
%% NOT intended to be called directly — used as the MFA in monitor child specs.
-spec start_monitor(binary(), map()) -> {ok, pid()} | {error, term()}.
start_monitor(EngineId, GpuOpts) ->
    case maps:find(gpu_id, GpuOpts) of
        {ok, GpuId} ->
            start_monitor_with_lookup(EngineId, GpuId, GpuOpts);
        error ->
            ?LOG_ERROR(#{msg => start_monitor_missing_gpu_id,
                       engine_id => EngineId, opts => GpuOpts}),
            {error, {missing_gpu_id, GpuOpts}}
    end.

%% @private
-spec start_monitor_with_lookup(binary(), term(), map()) ->
    {ok, pid()} | {error, term()}.
start_monitor_with_lookup(EngineId, GpuId, GpuOpts) ->
    %% Look up the coordinator pid via its ETS meta table owner.
    %% The process that called ets:new/2 is the table owner — for our
    %% named meta table, that is the coordinator gen_statem.
    %%
    %% ASSUMPTION: The supervisor starts children sequentially in spec-list
    %% order (OTP supervisor behavior). The coordinator is first in the list,
    %% so its init/1 creates the named ETS table before any monitor child's
    %% start function executes.
    %%
    %% We cannot use supervisor:which_children/1 here because this function
    %% is called during the supervisor's own child startup — that would
    %% deadlock (calling_self).
    MetaTable = loom_engine_coordinator:meta_table_name(EngineId),
    OwnerResult = try ets:info(MetaTable, owner) of
        undefined ->
            {error, {table_exists_no_owner, MetaTable}};
        Pid when is_pid(Pid) ->
            {ok, Pid}
    catch
        error:badarg ->
            %% Table does not exist — coordinator hasn't created it yet
            {error, {meta_table_missing, MetaTable}}
    end,
    case OwnerResult of
        {ok, CoordPid} ->
            ?LOG_INFO(#{msg => starting_gpu_monitor,
                       engine_id => EngineId,
                       gpu_id => GpuId,
                       coordinator => CoordPid}),
            loom_gpu_monitor:start_link(GpuOpts#{coordinator => CoordPid});
        {error, Reason} ->
            ?LOG_ERROR(#{msg => coordinator_lookup_failed,
                       engine_id => EngineId,
                       gpu_id => GpuId,
                       reason => Reason}),
            {error, coordinator_not_found}
    end.

%% @doc Derive the supervisor registered name from engine_id.
%% ASSUMPTION: engine_id is validated as [a-zA-Z0-9._-]+ (max 64 bytes)
%% by validate_engine_id/1 in this module before sup_name/1 is called.
%% The derived atom is safe.
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

    ?LOG_INFO(#{msg => building_coordinator_child_spec,
               engine_id => EngineId,
               command => maps:get(command, CoordConfig),
               model => maps:get(model, CoordConfig),
               backend => maps:get(backend, CoordConfig),
               shutdown_ms => CoordShutdown}),

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
    Validators = [
        fun validate_engine_id/1,
        fun validate_adapter/1,
        fun validate_optional_fields/1
    ],
    run_validators(Validators, Config).

-spec run_validators([fun((map()) -> ok | {error, term()})], map()) ->
    ok | {error, term()}.
run_validators([], _Config) -> ok;
run_validators([F | Rest], Config) ->
    case F(Config) of
        ok -> run_validators(Rest, Config);
        {error, _} = Err -> Err
    end.

-spec validate_engine_id(map()) -> ok | {error, term()}.
validate_engine_id(Config) ->
    case maps:find(engine_id, Config) of
        {ok, Id} when is_binary(Id), byte_size(Id) > 0 ->
            %% Enforce same regex as loom_engine_coordinator to ensure
            %% sup_name/1 produces a safe atom BEFORE the coordinator runs.
            case byte_size(Id) > 64 of
                true ->
                    {error, {invalid_engine_id, too_long}};
                false ->
                    case re:run(Id, <<"^[a-zA-Z0-9._-]+$">>) of
                        {match, _} -> ok;
                        nomatch -> {error, {invalid_engine_id, bad_format}}
                    end
            end;
        {ok, _} -> {error, {invalid_engine_id, not_binary}};
        error -> {error, {missing_required, engine_id}}
    end.

-spec validate_adapter(map()) -> ok | {error, term()}.
validate_adapter(Config) ->
    case maps:find(adapter_cmd, Config) of
        {ok, Cmd} when is_list(Cmd), length(Cmd) > 0 ->
            case io_lib:printable_list(Cmd) of
                true -> ok;
                false -> {error, {invalid_adapter_cmd, not_printable_string}}
            end;
        {ok, Cmd} when is_binary(Cmd), byte_size(Cmd) > 0 -> ok;
        {ok, _} -> {error, {invalid_adapter_cmd, empty_or_bad_type}};
        error -> {error, {missing_required, adapter_cmd}}
    end.

-spec validate_optional_fields(map()) -> ok | {error, term()}.
validate_optional_fields(Config) ->
    Gpus = maps:get(gpus, Config, []),
    MaxRestarts = maps:get(max_restarts, Config, 5),
    MaxPeriod = maps:get(max_period, Config, 60),
    DrainTimeout = maps:get(drain_timeout_ms, Config, 30000),
    if
        not is_list(Gpus) ->
            {error, {invalid_gpus, expected_list, Gpus}};
        not (is_integer(MaxRestarts) andalso MaxRestarts >= 0) ->
            {error, {invalid_max_restarts, expected_non_neg_integer, MaxRestarts}};
        not (is_integer(MaxPeriod) andalso MaxPeriod > 0) ->
            {error, {invalid_max_period, expected_pos_integer, MaxPeriod}};
        not (is_integer(DrainTimeout) andalso DrainTimeout > 0) ->
            {error, {invalid_drain_timeout_ms, expected_pos_integer, DrainTimeout}};
        true ->
            ok
    end.

-spec build_coordinator_config(map()) -> map().
build_coordinator_config(Config) ->
    EngineId = maps:get(engine_id, Config),
    ?LOG_INFO(#{msg => mapping_coordinator_config,
               engine_id => EngineId}),
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
        engine_id => maps:get(engine_id, Config),
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
