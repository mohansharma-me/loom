%%%-------------------------------------------------------------------
%%% @doc loom_port - gen_statem managing an external inference engine
%%% subprocess via Erlang Port.
%%%
%%% States: spawning -> loading -> ready -> shutting_down
%%%
%%% The module opens a Port with `open_port/2` using `spawn_executable`,
%%% monitors the owner process, and implements heartbeat-guarded startup
%%% with 3-level shutdown escalation.
%%%
%%% ASSUMPTION: The external process speaks line-delimited JSON on
%%% stdio matching the loom_protocol wire format. Lines are terminated
%%% with \n. The process sends heartbeat messages during startup and
%%% a ready message when fully initialized.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_port).
-behaviour(gen_statem).

%% Public API
-export([
    start_link/1,
    send/2,
    shutdown/1,
    get_state/1,
    get_os_pid/1
]).

%% gen_statem callbacks
-export([
    init/1,
    callback_mode/0,
    spawning/3,
    loading/3,
    ready/3,
    shutting_down/3,
    terminate/3
]).

-record(data, {
    port        :: port() | undefined,
    closed_port :: port() | undefined,  %% preserved after port_close for matching late exit_status
    os_pid      :: non_neg_integer() | undefined,
    ref         :: reference(),
    owner       :: pid(),
    owner_mon   :: reference(),
    line_buf    :: binary(),
    opts        :: map(),
    model       :: binary() | undefined,
    backend     :: binary() | undefined
}).

%%====================================================================
%% Public API
%%====================================================================

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    %% ASSUMPTION: owner defaults to the calling process, resolved here
    %% (not in init/1 where self() would be the gen_statem pid).
    Opts1 = case maps:is_key(owner, Opts) of
        true -> Opts;
        false -> Opts#{owner => self()}
    end,
    gen_statem:start_link(?MODULE, Opts1, []).

-spec send(pid(), loom_protocol:outbound_msg()) -> ok | {error, not_ready}.
send(Pid, Msg) ->
    gen_statem:call(Pid, {send, Msg}).

-spec shutdown(pid()) -> ok.
shutdown(Pid) ->
    gen_statem:cast(Pid, shutdown).

-spec get_state(pid()) -> spawning | loading | ready | shutting_down.
get_state(Pid) ->
    gen_statem:call(Pid, get_state).

-spec get_os_pid(pid()) -> non_neg_integer() | undefined.
get_os_pid(Pid) ->
    gen_statem:call(Pid, get_os_pid).

%%====================================================================
%% gen_statem callbacks
%%====================================================================

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() ->
    [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(atom()).
init(Opts) ->
    case maps:find(command, Opts) of
        {ok, Cmd} when is_list(Cmd) ->
            Args = maps:get(args, Opts, []),
            Owner = maps:get(owner, Opts),
            MaxLineLen = maps:get(max_line_length, Opts, 1048576),
            Ref = make_ref(),
            OwnerMon = erlang:monitor(process, Owner),
            %% ASSUMPTION: command path is valid and executable. If not,
            %% open_port will throw and the process will crash, which the
            %% supervisor will handle.
            Port = open_port({spawn_executable, Cmd}, [
                {args, Args},
                {line, MaxLineLen},
                binary,
                exit_status,
                use_stdio
            ]),
            OsPid = case erlang:port_info(Port, os_pid) of
                {os_pid, P} -> P;
                undefined -> undefined
            end,
            Data = #data{
                port        = Port,
                closed_port = undefined,
                os_pid      = OsPid,
                ref         = Ref,
                owner       = Owner,
                owner_mon   = OwnerMon,
                line_buf    = <<>>,
                opts        = Opts,
                model       = undefined,
                backend     = undefined
            },
            {ok, spawning, Data};
        {ok, _NotString} ->
            {stop, {error, {invalid_command, not_a_string}}};
        error ->
            {stop, {error, missing_command}}
    end.

%%--------------------------------------------------------------------
%% spawning state
%%--------------------------------------------------------------------

