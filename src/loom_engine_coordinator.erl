%%%-------------------------------------------------------------------
%%% @doc loom_engine_coordinator - gen_statem managing a single
%%% inference engine's lifecycle, request routing, and in-flight tracking.
%%%
%%% States: starting -> ready -> draining -> stopped
%%%
%%% Owns a loom_port subprocess. Tracks in-flight requests via ETS
%%% for lock-free reads by the router and metrics systems. Self-heals
%%% on port crash by notifying callers and spawning a new port.
%%%
%%% ASSUMPTION: The coordinator is the sole owner of its loom_port
%%% instance. No other process sends messages to the port directly.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_engine_coordinator).
-behaviour(gen_statem).

%% Public API
-export([
    start_link/1,
    generate/3,
    shutdown/1,
    stop/1
]).

%% ETS-backed read API (no message passing)
-export([
    get_status/1,
    get_load/1,
    get_info/1
]).

%% ETS table name helpers (exported for routing/testing)
-export([
    reqs_table_name/1,
    meta_table_name/1
]).

%% Config helpers (exported for testing)
-export([
    validate_config/1,
    merge_config/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    starting/3,
    ready/3,
    draining/3,
    stopped/3,
    terminate/3
]).

-include_lib("kernel/include/logger.hrl").

-record(data, {
    engine_id      :: binary(),
    config         :: map(),
    port_pid       :: pid() | undefined,
    port_ref       :: reference() | undefined,
    reqs_table     :: ets:table(),
    meta_table     :: ets:table(),
    max_concurrent :: pos_integer(),
    started_at     :: integer()
}).

%%====================================================================
%% Config validation
%%====================================================================

-spec validate_config(map()) -> ok | {error, term()}.
validate_config(Config) ->
    Required = [engine_id, command, model, backend],
    case check_required(Required, Config) of
        ok -> check_values(Config);
        Error -> Error
    end.

-spec merge_config(map()) -> {ok, map()} | {error, term()}.
merge_config(Config) ->
    case validate_config(Config) of
        ok ->
            Defaults = #{
                args => [],
                startup_timeout_ms => 120000,
                drain_timeout_ms => 30000,
                max_concurrent => 64,
                port_opts => #{}
            },
            {ok, maps:merge(Defaults, Config)};
        Error ->
            Error
    end.

%% @private
-spec check_required([atom()], map()) -> ok | {error, term()}.
check_required([], _Config) -> ok;
check_required([Key | Rest], Config) ->
    case maps:find(Key, Config) of
        {ok, Val} when is_binary(Val), byte_size(Val) =:= 0 ->
            {error, {empty_required, Key}};
        {ok, Val} when is_list(Val), length(Val) =:= 0, Key =:= command ->
            {error, {empty_required, Key}};
        {ok, _} -> check_required(Rest, Config);
        error -> {error, {missing_required, Key}}
    end.

%% @private
-spec check_values(map()) -> ok | {error, term()}.
check_values(Config) ->
    Checks = [
        {startup_timeout_ms, fun(V) -> is_integer(V) andalso V > 0 end},
        {drain_timeout_ms, fun(V) -> is_integer(V) andalso V > 0 end},
        {max_concurrent, fun(V) -> is_integer(V) andalso V > 0 end}
    ],
    check_values_loop(Checks, Config).

%% @private
-spec check_values_loop([{atom(), fun((term()) -> boolean())}], map()) ->
    ok | {error, term()}.
check_values_loop([], _Config) -> ok;
check_values_loop([{Key, Pred} | Rest], Config) ->
    case maps:find(Key, Config) of
        {ok, Val} ->
            case Pred(Val) of
                true -> check_values_loop(Rest, Config);
                false -> {error, {invalid_value, Key, Val}}
            end;
        error ->
            %% ASSUMPTION: Not provided; defaults will be applied by merge_config/1
            check_values_loop(Rest, Config)
    end.

%%====================================================================
%% ETS table name helpers
%%====================================================================

-spec reqs_table_name(binary()) -> atom().
reqs_table_name(EngineId) ->
    %% ASSUMPTION: EngineId contains only alphanumeric chars and underscores.
    binary_to_atom(<<"loom_coord_reqs_", EngineId/binary>>).

-spec meta_table_name(binary()) -> atom().
meta_table_name(EngineId) ->
    %% ASSUMPTION: EngineId contains only alphanumeric chars and underscores.
    binary_to_atom(<<"loom_coord_meta_", EngineId/binary>>).

%%====================================================================
%% Public API (stubs for now)
%%====================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    case merge_config(Config) of
        {ok, Merged} ->
            gen_statem:start_link(?MODULE, Merged, []);
        {error, _} = Error ->
            Error
    end.

-spec generate(pid(), binary(), map()) ->
    {ok, binary()} | {error, not_ready | draining | overloaded | stopped}.
generate(_Pid, _Prompt, _Params) ->
    {error, not_ready}.

-spec shutdown(pid()) -> ok.
shutdown(_Pid) ->
    ok.

-spec stop(pid()) -> ok.
stop(_Pid) ->
    ok.

-spec get_status(binary()) -> starting | ready | draining | stopped.
get_status(EngineId) ->
    MetaTable = meta_table_name(EngineId),
    case ets:lookup(MetaTable, meta) of
        [{meta, Status, _, _, _, _, _}] -> Status;
        [] -> stopped
    end.

-spec get_load(binary()) -> non_neg_integer().
get_load(EngineId) ->
    ReqsTable = reqs_table_name(EngineId),
    ets:info(ReqsTable, size).

-spec get_info(binary()) -> map().
get_info(EngineId) ->
    MetaTable = meta_table_name(EngineId),
    ReqsTable = reqs_table_name(EngineId),
    case ets:lookup(MetaTable, meta) of
        [{meta, Status, EId, Model, Backend, _PortPid, StartedAt}] ->
            #{
                engine_id => EId,
                model => Model,
                backend => Backend,
                status => Status,
                load => ets:info(ReqsTable, size),
                started_at => StartedAt
            };
        [] ->
            #{}
    end.

%%====================================================================
%% gen_statem callbacks
%%====================================================================

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() ->
    [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(atom()).
init(_Config) ->
    {stop, not_implemented}.

-spec starting(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
starting(_EventType, _Event, _Data) ->
    {stop, not_implemented}.

-spec ready(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
ready(_EventType, _Event, _Data) ->
    {stop, not_implemented}.

-spec draining(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
draining(_EventType, _Event, _Data) ->
    {stop, not_implemented}.

-spec stopped(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:event_handler_result(atom()).
stopped(_EventType, _Event, _Data) ->
    {stop, not_implemented}.

-spec terminate(term(), atom(), #data{}) -> any().
terminate(_Reason, _State, _Data) ->
    ok.
