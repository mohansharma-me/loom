-module(loom_config).

%% Public API
-export([load/0, load/1]).
-export([get/2, get_engine/1, engine_names/0, get_server/0]).
-export([resolve_adapter/1]).

%% Defaults (exported for testing)
-export([server_defaults/0, port_defaults/0, gpu_monitor_defaults/0,
         coordinator_defaults/0, engine_sup_defaults/0]).

-define(TABLE, loom_config).
-define(DEFAULT_PATH, "config/loom.json").

%%% ===================================================================
%%% Hardcoded defaults
%%% ===================================================================

-spec server_defaults() -> map().
server_defaults() ->
    #{port => 8080,
      ip => {0, 0, 0, 0},
      max_connections => 1024,
      max_body_size => 10485760,
      inactivity_timeout => 60000,
      generate_timeout => 5000}.

-spec port_defaults() -> map().
port_defaults() ->
    #{max_line_length => 1048576,
      spawn_timeout_ms => 5000,
      heartbeat_timeout_ms => 15000,
      shutdown_timeout_ms => 10000,
      post_close_timeout_ms => 5000}.

-spec gpu_monitor_defaults() -> map().
gpu_monitor_defaults() ->
    #{poll_interval_ms => 5000,
      poll_timeout_ms => 3000,
      backend => auto,
      thresholds => #{temperature_c => 85.0,
                      mem_percent => 95.0}}.

-spec coordinator_defaults() -> map().
coordinator_defaults() ->
    #{startup_timeout_ms => 120000,
      drain_timeout_ms => 30000,
      max_concurrent => 64}.

-spec engine_sup_defaults() -> map().
engine_sup_defaults() ->
    #{max_restarts => 5,
      max_period => 60}.

%%% ===================================================================
%%% Public API
%%% ===================================================================

-spec load() -> ok | {error, term()}.
load() ->
    load(?DEFAULT_PATH).