-spec spawning(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
spawning(enter, _OldState, #data{opts = Opts}) ->
    SpawnTimeout = maps:get(spawn_timeout_ms, Opts, 5000),
    {keep_state_and_data, [{state_timeout, SpawnTimeout, spawn_timeout}]};
spawning(state_timeout, spawn_timeout, Data) ->
    notify_owner({loom_port_timeout, Data#data.ref}, Data),
    {stop, {shutdown, spawn_timeout}};
spawning(info, {Port, {data, LineData}}, #data{port = Port} = Data) ->
    handle_port_data(LineData, spawning, Data);
spawning(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    handle_port_exit(Status, Data);
spawning(info, {'DOWN', MonRef, process, _, _}, #data{owner_mon = MonRef} = Data) ->
    handle_owner_down(Data);
spawning(cast, shutdown, Data) ->
    {next_state, shutting_down, Data};
spawning({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, spawning}]};
spawning({call, From}, get_os_pid, #data{os_pid = OsPid}) ->
    {keep_state_and_data, [{reply, From, OsPid}]};
spawning({call, From}, {send, _Msg}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.

%%--------------------------------------------------------------------
%% loading state
%%--------------------------------------------------------------------

-spec loading(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
loading(enter, _OldState, #data{opts = Opts}) ->
    HeartbeatTimeout = maps:get(heartbeat_timeout_ms, Opts, 15000),
    {keep_state_and_data, [{state_timeout, HeartbeatTimeout, heartbeat_timeout}]};
loading(state_timeout, heartbeat_timeout, Data) ->
    notify_owner({loom_port_timeout, Data#data.ref}, Data),
    {stop, {shutdown, heartbeat_timeout}};
loading(info, {Port, {data, LineData}}, #data{port = Port} = Data) ->
    handle_port_data(LineData, loading, Data);
loading(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    handle_port_exit(Status, Data);
loading(info, {'DOWN', MonRef, process, _, _}, #data{owner_mon = MonRef} = Data) ->
    handle_owner_down(Data);
loading(cast, shutdown, Data) ->
    {next_state, shutting_down, Data};
loading({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, loading}]};
loading({call, From}, get_os_pid, #data{os_pid = OsPid}) ->
    {keep_state_and_data, [{reply, From, OsPid}]};
loading({call, From}, {send, _Msg}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.

%%--------------------------------------------------------------------
%% ready state
%%--------------------------------------------------------------------

-spec ready(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
ready(enter, _OldState, #data{ref = Ref, model = Model, backend = Backend} = Data) ->
    notify_owner({loom_port_ready, Ref, Model, Backend}, Data),
    keep_state_and_data;
ready(info, {Port, {data, LineData}}, #data{port = Port} = Data) ->
    handle_port_data(LineData, ready, Data);
ready(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    handle_port_exit(Status, Data);
ready(info, {'DOWN', MonRef, process, _, _}, #data{owner_mon = MonRef} = Data) ->
    handle_owner_down(Data);
ready(cast, shutdown, Data) ->
    {next_state, shutting_down, Data};
ready({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};
ready({call, From}, get_os_pid, #data{os_pid = OsPid}) ->
    {keep_state_and_data, [{reply, From, OsPid}]};
ready({call, From}, {send, Msg}, #data{port = Port} = Data) ->
    case Port of
        undefined ->
            {keep_state_and_data, [{reply, From, {error, not_ready}}]};
        _ ->
            try loom_protocol:encode(Msg) of
                Encoded ->
                    try port_command(Port, Encoded) of
                        true -> {keep_state, Data, [{reply, From, ok}]}
                    catch
                        error:badarg ->
                            %% Port died — transition to shutting_down
                            logger:warning("loom_port: port_command failed in ready state, "
                                           "port likely closed"),
                            {next_state, shutting_down, Data,
                             [{reply, From, {error, port_closed}}]}
                    end
            catch
                error:EncodeReason ->
                    {keep_state_and_data,
                     [{reply, From, {error, {encode_failed, EncodeReason}}}]}
            end
    end.

%%--------------------------------------------------------------------
%% shutting_down state
%%--------------------------------------------------------------------

-spec shutting_down(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
shutting_down(enter, _OldState, #data{port = Port, opts = Opts} = Data) ->
    ShutdownTimeout = maps:get(shutdown_timeout_ms, Opts, 10000),
    %% Send shutdown command if port is still open
    case Port =/= undefined andalso erlang:port_info(Port) =/= undefined of
        true ->
            ShutdownCmd = loom_protocol:encode({shutdown}),
            try port_command(Port, ShutdownCmd)
            catch error:badarg ->
                logger:info("loom_port: shutdown command failed (port already closed), "
                            "will escalate after timeout")
            end;
        false ->
            ok
    end,
    {keep_state, Data, [{state_timeout, ShutdownTimeout, shutdown_timeout}]};
shutting_down(state_timeout, shutdown_timeout, #data{port = Port} = Data) ->
    %% Level 2: port_close (EOF stdin, triggers watchdog in adapter)
    case Port =/= undefined andalso erlang:port_info(Port) =/= undefined of
        true ->
            try port_close(Port)
            catch error:badarg ->
                logger:debug("loom_port: port_close failed (port already closed)")
            end,
            PostCloseTimeout = maps:get(post_close_timeout_ms, Data#data.opts, 5000),
            {keep_state, Data#data{port = undefined, closed_port = Port},
             [{state_timeout, PostCloseTimeout, post_close_timeout}]};
        false ->
            %% Port already closed, nothing more we can do
            notify_owner({loom_port_exit, Data#data.ref, killed}, Data),
            {stop, {shutdown, post_close_timeout}}
    end;
shutting_down(state_timeout, post_close_timeout, Data) ->
    %% Level 3: force-kill the OS process
    logger:warning("loom_port: OS process ~p did not exit after post_close_timeout, "
                   "escalating to force-kill",
                   [Data#data.os_pid]),
    loom_os:force_kill(Data#data.os_pid),
    notify_owner({loom_port_exit, Data#data.ref, killed}, Data),
    %% Clear os_pid so terminate/3 does not redundantly force-kill again.
    {stop, {shutdown, post_close_timeout}, Data#data{os_pid = undefined}};
%% Match exit_status from active port OR closed port (late arrival after port_close)
shutting_down(info, {Port, {exit_status, Status}}, #data{port = Port} = Data) ->
    handle_port_exit(Status, Data);
shutting_down(info, {ClosedPort, {exit_status, Status}},
              #data{closed_port = ClosedPort} = Data) when ClosedPort =/= undefined ->
    handle_port_exit(Status, Data);
%% Ignore data during shutdown — from active or closed port
shutting_down(info, {Port, {data, _}}, #data{port = Port}) ->
    keep_state_and_data;
shutting_down(info, {ClosedPort, {data, _}},
              #data{closed_port = ClosedPort}) when ClosedPort =/= undefined ->
    keep_state_and_data;
shutting_down(info, {'DOWN', MonRef, process, _, _}, #data{owner_mon = MonRef}) ->
    %% Owner already dead, we're shutting down anyway
    keep_state_and_data;
shutting_down(cast, shutdown, _Data) ->
    %% Already shutting down
    keep_state_and_data;
shutting_down({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, shutting_down}]};
shutting_down({call, From}, get_os_pid, #data{os_pid = OsPid}) ->
    {keep_state_and_data, [{reply, From, OsPid}]};
shutting_down({call, From}, {send, _Msg}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.

%%--------------------------------------------------------------------
%% terminate
%%--------------------------------------------------------------------

-spec terminate(term(), atom(), #data{}) -> ok.
terminate(_Reason, _State, #data{port = Port, os_pid = OsPid, owner_mon = OwnerMon}) ->
    %% Cleanup: close port if still open, demonitor owner
    case Port =/= undefined andalso erlang:port_info(Port) =/= undefined of
        true ->
            try port_close(Port)
            catch error:badarg ->
                logger:debug("loom_port: port_close failed in terminate (port already closed)")
            end;
        false ->
            ok
    end,
    %% Safety net: force-kill the OS process if we never received its exit_status.
    %% handle_port_exit/2 clears os_pid when exit_status is received, so
    %% OsPid =:= undefined means the process is already confirmed dead.
    loom_os:force_kill(OsPid),
    erlang:demonitor(OwnerMon, [flush]),
    ok.

%%====================================================================
%% Internal helpers
%%====================================================================

%% @doc Handle port data messages. Port delivers lines with {eol, Line} or
%% partial lines with {noeol, Chunk}.
-spec handle_port_data({eol, binary()} | {noeol, binary()}, atom(), #data{}) ->
    gen_statem:event_handler_result(atom()).
handle_port_data({eol, Line}, State, Data) ->
    handle_line(Line, State, Data);
handle_port_data({noeol, Chunk}, _State, Data) ->
    handle_noeol(Chunk, Data).

%% @doc Accumulate partial line fragment into line_buf.
-spec handle_noeol(binary(), #data{}) -> gen_statem:event_handler_result(atom()).
handle_noeol(Chunk, #data{line_buf = Buf} = Data) ->
    {keep_state, Data#data{line_buf = <<Buf/binary, Chunk/binary>>}}.

%% @doc Complete line received: prepend any buffered fragment, clear buffer, dispatch.
-spec handle_line(binary(), atom(), #data{}) -> gen_statem:event_handler_result(atom()).
handle_line(RawLine, State, #data{line_buf = Buf} = Data) ->
    FullLine = case Buf of
        <<>> -> RawLine;
        _    -> <<Buf/binary, RawLine/binary>>
    end,
    Data1 = Data#data{line_buf = <<>>},
    case FullLine of
        <<>> ->
            %% Empty line, skip
            {keep_state, Data1};
        _ ->
            dispatch_line(FullLine, State, Data1)
    end.

%% @doc Decode a complete line and dispatch based on current state and message type.
-spec dispatch_line(binary(), atom(), #data{}) -> gen_statem:event_handler_result(atom()).
dispatch_line(Line, State, #data{ref = Ref} = Data) ->
    case loom_protocol:decode(Line) of
        {ok, {heartbeat, _Status, _Detail}} when State =:= spawning ->
            {next_state, loading, Data};
        {ok, {heartbeat, _Status, _Detail}} when State =:= loading ->
            %% Reset heartbeat timeout
            HeartbeatTimeout = maps:get(heartbeat_timeout_ms, Data#data.opts, 15000),
            {keep_state, Data, [{state_timeout, HeartbeatTimeout, heartbeat_timeout}]};
        {ok, {ready, Model, Backend}} when State =:= spawning; State =:= loading ->
            Data1 = Data#data{model = Model, backend = Backend},
            {next_state, ready, Data1};
        {ok, Msg} when State =:= ready ->
            notify_owner({loom_port_msg, Ref, Msg}, Data),
            {keep_state, Data};
        {ok, Msg} ->
            %% Message in unexpected state — log and drop
            logger:debug("loom_port: dropping ~p message in ~p state",
                         [element(1, Msg), State]),
            {keep_state, Data};
        {error, Reason} ->
            notify_owner({loom_port_error, Ref, {decode_error, Reason}}, Data),
            {keep_state, Data}
    end.

%% @doc Handle port exit_status message.
-spec handle_port_exit(non_neg_integer(), #data{}) -> gen_statem:event_handler_result(atom()).
handle_port_exit(Status, Data) ->
    notify_owner({loom_port_exit, Data#data.ref, Status}, Data),
    {stop, {shutdown, {port_exit, Status}}, Data#data{port = undefined, os_pid = undefined}}.

%% @doc Owner process died, transition to shutting_down.
-spec handle_owner_down(#data{}) -> gen_statem:event_handler_result(atom()).
handle_owner_down(Data) ->
    {next_state, shutting_down, Data}.

%% @doc Send a message to the owner process. Logs a warning if the owner is dead.
-spec notify_owner(term(), #data{}) -> ok.
notify_owner(Msg, #data{owner = Owner}) ->
    case is_process_alive(Owner) of
        true ->
            Owner ! Msg,
            ok;
        false ->
            logger:warning("loom_port: cannot notify dead owner ~p with ~p",
                           [Owner, Msg]),
            ok
    end.
