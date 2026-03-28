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
    generate/4,
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

%% Request ID generation (exported for testing)
-export([generate_request_id/0]).

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
        {ok, Val} when Key =:= engine_id, is_binary(Val) ->
            %% ASSUMPTION: engine_id is used to construct ETS table names via
            %% binary_to_atom/1. Restricting to [a-zA-Z0-9._-] and max 64 bytes
            %% prevents atom table pollution from untrusted input.
            case byte_size(Val) > 64 of
                true ->
                    {error, {invalid_engine_id, too_long}};
                false ->
                    case re:run(Val, <<"^[a-zA-Z0-9._-]+$">>) of
                        {match, _} -> check_required(Rest, Config);
                        nomatch -> {error, {invalid_engine_id, bad_format}}
                    end
            end;
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
generate(Pid, Prompt, Params) ->
    gen_statem:call(Pid, {generate, Prompt, Params}).

-spec generate(pid(), binary(), map(), timeout()) ->
    {ok, binary()} | {error, not_ready | draining | overloaded | stopped}.
generate(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {generate, Prompt, Params}, Timeout).

-spec shutdown(pid()) -> ok.
shutdown(Pid) ->
    gen_statem:cast(Pid, do_shutdown).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:cast(Pid, do_stop).

-spec get_status(binary()) -> starting | ready | draining | stopped.
get_status(EngineId) ->
    MetaTable = meta_table_name(EngineId),
    try ets:lookup(MetaTable, meta) of
        [{meta, Status, _, _, _, _, _}] -> Status;
        [] -> stopped
    catch
        error:badarg ->
            %% ASSUMPTION: Table was deleted because coordinator terminated.
            stopped
    end.

-spec get_load(binary()) -> non_neg_integer().
get_load(EngineId) ->
    ReqsTable = reqs_table_name(EngineId),
    try ets:info(ReqsTable, size) of
        undefined -> 0;
        Size -> Size
    catch
        error:badarg -> 0
    end.

