-module(loom_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-include_lib("kernel/include/logger.hrl").

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    %% ASSUMPTION: For Phase 0, engine supervisors are direct children of loom_sup.
    %% KNOWLEDGE.md shows an intermediate loom_engine_pool_sup for dynamic engine
    %% management. That will be introduced in Phase 1 when we need dynamic_supervisor
    %% semantics for adding/removing engines at runtime.
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    HttpChild = #{
        id => loom_http_server,
        start => {loom_http_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    EngineChildren = build_engine_children(),

    {ok, {SupFlags, [HttpChild | EngineChildren]}}.

%%====================================================================
%% Internal
%%====================================================================

-spec build_engine_children() -> [supervisor:child_spec()].
build_engine_children() ->
    Names = loom_config:engine_names(),
    lists:map(fun(Name) ->
        case loom_config:get_engine(Name) of
            {ok, EngineMap} ->
                ChildConfig = flatten_engine_config(EngineMap),
                SupName = loom_engine_sup:sup_name(Name),
                #{
                    id => SupName,
                    start => {loom_engine_sup, start_link, [ChildConfig]},
                    restart => permanent,
                    shutdown => infinity,
                    type => supervisor
                };
            {error, not_found} ->
                ?LOG_ERROR(#{msg => engine_config_not_found, engine_name => Name}),
                error({engine_config_not_found, Name})
        end
    end, Names).

%% @doc Flatten loom_config engine map (nested sub-maps) into the flat
%% format loom_engine_sup:start_link/1 expects.
%%
%% ASSUMPTION: Known backends (vllm, mlx, tensorrt, mock) are Python scripts
%% that need python3 as the executable. Custom adapter_cmd values are assumed
%% to be directly executable binaries (not wrapped with python3).
-spec flatten_engine_config(map()) -> map().
flatten_engine_config(EngineMap) ->
    RequiredKeys = [adapter_cmd, backend, engine_id, model],
    case [K || K <- RequiredKeys, not maps:is_key(K, EngineMap)] of
        [] -> ok;
        Missing ->
            EngineName = maps:get(name, EngineMap, <<"unknown">>),
            error({missing_engine_config_keys, Missing, EngineName})
    end,

    CoordConfig = maps:get(coordinator, EngineMap, #{}),
    EngSupConfig = maps:get(engine_sup, EngineMap, #{}),
    GpuMonConfig = maps:get(gpu_monitor, EngineMap, #{}),
    PortConfig = maps:get(port, EngineMap, #{}),

    AdapterPath = maps:get(adapter_cmd, EngineMap),
    Backend = maps:get(backend, EngineMap),
    {Cmd, Args} = adapter_cmd_and_args(AdapterPath, Backend),

    Base = #{
        engine_id => maps:get(engine_id, EngineMap),
        adapter_cmd => Cmd,
        adapter_args => Args,
        model => maps:get(model, EngineMap),
        backend => Backend,
        gpus => maps:get(gpu_ids, EngineMap, []),
        %% Coordinator settings (flattened)
        startup_timeout_ms => maps:get(startup_timeout_ms, CoordConfig, 120000),
        drain_timeout_ms => maps:get(drain_timeout_ms, CoordConfig, 30000),
        max_concurrent => maps:get(max_concurrent, CoordConfig, 64),
        %% Engine sup settings (flattened)
        max_restarts => maps:get(max_restarts, EngSupConfig, 5),
        max_period => maps:get(max_period, EngSupConfig, 60),
        %% GPU monitor settings (flattened)
        gpu_poll_interval => maps:get(poll_interval_ms, GpuMonConfig, 5000),
        allow_mock_backend => Backend =:= <<"mock">>,
        %% Port opts as sub-map
        port_opts => PortConfig
    },
    %% Forward optional gpu_monitor fields if present
    OptionalGpuMon = [{poll_timeout_ms, poll_timeout_ms}, {thresholds, thresholds}],
    lists:foldl(fun({SrcKey, DstKey}, Acc) ->
        case maps:find(SrcKey, GpuMonConfig) of
            {ok, Val} -> maps:put(DstKey, Val, Acc);
            error -> Acc
        end
    end, Base, OptionalGpuMon).

%% @doc Determine the executable and args for launching an adapter.
%% Known Python backends need python3 as the executable; the script is an arg.
%% Custom adapter_cmd (non-Python backends) is used directly as the command.
-spec adapter_cmd_and_args(string(), binary()) -> {string(), [string()]}.
adapter_cmd_and_args(AdapterPath, Backend) when
        Backend =:= <<"vllm">>;
        Backend =:= <<"mlx">>;
        Backend =:= <<"tensorrt">>;
        Backend =:= <<"mock">> ->
    case os:find_executable("python3") of
        false ->
            ?LOG_ERROR(#{msg => python3_not_found,
                         adapter_path => AdapterPath,
                         backend => Backend,
                         hint => "Install python3 or use a custom adapter_cmd binary"}),
            error({python3_not_found, AdapterPath});
        PythonCmd ->
            {PythonCmd, [AdapterPath]}
    end;
adapter_cmd_and_args(AdapterPath, _CustomBackend) ->
    %% Non-Python adapter (custom binary) — use directly
    {AdapterPath, []}.
