-module(loom_port_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Helpers ---

mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

python_cmd() ->
    os:find_executable("python3").

default_opts() ->
    #{
        command => python_cmd(),
        args => [mock_adapter_path()],
        owner => self(),
        spawn_timeout_ms => 5000,
        heartbeat_timeout_ms => 5000,
        shutdown_timeout_ms => 5000,
        post_close_timeout_ms => 2000,
        max_line_length => 1048576
    }.

%% --- Tests ---

happy_path_startup_test() ->
    process_flag(trap_exit, true),
    {ok, Pid} = loom_port:start_link(default_opts()),
    %% Wait for ready message
    receive
        {loom_port_ready, _Ref, Model, Backend} ->
            ?assertEqual(<<"mock">>, Model),
            ?assertEqual(<<"mock">>, Backend)
    after 5000 ->
        ?assert(false)
    end,
    %% Verify state is ready
    ?assertEqual(ready, loom_port:get_state(Pid)),
    %% OS pid should be a positive integer
    OsPid = loom_port:get_os_pid(Pid),
    ?assert(is_integer(OsPid) andalso OsPid > 0),
    %% Shutdown
    ok = loom_port:shutdown(Pid),
    %% Wait for exit notification
    receive
        {loom_port_exit, _Ref2, _ExitCode} ->
            ok
    after 10000 ->
        ?assert(false)
    end,
    %% Process should be dead
    ?assertNot(is_process_alive(Pid)).

spawn_timeout_test() ->
    process_flag(trap_exit, true),
    %% ASSUMPTION: /bin/cat never sends a heartbeat or ready message,
    %% so the spawn timeout will fire. We use a short timeout (1s).
    CatPath = os:find_executable("cat"),
    Opts = #{
        command => CatPath,
        args => [],
        owner => self(),
        spawn_timeout_ms => 1000,
        heartbeat_timeout_ms => 5000,
        shutdown_timeout_ms => 1000,
        post_close_timeout_ms => 1000,
        max_line_length => 1048576
    },
    {ok, Pid} = loom_port:start_link(Opts),
    receive
        {loom_port_timeout, _Ref} ->
            ok
    after 2000 ->
        ?assert(false)
    end,
    %% Process should stop after timeout
    timer:sleep(100),
    ?assertNot(is_process_alive(Pid)).

bad_command_path_test() ->
    process_flag(trap_exit, true),
    Opts = #{
        command => "/nonexistent/path/to/binary",
        args => [],
        owner => self()
    },
    %% open_port with a nonexistent executable raises an error,
    %% which crashes the gen_statem init. start_link should fail.
    Result = loom_port:start_link(Opts),
    ?assertMatch({error, _}, Result).

send_in_ready_state_test() ->
    process_flag(trap_exit, true),
    {ok, Pid} = loom_port:start_link(default_opts()),
    %% Wait for the port to reach ready
    Ref = wait_for_ready(),
    %% Send a health command and verify the response arrives
    ok = loom_port:send(Pid, {health}),
    receive
        {loom_port_msg, Ref, {health_response, _Status, _GpuUtil, _MemUsedGb, _MemTotalGb}} ->
            ok
    after 5000 ->
        ?assert(false)
    end,
    %% Clean shutdown
    ok = loom_port:shutdown(Pid),
    wait_for_exit(),
    ?assertNot(is_process_alive(Pid)).

send_not_ready_test() ->
    process_flag(trap_exit, true),
    %% ASSUMPTION: cat never sends heartbeat/ready, so loom_port stays in
    %% spawning state and returns {error, not_ready} for any send call.
    CatPath = os:find_executable("cat"),
    Opts = #{
        command => CatPath,
        args => [],
        owner => self(),
        spawn_timeout_ms => 3000,
        heartbeat_timeout_ms => 3000,
        shutdown_timeout_ms => 1000,
        post_close_timeout_ms => 1000,
        max_line_length => 1048576
    },
    {ok, Pid} = loom_port:start_link(Opts),
    %% Port is in spawning state — send must be refused
    ?assertEqual({error, not_ready}, loom_port:send(Pid, {health})),
    %% Trigger shutdown and drain the timeout/exit notification
    ok = loom_port:shutdown(Pid),
    wait_for_exit(),
    ?assertNot(is_process_alive(Pid)).