-spec get_info(binary()) -> map().
get_info(EngineId) ->
    MetaTable = meta_table_name(EngineId),
    ReqsTable = reqs_table_name(EngineId),
    try ets:lookup(MetaTable, meta) of
        [{meta, Status, EId, Model, Backend, _PortPid, StartedAt}] ->
            Load = try ets:info(ReqsTable, size) of
                       undefined -> 0;
                       S -> S
                   catch error:badarg -> 0
                   end,
            #{engine_id => EId, model => Model, backend => Backend,
              status => Status, load => Load, started_at => StartedAt};
        [] ->
            #{}
    catch
        error:badarg -> #{}
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
    logger:set_process_metadata(#{engine_id => EngineId}),
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
    %% Store coordinator pid for lock-free lookup by HTTP handlers.
    %% ASSUMPTION: self() here is the coordinator gen_statem process.
    ets:insert(MetaTable, {coordinator_pid, self()}),
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
starting(enter, _OldState, #data{config = Config, port_pid = ExistingPortPid} = Data) ->
    %% If port_pid is already set (self-heal path), skip port startup.
    %% ASSUMPTION: When self-heal sets port_pid before transitioning to starting,
    %% the port is already started and we only need to set the startup timeout.
    case ExistingPortPid =/= undefined andalso is_process_alive(ExistingPortPid) of
        true ->
            StartupTimeout = maps:get(startup_timeout_ms, Config),
            {keep_state, Data,
             [{state_timeout, StartupTimeout, startup_timeout}]};
        false ->
            %% Normal path: start loom_port with built options; set startup timeout.
            PortOpts = build_port_opts(Config),
            case loom_port:start_link(PortOpts) of
                {ok, PortPid} ->
                    StartupTimeout = maps:get(startup_timeout_ms, Config),
                    {keep_state, Data#data{port_pid = PortPid},
                     [{state_timeout, StartupTimeout, startup_timeout}]};
                {error, Reason} ->
                    ?LOG_ERROR(#{msg => port_start_failed,
                               engine_id => Data#data.engine_id,
                               reason => Reason}),
                    {next_state, stopped, Data}
            end
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
    ?LOG_WARNING(#{msg => port_exited_during_startup,
                   engine_id => Data#data.engine_id,
                   exit_code => NormalizedCode}),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(info, {loom_port_timeout, _Ref}, Data) ->
    %% Heartbeat timeout from loom_port → shutdown port, go to stopped
    ?LOG_WARNING(#{msg => port_heartbeat_timeout_during_startup,
                   engine_id => Data#data.engine_id}),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(state_timeout, startup_timeout, Data) ->
    %% Startup timeout → shutdown port, go to stopped
    ?LOG_WARNING(#{msg => startup_timeout_expired,
                   engine_id => Data#data.engine_id}),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting({call, From}, {generate, _Prompt, _Params}, _Data) ->
    %% Not ready yet — reply with error
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
starting(info, {'EXIT', PortPid, _Reason}, #data{port_pid = PortPid} = Data) ->
    %% Port process died during startup. loom_port_exit may not arrive
    %% (e.g., if killed with exit(kill)). Transition to stopped.
    ?LOG_WARNING(#{msg => port_process_exited_during_startup,
                   engine_id => Data#data.engine_id}),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(info, {'EXIT', _Pid, _Reason}, _Data) ->
    %% EXIT from other linked processes — ignore.
    keep_state_and_data;
starting(cast, do_shutdown, Data) ->
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(cast, do_stop, Data) ->
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(info, {loom_port_error, _Ref, Error}, #data{engine_id = EngineId}) ->
    ?LOG_WARNING(#{msg => port_error_during_startup,
                   engine_id => EngineId,
                   error => Error}),
    keep_state_and_data;
starting({call, From}, Msg, #data{engine_id = EngineId}) ->
    ?LOG_WARNING(#{msg => unexpected_call_in_starting,
                   engine_id => EngineId,
                   call => Msg}),
    {keep_state_and_data, [{reply, From, {error, unknown_call}}]};
starting(EventType, Event, #data{engine_id = EngineId}) ->
    ?LOG_WARNING(#{msg => unexpected_event_in_starting,
                   engine_id => EngineId,
                   event_type => EventType,
                   event => Event}),
    keep_state_and_data.

-spec ready(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
ready(enter, _OldState, _Data) ->
    keep_state_and_data;

%% --- generate request acceptance ---
ready({call, From}, {generate, Prompt, Params},
      #data{reqs_table = ReqsTable, max_concurrent = MaxConcurrent,
            port_pid = PortPid, port_ref = PortRef, engine_id = EngineId}) ->
    case ets:info(ReqsTable, size) < MaxConcurrent of
        false ->
            {keep_state_and_data, [{reply, From, {error, overloaded}}]};
        true ->
            RequestId = generate_request_id(),
            {CallerPid, _Tag} = From,
            MonRef = erlang:monitor(process, CallerPid),
            %% Send generate command to the port BEFORE inserting into ETS.
            %% If the send fails, we clean up the monitor and avoid leaking
            %% an ETS entry that would never be resolved.
            case loom_port:send(PortPid, {generate, RequestId, Prompt, Params}) of
                ok ->
                    ets:insert(ReqsTable, {RequestId, CallerPid, MonRef, PortRef}),
                    {keep_state_and_data, [{reply, From, {ok, RequestId}}]};
                {error, SendErr} ->
                    erlang:demonitor(MonRef, [flush]),
                    ?LOG_WARNING(#{msg => generate_send_failed,
                                 engine_id => EngineId,
                                 error => SendErr}),
                    {keep_state_and_data, [{reply, From, {error, not_ready}}]}
            end
    end;

%% --- Token routing (matching current PortRef) ---
ready(info, {loom_port_msg, PortRef, {token, Id, _TokenId, Text, Finished}},
      #data{port_ref = PortRef, reqs_table = ReqsTable} = _Data) ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, _MonRef, _}] ->
            CallerPid ! {loom_token, Id, Text, Finished},
            keep_state_and_data;
        [] ->
            %% Unknown request ID — request may have been cancelled
            keep_state_and_data
    end;

%% --- Done handling (matching current PortRef) ---
ready(info, {loom_port_msg, PortRef, {done, Id, TokensGenerated, TimeMs}},
      #data{port_ref = PortRef, reqs_table = ReqsTable} = _Data) ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, MonRef, _}] ->
            CallerPid ! {loom_done, Id, #{tokens => TokensGenerated, time_ms => TimeMs}},
            erlang:demonitor(MonRef, [flush]),
            ets:delete(ReqsTable, Id);
        [] ->
            ok
    end,
    keep_state_and_data;

%% --- Error from port for a specific request (matching current PortRef) ---
ready(info, {loom_port_msg, PortRef, {error, Id, Code, Message}},
      #data{port_ref = PortRef, reqs_table = ReqsTable} = _Data) when Id =/= undefined ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, MonRef, _}] ->
            CallerPid ! {loom_error, Id, Code, Message},
            erlang:demonitor(MonRef, [flush]),
            ets:delete(ReqsTable, Id);
        [] ->
            ok
    end,
    keep_state_and_data;

%% --- GPU alert logging ---
ready(info, {loom_port_msg, PortRef, {health_response, _Status, GpuUtil, MemUsed, MemTotal}},
      #data{port_ref = PortRef, engine_id = EngineId} = _Data) ->
    ?LOG_DEBUG(#{msg => gpu_health_response,
               engine_id => EngineId,
               gpu_util => GpuUtil,
               mem_used_gb => MemUsed,
               mem_total_gb => MemTotal}),
    keep_state_and_data;

%% --- Other port messages with matching PortRef (log and ignore) ---
ready(info, {loom_port_msg, PortRef, _Msg}, #data{port_ref = PortRef} = _Data) ->
    keep_state_and_data;

%% --- Stale port messages (mismatched PortRef — silently drop) ---
ready(info, {loom_port_msg, _StaleRef, _Msg}, _Data) ->
    keep_state_and_data;

%% --- Port error (decode errors etc, matching current PortRef) ---
ready(info, {loom_port_error, PortRef, Error},
      #data{port_ref = PortRef, engine_id = EngineId} = _Data) ->
    ?LOG_WARNING(#{msg => port_error_in_ready,
                   engine_id => EngineId,
                   error => Error}),
    keep_state_and_data;

%% --- Stale port error (mismatched ref — silently drop) ---
ready(info, {loom_port_error, _StaleRef, _Error}, _Data) ->
    keep_state_and_data;

%% --- Self-heal on port crash ---
ready(info, {loom_port_exit, _Ref, ExitCode},
      #data{reqs_table = ReqsTable, config = Config, engine_id = EngineId} = Data) ->
    NormalizedCode = normalize_exit_code(ExitCode),
    NormalizedBin = normalize_exit_code_binary(NormalizedCode),
    ?LOG_WARNING(#{msg => port_crashed_self_healing,
                   engine_id => EngineId,
                   exit_code => NormalizedCode}),
    %% Notify all in-flight callers of the crash
    notify_all_callers_error(ReqsTable, <<"engine_crashed">>, NormalizedBin),
    %% Clear all in-flight requests
    ets:delete_all_objects(ReqsTable),
    %% Start a new port for self-heal
    PortOpts = build_port_opts(Config),
    case loom_port:start_link(PortOpts) of
        {ok, NewPortPid} ->
            update_meta_status(starting, Data),
            {next_state, starting,
             Data#data{port_pid = NewPortPid, port_ref = undefined}};
        {error, Reason} ->
            ?LOG_ERROR(#{msg => self_heal_port_start_failed,
                       engine_id => EngineId,
                       reason => Reason}),
            {next_state, stopped, Data#data{port_pid = undefined, port_ref = undefined}}
    end;

%% --- Port heartbeat timeout ---
ready(info, {loom_port_timeout, _Ref}, #data{reqs_table = ReqsTable} = Data) ->
    ?LOG_WARNING(#{msg => port_heartbeat_timeout_in_ready,
                   engine_id => Data#data.engine_id}),
    %% Notify all in-flight callers
    notify_all_callers_error(ReqsTable, <<"engine_timeout">>, <<"heartbeat_timeout">>),
    ets:delete_all_objects(ReqsTable),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};

%% --- Caller death (DOWN monitor) ---
ready(info, {'DOWN', MonRef, process, CallerPid, _Reason},
      #data{reqs_table = ReqsTable, port_pid = PortPid,
            engine_id = EngineId} = _Data) ->
    %% Find the request for this caller via match_object
    case ets:match_object(ReqsTable, {'_', CallerPid, MonRef, '_'}) of
        [{RequestId, _CallerPid, _MonRef, _PortRef} | _] ->
            %% Cancel the in-flight request on the port
            try loom_port:send(PortPid, {cancel, RequestId}) of
                ok -> ok;
                {error, SendErr} ->
                    ?LOG_DEBUG(#{msg => cancel_send_failed,
                                 engine_id => EngineId,
                                 request_id => RequestId,
                                 error => SendErr})
            catch
                _:_ ->
                    ?LOG_DEBUG(#{msg => cancel_send_crashed,
                                 engine_id => EngineId,
                                 request_id => RequestId})
            end,
            ets:delete(ReqsTable, RequestId);
        [] ->
            %% Already cleaned up
            ok
    end,
    keep_state_and_data;

%% --- EXIT from port process ---
%% When loom_port is killed (e.g., exit(Pid, kill)), it cannot send
%% loom_port_exit because terminate/3 is not called for untrappable signals.
%% We must self-heal directly from the EXIT signal.
%% ASSUMPTION: If the port process exits, loom_port_exit may or may not follow.
%% Handling EXIT here is safe even if loom_port_exit also arrives, because
%% transitioning to starting clears port_pid, making the stale loom_port_exit
%% a no-match on PortPid.
ready(info, {'EXIT', PortPid, Reason},
      #data{port_pid = PortPid, reqs_table = ReqsTable, config = Config,
            engine_id = EngineId} = Data) ->
    NormalizedCode = normalize_exit_code(Reason),
    NormalizedBin = normalize_exit_code_binary(NormalizedCode),
    ?LOG_WARNING(#{msg => port_process_exited_self_healing,
                   engine_id => EngineId,
                   reason => Reason}),
    %% Notify all in-flight callers of the crash
    notify_all_callers_error(ReqsTable, <<"engine_crashed">>, NormalizedBin),
    %% Clear all in-flight requests
    ets:delete_all_objects(ReqsTable),
    %% Start a new port for self-heal
    PortOpts = build_port_opts(Config),
    case loom_port:start_link(PortOpts) of
        {ok, NewPortPid} ->
            update_meta_status(starting, Data),
            {next_state, starting,
             Data#data{port_pid = NewPortPid, port_ref = undefined}};
        {error, StartReason} ->
            ?LOG_ERROR(#{msg => self_heal_port_start_failed,
                       engine_id => EngineId,
                       reason => StartReason}),
            {next_state, stopped, Data#data{port_pid = undefined, port_ref = undefined}}
    end;

%% --- EXIT from other linked processes ---
ready(info, {'EXIT', _Pid, _Reason}, _Data) ->
    keep_state_and_data;

%% --- Graceful shutdown ---
ready(cast, do_shutdown, #data{reqs_table = ReqsTable} = Data) ->
    case ets:info(ReqsTable, size) of
        0 ->
            stop_port(Data),
            {next_state, stopped, Data#data{port_pid = undefined}};
        _N ->
            {next_state, draining, Data}
    end;

%% --- Immediate stop ---
ready(cast, do_stop, #data{reqs_table = ReqsTable} = Data) ->
    %% Notify all in-flight callers
    notify_all_callers_error(ReqsTable, <<"engine_stopped">>, <<"stopped">>),
    ets:delete_all_objects(ReqsTable),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};

%% --- Catch-all: reply to unrecognized calls, log unexpected events ---
ready({call, From}, Msg, #data{engine_id = EngineId}) ->
    ?LOG_WARNING(#{msg => unexpected_call_in_ready,
                   engine_id => EngineId,
                   call => Msg}),
    {keep_state_and_data, [{reply, From, {error, unknown_call}}]};
ready(EventType, Event, #data{engine_id = EngineId}) ->
    ?LOG_WARNING(#{msg => unexpected_event_in_ready,
                   engine_id => EngineId,
                   event_type => EventType,
                   event => Event}),
    keep_state_and_data.

-spec draining(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).

%% --- enter: update meta status, set drain_timeout timer ---
draining(enter, _OldState, #data{config = Config} = Data) ->
    update_meta_status(draining, Data),
    DrainTimeout = maps:get(drain_timeout_ms, Config),
    {keep_state, Data, [{state_timeout, DrainTimeout, drain_timeout}]};

%% --- drain_timeout: force-cancel all in-flight, stop port, go to stopped ---
draining(state_timeout, drain_timeout, #data{reqs_table = ReqsTable} = Data) ->
    ?LOG_WARNING(#{msg => drain_timeout_expired,
                   engine_id => Data#data.engine_id,
                   in_flight_requests => ets:info(ReqsTable, size)}),
    notify_all_callers_error(ReqsTable, <<"drain_timeout">>, <<"drain_timeout">>),
    ets:delete_all_objects(ReqsTable),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};

%% --- generate call: reject with {error, draining} ---
draining({call, From}, {generate, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, draining}}]};

%% --- Token routing (same as ready — forward tokens to callers via ETS lookup) ---
draining(info, {loom_port_msg, PortRef, {token, Id, _TokenId, Text, Finished}},
         #data{port_ref = PortRef, reqs_table = ReqsTable} = _Data) ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, _MonRef, _}] ->
            CallerPid ! {loom_token, Id, Text, Finished},
            keep_state_and_data;
        [] ->
            keep_state_and_data
    end;

%% --- Done handling: forward done, cleanup, check if drain complete ---
draining(info, {loom_port_msg, PortRef, {done, Id, TokensGenerated, TimeMs}},
         #data{port_ref = PortRef, reqs_table = ReqsTable} = Data) ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, MonRef, _}] ->
            CallerPid ! {loom_done, Id, #{tokens => TokensGenerated, time_ms => TimeMs}},
            erlang:demonitor(MonRef, [flush]),
            ets:delete(ReqsTable, Id);
        [] ->
            ok
    end,
    maybe_drain_complete(Data);

%% --- Error handling: forward error, cleanup, check if drain complete ---
draining(info, {loom_port_msg, PortRef, {error, Id, Code, Message}},
         #data{port_ref = PortRef, reqs_table = ReqsTable} = Data) when Id =/= undefined ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, MonRef, _}] ->
            CallerPid ! {loom_error, Id, Code, Message},
            erlang:demonitor(MonRef, [flush]),
            ets:delete(ReqsTable, Id);
        [] ->
            ok
    end,
    maybe_drain_complete(Data);

%% --- Port crash: notify all in-flight, clear ETS, go to stopped (NO self-heal) ---
draining(info, {loom_port_exit, _Ref, ExitCode},
         #data{reqs_table = ReqsTable, engine_id = EngineId} = Data) ->
    NormalizedCode = normalize_exit_code(ExitCode),
    NormalizedBin = normalize_exit_code_binary(NormalizedCode),
    ?LOG_WARNING(#{msg => port_crashed_during_drain,
                   engine_id => EngineId,
                   exit_code => NormalizedCode}),
    notify_all_callers_error(ReqsTable, <<"engine_crashed">>, NormalizedBin),
    ets:delete_all_objects(ReqsTable),
    {next_state, stopped, Data#data{port_pid = undefined}};

%% --- Port heartbeat timeout during drain ---
draining(info, {loom_port_timeout, _Ref}, #data{reqs_table = ReqsTable} = Data) ->
    ?LOG_WARNING(#{msg => port_heartbeat_timeout_during_drain,
                   engine_id => Data#data.engine_id}),
    notify_all_callers_error(ReqsTable, <<"engine_timeout">>, <<"heartbeat_timeout">>),
    ets:delete_all_objects(ReqsTable),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};

%% --- Caller death (DOWN): cancel request, cleanup, check if drain complete ---
draining(info, {'DOWN', MonRef, process, CallerPid, _Reason},
         #data{reqs_table = ReqsTable, port_pid = PortPid,
               engine_id = EngineId} = Data) ->
    case ets:match_object(ReqsTable, {'_', CallerPid, MonRef, '_'}) of
        [{RequestId, _CallerPid, _MonRef, _PortRef} | _] ->
            try loom_port:send(PortPid, {cancel, RequestId}) of
                ok -> ok;
                {error, SendErr} ->
                    ?LOG_DEBUG(#{msg => cancel_send_failed,
                                 engine_id => EngineId,
                                 request_id => RequestId,
                                 error => SendErr})
            catch
                _:_ ->
                    ?LOG_DEBUG(#{msg => cancel_send_crashed,
                                 engine_id => EngineId,
                                 request_id => RequestId})
            end,
            ets:delete(ReqsTable, RequestId);
        [] ->
            ok
    end,
    maybe_drain_complete(Data);

%% --- do_shutdown: already draining, keep_state ---
draining(cast, do_shutdown, _Data) ->
    keep_state_and_data;

%% --- do_stop: force-cancel all in-flight, stop port, go to stopped ---
draining(cast, do_stop, #data{reqs_table = ReqsTable} = Data) ->
    notify_all_callers_error(ReqsTable, <<"engine_stopped">>, <<"stopped">>),
    ets:delete_all_objects(ReqsTable),
    stop_port(Data),
    {next_state, stopped, Data#data{port_pid = undefined}};

%% --- EXIT from port process ---
%% When loom_port is killed directly, loom_port_exit may not arrive.
%% Handle EXIT by transitioning to stopped (no self-heal during drain).
draining(info, {'EXIT', PortPid, Reason},
         #data{port_pid = PortPid, reqs_table = ReqsTable,
               engine_id = EngineId} = Data) ->
    NormalizedCode = normalize_exit_code(Reason),
    NormalizedBin = normalize_exit_code_binary(NormalizedCode),
    ?LOG_WARNING(#{msg => port_process_exited_during_drain,
                   engine_id => EngineId,
                   reason => Reason}),
    notify_all_callers_error(ReqsTable, <<"engine_crashed">>, NormalizedBin),
    ets:delete_all_objects(ReqsTable),
    {next_state, stopped, Data#data{port_pid = undefined}};

%% --- EXIT from other linked processes, loom_port_error, gpu_alert: keep state ---
draining(info, {'EXIT', _Pid, _Reason}, _Data) ->
    keep_state_and_data;
draining(info, {loom_port_error, _Ref, Error}, #data{engine_id = EngineId}) ->
    ?LOG_WARNING(#{msg => port_error_during_drain,
                   engine_id => EngineId,
                   error => Error}),
    keep_state_and_data;

%% --- Stale port messages (mismatched PortRef) ---
draining(info, {loom_port_msg, _StaleRef, _Msg}, _Data) ->
    keep_state_and_data;

%% --- Catch-all: reply to unrecognized calls, log unexpected events ---
draining({call, From}, Msg, #data{engine_id = EngineId}) ->
    ?LOG_WARNING(#{msg => unexpected_call_in_draining,
                   engine_id => EngineId,
                   call => Msg}),
    {keep_state_and_data, [{reply, From, {error, unknown_call}}]};
draining(EventType, Event, #data{engine_id = EngineId}) ->
    ?LOG_WARNING(#{msg => unexpected_event_in_draining,
                   engine_id => EngineId,
                   event_type => EventType,
                   event => Event}),
    keep_state_and_data.

-spec stopped(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
stopped(enter, _OldState, Data) ->
    ?LOG_INFO(#{msg => entering_stopped_state,
               engine_id => Data#data.engine_id}),
    update_meta_status(stopped, Data),
    {stop, normal, Data};
stopped(_EventType, _Event, _Data) ->
    %% Should not be reached since enter stops the process, but required
    %% for completeness.
    keep_state_and_data.

-spec terminate(term(), atom(), #data{}) -> any().
terminate(Reason, State, #data{engine_id = EngineId} = Data) ->
    ?LOG_DEBUG(#{msg => terminating,
               engine_id => EngineId,
               state => State,
               reason => Reason}),
    %% Stop port if alive
    stop_port(Data),
    %% Delete both ETS tables with catch to avoid crashes if already deleted
    catch ets:delete(Data#data.reqs_table),
    catch ets:delete(Data#data.meta_table),
    ok.

%%====================================================================
%% Request ID generation
%%====================================================================

%% @doc Generate a unique, monotonically increasing request identifier.
-spec generate_request_id() -> binary().
generate_request_id() ->
    iolist_to_binary([
        <<"req-">>,
        integer_to_binary(erlang:unique_integer([positive, monotonic]))
    ]).

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
-spec update_meta_status(atom(), #data{}) -> ok.
update_meta_status(Status, #data{meta_table = MetaTable, engine_id = EngineId}) ->
    case ets:update_element(MetaTable, meta, {2, Status}) of
        true -> ok;
        false ->
            ?LOG_WARNING(#{msg => meta_row_missing,
                         engine_id => EngineId,
                         target_status => Status})
    end.

%% @doc Normalize port exit codes. Raw exit_status from Erlang ports can
%% be OS-dependent; this helper ensures consistent representation.
%% ASSUMPTION: Exit codes are non-negative integers or the atom 'killed'.
-spec normalize_exit_code(term()) -> non_neg_integer() | killed.
normalize_exit_code(killed) -> killed;
normalize_exit_code(Code) when is_integer(Code), Code >= 0 -> Code;
normalize_exit_code(_Other) -> 1.

%% @doc Convert a normalized exit code to binary for error messages.
-spec normalize_exit_code_binary(non_neg_integer() | killed) -> binary().
normalize_exit_code_binary(killed) -> <<"killed">>;
normalize_exit_code_binary(Code) when is_integer(Code) ->
    integer_to_binary(Code).

%% @doc Check if all in-flight requests have completed during drain.
%% If the requests table is empty, stop the port and transition to stopped.
-spec maybe_drain_complete(#data{}) ->
    gen_statem:event_handler_result(atom()).
maybe_drain_complete(#data{reqs_table = ReqsTable} = Data) ->
    case ets:info(ReqsTable, size) of
        0 ->
            stop_port(Data),
            {next_state, stopped, Data#data{port_pid = undefined}};
        _N ->
            keep_state_and_data
    end.

%% @doc Notify all in-flight callers with an error message and demonitor them.
%% Iterates the requests ETS table and sends {loom_error, RequestId, Code, Detail}
%% to each caller. Does NOT delete ETS entries — caller must do that after.
-spec notify_all_callers_error(ets:table(), binary(), binary()) -> ok.
notify_all_callers_error(ReqsTable, Code, Detail) ->
    ets:foldl(fun({RequestId, CallerPid, MonRef, _PortRef}, Acc) ->
        CallerPid ! {loom_error, RequestId, Code, Detail},
        erlang:demonitor(MonRef, [flush]),
        Acc
    end, ok, ReqsTable).
