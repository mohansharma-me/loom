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
%% Public API
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
shutdown(Pid) ->
    gen_statem:cast(Pid, do_shutdown).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:cast(Pid, do_stop).

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
init(Config) ->
    %% MUST trap exits FIRST — loom_port:start_link creates a link and
    %% we need to survive port crashes for self-heal.
    process_flag(trap_exit, true),
    EngineId = maps:get(engine_id, Config),
    MaxConcurrent = maps:get(max_concurrent, Config),
    %% Create named ETS tables for lock-free reads by router/metrics.
    %% ASSUMPTION: Table names are unique per EngineId; if a coordinator
    %% with the same EngineId is already running, this will crash.
    ReqsTable = ets:new(reqs_table_name(EngineId), [
        named_table, set, protected, {read_concurrency, true}
    ]),
    MetaTable = ets:new(meta_table_name(EngineId), [
        named_table, set, protected, {read_concurrency, true}
    ]),
    StartedAt = erlang:system_time(millisecond),
    %% Initialize meta row with status=starting
    ets:insert(MetaTable, {meta, starting, EngineId,
                           maps:get(model, Config),
                           maps:get(backend, Config),
                           undefined, StartedAt}),
    Data = #data{
        engine_id      = EngineId,
        config         = Config,
        port_pid       = undefined,
        port_ref       = undefined,
        reqs_table     = ReqsTable,
        meta_table     = MetaTable,
        max_concurrent = MaxConcurrent,
        started_at     = StartedAt
    },
    {ok, starting, Data}.