send_generate_and_receive_tokens_test() ->
    process_flag(trap_exit, true),
    {ok, Pid} = loom_port:start_link(default_opts()),
    Ref = wait_for_ready(),
    %% Send a generate request; mock adapter replies with 5 tokens + 1 done
    ok = loom_port:send(Pid, {generate, <<"req-1">>, <<"Hello">>, #{}}),
    %% Collect all 6 response messages (5 tokens + 1 done)
    Msgs = collect_messages(Ref, 6, 5000),
    TokenMsgs = [M || {loom_port_msg, _, {token, _, _, _, _}} = M <- Msgs],
    DoneMsgs  = [M || {loom_port_msg, _, {done,  _, _, _}}    = M <- Msgs],
    ?assertEqual(5, length(TokenMsgs)),
    ?assertEqual(1, length(DoneMsgs)),
    ok = loom_port:shutdown(Pid),
    wait_for_exit(),
    ?assertNot(is_process_alive(Pid)).

graceful_shutdown_test() ->
    process_flag(trap_exit, true),
    {ok, Pid} = loom_port:start_link(default_opts()),
    _Ref = wait_for_ready(),
    ok = loom_port:shutdown(Pid),
    %% Mock adapter calls os._exit(0) on shutdown command, so exit code is 0
    receive
        {loom_port_exit, _, 0} -> ok
    after 10000 ->
        ?assert(false)
    end,
    ?assertNot(is_process_alive(Pid)).

double_shutdown_test() ->
    process_flag(trap_exit, true),
    {ok, Pid} = loom_port:start_link(default_opts()),
    _Ref = wait_for_ready(),
    ok = loom_port:shutdown(Pid),
    %% Second shutdown while already shutting_down — must not crash
    ok = loom_port:shutdown(Pid),
    wait_for_exit(),
    ?assertNot(is_process_alive(Pid)).

send_during_shutdown_test() ->
    process_flag(trap_exit, true),
    {ok, Pid} = loom_port:start_link(default_opts()),
    _Ref = wait_for_ready(),
    ok = loom_port:shutdown(Pid),
    %% Sending after shutdown is requested must return {error, not_ready}
    %% ASSUMPTION: The gen_statem processes the shutdown cast before this
    %% synchronous call, so the process is already in shutting_down state.
    ?assertEqual({error, not_ready}, loom_port:send(Pid, {health})),
    wait_for_exit(),
    ?assertNot(is_process_alive(Pid)).

%% --- Additional helpers ---

%% @doc Wait for the loom_port_ready notification and return the port reference.
wait_for_ready() ->
    receive
        {loom_port_ready, Ref, _Model, _Backend} -> Ref
    after 5000 ->
        error(wait_for_ready_timeout)
    end.

%% @doc Wait for loom_port_exit or loom_port_timeout with a 10-second deadline.
wait_for_exit() ->
    receive
        {loom_port_exit,    _, _} -> ok;
        {loom_port_timeout, _}    -> ok
    after 10000 ->
        error(wait_for_exit_timeout)
    end.

%% @doc Collect N {loom_port_msg, Ref, _} messages within Timeout ms each.
collect_messages(_Ref, 0, _Timeout) ->
    [];
collect_messages(Ref, N, Timeout) ->
    receive
        {loom_port_msg, Ref, _} = Msg ->
            [Msg | collect_messages(Ref, N - 1, Timeout)]
    after Timeout ->
        error({collect_messages_timeout, N})
    end.
