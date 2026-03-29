-module(loom_config).
%% ASSUMPTION: no_underspecs needed because validation helpers use broad
%% specs (validation_detail() union) for API stability across all callers.
-dialyzer(no_underspecs).

-type config_path() :: [atom()].

-type validation_detail() ::
    {empty_engines} |
    {missing_field, atom(), atom()} |
    {duplicate_engine, binary()} |
    {invalid_engine_name, binary()} |
    {unknown_backend, binary(), engine, binary()} |
    {adapter_not_found, string(), engine, binary()} |
    {invalid_type, atom(), expected_list} |
    {invalid_type, atom(), expected_positive_integer}.

-type validation_error() ::
    {config_file, atom(), file:filename()} |
    {json_parse, term()} |
    {validation, validation_detail()}.

-export_type([config_path/0, validation_error/0, validation_detail/0]).

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

%% ASSUMPTION: server_defaults/0 carries only server-level settings.
%% Handler-specific defaults (max_body_size, inactivity_timeout, generate_timeout)
%% live in loom_http_util:default_config/0 to avoid duplicate default sources.
-spec server_defaults() ->
    #{port := pos_integer(), ip := inet:ip_address(), max_connections := pos_integer()}.
server_defaults() ->
    #{port => 8080,
      ip => {0, 0, 0, 0},
      max_connections => 1024}.

-spec port_defaults() ->
    #{max_line_length := pos_integer(), spawn_timeout_ms := pos_integer(),
      heartbeat_timeout_ms := pos_integer(), shutdown_timeout_ms := pos_integer(),
      post_close_timeout_ms := pos_integer()}.
port_defaults() ->
    #{max_line_length => 1048576,
      spawn_timeout_ms => 5000,
      heartbeat_timeout_ms => 15000,
      shutdown_timeout_ms => 10000,
      post_close_timeout_ms => 5000}.

-spec gpu_monitor_defaults() ->
    #{poll_interval_ms := pos_integer(), poll_timeout_ms := pos_integer(),
      backend := atom(), thresholds := #{temperature_c := float(), mem_percent := float()}}.
gpu_monitor_defaults() ->
    #{poll_interval_ms => 5000,
      poll_timeout_ms => 3000,
      backend => auto,
      thresholds => #{temperature_c => 85.0,
                      mem_percent => 95.0}}.

-spec coordinator_defaults() ->
    #{startup_timeout_ms := pos_integer(), drain_timeout_ms := pos_integer(),
      max_concurrent := pos_integer()}.
coordinator_defaults() ->
    #{startup_timeout_ms => 120000,
      drain_timeout_ms => 30000,
      max_concurrent => 64}.

-spec engine_sup_defaults() ->
    #{max_restarts := pos_integer(), max_period := pos_integer()}.
engine_sup_defaults() ->
    #{max_restarts => 5,
      max_period => 60}.

%%% ===================================================================
%%% Public API
%%% ===================================================================

-spec load() -> ok | {error, validation_error()}.
load() ->
    load(?DEFAULT_PATH).

-spec load(file:filename()) -> ok | {error, validation_error()}.
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

-spec resolve_adapter(map()) -> {ok, string()} | {error, {unknown_backend, binary() | undefined}}.
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

%%% ===================================================================
%%% Validation
%%% ===================================================================

-spec validate(map()) -> ok | {error, {validation, validation_detail()}}.
validate(Config) ->
    case validate_engines_present(Config) of
        ok ->
            Engines = maps:get(engines, Config),
            case validate_engines(Engines, []) of
                ok -> validate_defaults(Config);
                Err -> Err
            end;
        Err -> Err
    end.