-spec load(file:filename()) -> ok | {error, term()}.
load(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            parse_and_store(Bin);
        {error, enoent} ->
            {error, {config_file, enoent, Path}};
        {error, Reason} ->
            {error, {config_file, Reason, Path}}
    end.

-spec get(list(atom()), term()) -> term().
get(KeyPath, Default) ->
    case ets:info(?TABLE) of
        undefined ->
            Default;
        _ ->
            case ets:lookup(?TABLE, {config, parsed}) of
                [{{config, parsed}, Config}] ->
                    get_nested(KeyPath, Config, Default);
                [] ->
                    Default
            end
    end.

-spec get_engine(binary()) -> {ok, map()} | {error, not_found}.
get_engine(Name) ->
    case ets:info(?TABLE) of
        undefined ->
            {error, not_found};
        _ ->
            case ets:lookup(?TABLE, {engine, Name}) of
                [{{engine, _}, EngineMap}] ->
                    {ok, EngineMap};
                [] ->
                    {error, not_found}
            end
    end.

-spec engine_names() -> [binary()].
engine_names() ->
    case ets:info(?TABLE) of
        undefined ->
            [];
        _ ->
            case ets:lookup(?TABLE, {engine, names}) of
                [{{engine, names}, Names}] -> Names;
                [] -> []
            end
    end.

-spec get_server() -> map().
get_server() ->
    case ets:info(?TABLE) of
        undefined ->
            server_defaults();
        _ ->
            case ets:lookup(?TABLE, {server, config}) of
                [{{server, config}, ServerMap}] -> ServerMap;
                [] -> server_defaults()
            end
    end.

-spec resolve_adapter(map()) -> {ok, string()} | {error, term()}.
resolve_adapter(#{adapter_cmd := Cmd}) when is_binary(Cmd), byte_size(Cmd) > 0 ->
    {ok, binary_to_list(Cmd)};
resolve_adapter(#{adapter_cmd := Cmd}) when is_list(Cmd), length(Cmd) > 0 ->
    {ok, Cmd};
resolve_adapter(#{backend := Backend}) ->
    case adapter_filename(Backend) of
        {ok, Filename} ->
            {ok, filename:join([code:priv_dir(loom), "python", Filename])};
        error ->
            {error, {unknown_backend, Backend}}
    end;
resolve_adapter(_) ->
    {error, {unknown_backend, undefined}}.

%%% ===================================================================
%%% Internal functions
%%% ===================================================================

-spec adapter_filename(binary()) -> {ok, string()} | error.
adapter_filename(<<"vllm">>) -> {ok, "loom_adapter.py"};
adapter_filename(<<"mlx">>) -> {ok, "loom_adapter_mlx.py"};
adapter_filename(<<"tensorrt">>) -> {ok, "loom_adapter_trt.py"};
adapter_filename(<<"mock">>) -> {ok, "loom_adapter_mock.py"};
adapter_filename(_) -> error.

-spec parse_and_store(binary()) -> ok | {error, term()}.
parse_and_store(Bin) ->
    try json:decode(Bin) of
        Parsed when is_map(Parsed) ->
            store_config(Parsed);
        Other ->
            {error, {json_parse, {expected_object, Other}}}
    catch
        error:Reason ->
            {error, {json_parse, Reason}}
    end.

-spec store_config(map()) -> ok.
store_config(RawConfig) ->
    Config = atomize_keys(RawConfig),
    ensure_table(),
    %% Store full parsed config for get/2
    ets:insert(?TABLE, {{config, parsed}, Config}),
    %% Store server config (merged with defaults)
    ServerSection = maps:get(server, Config, #{}),
    MergedServer = deep_merge(server_defaults(), ServerSection),
    ets:insert(?TABLE, {{server, config}, MergedServer}),
    %% Store per-engine configs
    Engines = maps:get(engines, Config, []),
    DefaultsSection = maps:get(defaults, Config, #{}),
    Names = store_engines(Engines, DefaultsSection),
    ets:insert(?TABLE, {{engine, names}, Names}),
    ok.

-spec ensure_table() -> ok.
ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ?TABLE = ets:new(?TABLE, [set, named_table, public,
                                      {read_concurrency, true}]),
            ok;
        _ ->
            ets:delete_all_objects(?TABLE),
            ok
    end.

-spec store_engines(list(map()), map()) -> [binary()].
store_engines(Engines, DefaultsSection) ->
    lists:map(fun(Engine) ->
        Name = maps:get(name, Engine),
        Merged = merge_engine(Engine, DefaultsSection),
        ets:insert(?TABLE, {{engine, Name}, Merged}),
        Name
    end, Engines).

-spec merge_engine(map(), map()) -> map().
merge_engine(EngineMap, DefaultsSection) ->
    %% ASSUMPTION: Merge priority is per-engine > defaults section > hardcoded defaults.
    %% Sub-sections: port, gpu_monitor, coordinator, engine_sup.
    Sections = [
        {port, fun port_defaults/0},
        {gpu_monitor, fun gpu_monitor_defaults/0},
        {coordinator, fun coordinator_defaults/0},
        {engine_sup, fun engine_sup_defaults/0}
    ],
    BaseMerged = lists:foldl(fun({Key, DefaultsFun}, Acc) ->
        Hardcoded = DefaultsFun(),
        FromDefaults = maps:get(Key, DefaultsSection, #{}),
        FromEngine = maps:get(Key, EngineMap, #{}),
        %% deep_merge(hardcoded, deep_merge(defaults, per_engine))
        Merged = deep_merge(Hardcoded, deep_merge(FromDefaults, FromEngine)),
        maps:put(Key, Merged, Acc)
    end, #{}, Sections),
    %% Carry over top-level engine fields (name, backend, model, gpu_ids, tp_size)
    GpuIds = maps:get(gpu_ids, EngineMap, []),
    TpSize = maps:get(tp_size, EngineMap, 1),
    Name = maps:get(name, EngineMap),
    Backend = maps:get(backend, EngineMap),
    Model = maps:get(model, EngineMap),
    BaseMerged#{
        name => Name,
        backend => Backend,
        model => Model,
        gpu_ids => GpuIds,
        tp_size => TpSize
    }.

-spec deep_merge(map(), map()) -> map().
deep_merge(Base, Override) when is_map(Base), is_map(Override) ->
    maps:fold(fun(K, V, Acc) ->
        case maps:find(K, Acc) of
            {ok, ExistingV} when is_map(ExistingV), is_map(V) ->
                maps:put(K, deep_merge(ExistingV, V), Acc);
            _ ->
                maps:put(K, V, Acc)
        end
    end, Base, Override);
deep_merge(_Base, Override) ->
    Override.

-spec atomize_keys(term()) -> term().
atomize_keys(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        Key = case K of
            B when is_binary(B) -> binary_to_atom(B, utf8);
            A when is_atom(A) -> A
        end,
        maps:put(Key, atomize_keys(V), Acc)
    end, #{}, Map);
atomize_keys(List) when is_list(List) ->
    lists:map(fun atomize_keys/1, List);
atomize_keys(Other) ->
    Other.

-spec get_nested(list(atom()), map(), term()) -> term().
get_nested([], Value, _Default) ->
    Value;
get_nested([Key | Rest], Map, Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> get_nested(Rest, Value, Default);
        error -> Default
    end;
get_nested(_Keys, _NotAMap, Default) ->
    Default.