-spec starting(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
starting(enter, _OldState, #data{config = Config} = Data) ->
    %% Start loom_port with built options; set startup timeout.
    PortOpts = build_port_opts(Config),
    case loom_port:start_link(PortOpts) of
        {ok, PortPid} ->
            StartupTimeout = maps:get(startup_timeout_ms, Config),
            {keep_state, Data#data{port_pid = PortPid},
             [{state_timeout, StartupTimeout, startup_timeout}]};
        {error, Reason} ->
            ?LOG_ERROR("loom_engine_coordinator ~s: failed to start port: ~p",
                       [Data#data.engine_id, Reason]),
            {next_state, stopped, Data}
    end;
starting(info, {loom_port_ready, PortRef, Model, Backend}, Data) ->
    %% IMPORTANT: Capture the PortRef from loom_port (don't create a new one).
    %% This ref is used to filter stale messages after self-heal.
    update_meta_status(ready, Data),
    ets:update_element(Data#data.meta_table, meta, [
        {4, Model}, {5, Backend}, {6, Data#data.port_pid}
    ]),
    {next_state, ready, Data#data{port_ref = PortRef}};
starting(info, {loom_port_exit, _Ref, ExitCode}, Data) ->
    %% Port died before reaching ready → go to stopped
    NormalizedCode = normalize_exit_code(ExitCode),
    ?LOG_WARNING("loom_engine_coordinator ~s: port exited during startup "
                 "with code ~p", [Data#data.engine_id, NormalizedCode]),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(info, {loom_port_timeout, _Ref}, Data) ->
    %% Heartbeat timeout from loom_port → shutdown port, go to stopped
    ?LOG_WARNING("loom_engine_coordinator ~s: port heartbeat timeout during startup",
                 [Data#data.engine_id]),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(state_timeout, startup_timeout, Data) ->
    %% Startup timeout → shutdown port, go to stopped
    ?LOG_WARNING("loom_engine_coordinator ~s: startup timeout expired",
                 [Data#data.engine_id]),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(info, {generate, _From, _Prompt, _Params}, _Data) ->
    %% Not ready yet — caller will get {error, not_ready} via generate/3 stub
    keep_state_and_data;
starting(info, {'EXIT', _Pid, _Reason}, _Data) ->
    %% Keep state — trap_exit handles linked exits.
    %% loom_port_exit notification handles the actual state transition.
    keep_state_and_data;
starting(cast, do_shutdown, Data) ->
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(cast, do_stop, Data) ->
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(info, {loom_port_error, _Ref, _Error}, _Data) ->
    %% Log and ignore decode errors during startup
    keep_state_and_data;
starting(_EventType, _Event, _Data) ->
    keep_state_and_data.

-spec ready(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
ready(enter, _OldState, _Data) ->
    keep_state_and_data;
ready(cast, do_shutdown, Data) ->
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
ready(cast, do_stop, Data) ->
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
ready(info, {loom_port_exit, _Ref, ExitCode}, Data) ->
    NormalizedCode = normalize_exit_code(ExitCode),
    ?LOG_WARNING("loom_engine_coordinator ~s: port exited in ready state "
                 "with code ~p", [Data#data.engine_id, NormalizedCode]),
    {next_state, stopped, Data#data{port_pid = undefined}};
ready(info, {'EXIT', _Pid, _Reason}, _Data) ->
    keep_state_and_data;
ready(info, {loom_port_msg, _Ref, _Msg}, _Data) ->
    %% TODO: Route messages to callers in Task 4
    keep_state_and_data;
ready(info, {loom_port_error, _Ref, _Error}, _Data) ->
    keep_state_and_data;
ready(info, {loom_port_timeout, _Ref}, Data) ->
    ?LOG_WARNING("loom_engine_coordinator ~s: port heartbeat timeout in ready state",
                 [Data#data.engine_id]),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
ready(_EventType, _Event, _Data) ->
    keep_state_and_data.

-spec draining(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
draining(enter, _OldState, _Data) ->
    %% TODO: Implement drain protocol in Task 5
    keep_state_and_data;
draining(cast, do_stop, Data) ->
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
draining(info, {'EXIT', _Pid, _Reason}, _Data) ->
    keep_state_and_data;
draining(_EventType, _Event, _Data) ->
    keep_state_and_data.

-spec stopped(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
stopped(enter, _OldState, Data) ->
    ?LOG_INFO("loom_engine_coordinator ~s: entering stopped state",
              [Data#data.engine_id]),
    update_meta_status(stopped, Data),
    {stop, normal, Data};
stopped(_EventType, _Event, _Data) ->
    %% Should not be reached since enter stops the process, but required
    %% for completeness.
    keep_state_and_data.

-spec terminate(term(), atom(), #data{}) -> any().
terminate(_Reason, _State, Data) ->
    %% Stop port if alive
    stop_port(Data),
    %% Delete both ETS tables with catch to avoid crashes if already deleted
    catch ets:delete(Data#data.reqs_table),
    catch ets:delete(Data#data.meta_table),
    ok.

%%====================================================================
%% Internal helpers
%%====================================================================

%% @doc Build loom_port options from coordinator config.
%% ASSUMPTION: The coordinator is always the owner of its loom_port instance.
-spec build_port_opts(map()) -> map().
build_port_opts(Config) ->
    BaseOpts = #{
        command => maps:get(command, Config),
        args    => maps:get(args, Config, []),
        owner   => self()
    },
    %% Merge any extra port_opts from the config (e.g., timeouts)
    PortOpts = maps:get(port_opts, Config, #{}),
    maps:merge(BaseOpts, PortOpts).

%% @doc Shutdown the port if it is alive.
-spec stop_port(#data{}) -> ok.
stop_port(#data{port_pid = undefined}) ->
    ok;
stop_port(#data{port_pid = PortPid}) ->
    case is_process_alive(PortPid) of
        true  -> loom_port:shutdown(PortPid);
        false -> ok
    end.

%% @doc Update the status field in the meta ETS table.
-spec update_meta_status(atom(), #data{}) -> true.
update_meta_status(Status, #data{meta_table = MetaTable}) ->
    ets:update_element(MetaTable, meta, {2, Status}).

%% @doc Normalize port exit codes. Raw exit_status from Erlang ports can
%% be OS-dependent; this helper ensures consistent representation.
%% ASSUMPTION: Exit codes are non-negative integers or the atom 'killed'.
-spec normalize_exit_code(term()) -> non_neg_integer() | killed.
normalize_exit_code(killed) -> killed;
normalize_exit_code(Code) when is_integer(Code), Code >= 0 -> Code;
normalize_exit_code(_Other) -> 1.
