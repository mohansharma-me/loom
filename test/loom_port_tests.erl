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