-spec validate_engines_present(map()) -> ok | {error, {validation, validation_detail()}}.
validate_engines_present(#{engines := Engines}) when is_list(Engines), length(Engines) > 0 -> ok;
validate_engines_present(#{engines := []}) -> {error, {validation, {empty_engines}}};
validate_engines_present(#{engines := _}) -> {error, {validation, {invalid_type, engines, expected_list}}};
validate_engines_present(_) -> {error, {validation, {missing_field, root, engines}}}.

-spec validate_engines(list(map()), [binary()]) -> ok | {error, {validation, validation_detail()}}.
validate_engines([], _Seen) -> ok;
validate_engines([Engine | Rest], Seen) ->
    case validate_single_engine(Engine, Seen) of
        {ok, Name} -> validate_engines(Rest, [Name | Seen]);
        {error, _} = Err -> Err
    end.

-spec validate_single_engine(map(), [binary()]) -> {ok, binary()} | {error, {validation, validation_detail()}}.
validate_single_engine(Engine, Seen) ->
    case validate_required_engine_fields(Engine) of
        {ok, Name} ->
            case lists:member(Name, Seen) of
                true -> {error, {validation, {duplicate_engine, Name}}};
                false ->
                    case validate_engine_name_format(Name) of
                        ok ->
                            case validate_engine_backend(Engine, Name) of
                                ok ->
                                    case validate_adapter_exists(Engine, Name) of
                                        ok -> validate_engine_optional_fields(Engine, Name);
                                        Err -> Err
                                    end;
                                Err -> Err
                            end;
                        Err -> Err
                    end
            end;
        Err -> Err
    end.

-spec validate_required_engine_fields(map()) -> {ok, binary()} | {error, {validation, validation_detail()}}.
validate_required_engine_fields(Engine) ->
    case maps:find(name, Engine) of
        {ok, Name} when is_binary(Name) ->
            case maps:find(backend, Engine) of
                {ok, _} ->
                    case maps:find(model, Engine) of
                        {ok, _} -> {ok, Name};
                        error -> {error, {validation, {missing_field, engine, model}}}
                    end;
                error -> {error, {validation, {missing_field, engine, backend}}}
            end;
        error -> {error, {validation, {missing_field, engine, name}}}
    end.

-spec validate_engine_name_format(binary()) -> ok | {error, {validation, validation_detail()}}.
validate_engine_name_format(Name) ->
    case re:run(Name, <<"^[a-zA-Z0-9._-]+$">>) of
        {match, _} when byte_size(Name) =< 64 -> ok;
        _ -> {error, {validation, {invalid_engine_name, Name}}}
    end.

-spec validate_engine_backend(map(), binary()) -> ok | {error, {validation, validation_detail()}}.
validate_engine_backend(#{adapter_cmd := Cmd}, _Name) when is_binary(Cmd), byte_size(Cmd) > 0 -> ok;
validate_engine_backend(#{backend := Backend}, Name) ->
    case adapter_filename(Backend) of
        {ok, _} -> ok;
        error -> {error, {validation, {unknown_backend, Backend, engine, Name}}}
    end.

-spec validate_adapter_exists(map(), binary()) -> ok | {error, {validation, validation_detail()}}.
validate_adapter_exists(Engine, Name) ->
    case resolve_adapter(Engine) of
        {ok, Path} ->
            case filelib:is_regular(Path) of
                true -> ok;
                false -> {error, {validation, {adapter_not_found, Path, engine, Name}}}
            end;
        {error, _} ->
            %% Already caught by validate_engine_backend
            ok
    end.

-spec validate_engine_optional_fields(map(), binary()) -> {ok, binary()} | {error, {validation, validation_detail()}}.
validate_engine_optional_fields(Engine, Name) ->
    case maps:find(gpu_ids, Engine) of
        {ok, GpuIds} when not is_list(GpuIds) ->
            {error, {validation, {invalid_type, gpu_ids, expected_list}}};
        {ok, GpuIds} ->
            %% ASSUMPTION: GPU IDs are physical CUDA device indices and must
            %% be non-negative integers. Negative or non-integer values would
            %% produce invalid CUDA_VISIBLE_DEVICES strings.
            case lists:all(fun(G) -> is_integer(G) andalso G >= 0 end, GpuIds) of
                true -> {ok, Name};
                false -> {error, {validation, {invalid_gpu_ids, expected_non_neg_integers}}}
            end;
        error -> {ok, Name}
    end.

-spec validate_defaults(map()) -> ok | {error, {validation, validation_detail()}}.
validate_defaults(#{defaults := Defaults}) when is_map(Defaults) ->
    validate_defaults_sections(Defaults);
validate_defaults(_) -> ok.

-spec validate_defaults_sections(map()) -> ok | {error, {validation, validation_detail()}}.
validate_defaults_sections(Defaults) ->
    Sections = [
        {coordinator, [startup_timeout_ms, drain_timeout_ms, max_concurrent]},
        {port, [max_line_length, spawn_timeout_ms, heartbeat_timeout_ms,
                shutdown_timeout_ms, post_close_timeout_ms]},
        {gpu_monitor, [poll_interval_ms, poll_timeout_ms]},
        {engine_sup, [max_restarts, max_period]}
    ],
    validate_sections(Defaults, Sections).

-spec validate_sections(map(), [{atom(), [atom()]}]) -> ok | {error, {validation, validation_detail()}}.
validate_sections(_Defaults, []) -> ok;
validate_sections(Defaults, [{Section, Fields} | Rest]) ->
    case maps:find(Section, Defaults) of
        {ok, SectionMap} when is_map(SectionMap) ->
            case validate_positive_integer_fields(SectionMap, Fields) of
                ok -> validate_sections(Defaults, Rest);
                Err -> Err
            end;
        _ -> validate_sections(Defaults, Rest)
    end.

-spec validate_positive_integer_fields(map(), [atom()]) -> ok | {error, {validation, validation_detail()}}.
validate_positive_integer_fields(_Map, []) -> ok;
validate_positive_integer_fields(Map, [Field | Rest]) ->
    case maps:find(Field, Map) of
        {ok, V} when is_integer(V), V > 0 ->
            validate_positive_integer_fields(Map, Rest);
        {ok, _} ->
            {error, {validation, {invalid_type, Field, expected_positive_integer}}};
        error ->
            validate_positive_integer_fields(Map, Rest)
    end.

%%% ===================================================================
%%% Parsing and storage
%%% ===================================================================

-spec parse_and_store(binary()) -> ok | {error, validation_error()}.
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

-spec store_config(map()) -> ok | {error, {validation, validation_detail()}}.
store_config(RawConfig) ->
    Config = atomize_keys(RawConfig),
    case validate(Config) of
        ok -> do_store(Config);
        {error, _} = Err -> Err
    end.

-spec do_store(map()) -> ok.
do_store(Config) ->
    ensure_table(),
    %% Store full parsed config for get/2
    ets:insert(?TABLE, {{config, parsed}, Config}),
    %% Store server config (merged with defaults)
    ServerSection = maps:get(server, Config, #{}),
    MergedServer = parse_server_ip(deep_merge(server_defaults(), ServerSection)),
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
    %% ASSUMPTION: resolve_adapter/1 is safe here because validation has already
    %% rejected unknown backends without adapter_cmd.
    {ok, AdapterCmd} = resolve_adapter(EngineMap),
    BaseMerged#{
        name => Name,
        backend => Backend,
        model => Model,
        gpu_ids => GpuIds,
        tp_size => TpSize,
        engine_id => Name,
        adapter_cmd => AdapterCmd
    }.

%% ASSUMPTION: If the IP string is invalid, we silently keep the original binary
%% rather than crashing. This lets validation catch it later if needed.
-spec parse_server_ip(map()) -> map().
parse_server_ip(#{ip := Ip} = Server) when is_binary(Ip) ->
    case inet:parse_address(binary_to_list(Ip)) of
        {ok, Addr} -> Server#{ip => Addr};
        {error, _} -> Server
    end;
parse_server_ip(Server) ->
    Server.

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
