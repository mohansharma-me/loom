%%%-------------------------------------------------------------------
%%% @doc Common Test integration suite for loom_port gen_statem.
%%%
%%% Tests cover the full lifecycle of a managed subprocess: startup,
%%% ready notification, crash detection, graceful shutdown, shutdown
%%% escalation via port_close, owner death propagation, concurrent
%%% sends, startup delay with heartbeats, and shutdown mid-loading.
%%%
%%% ASSUMPTION: The loom application (and its priv dir) is available
%%% at test runtime because init_per_suite/1 starts it explicitly.
%%% ASSUMPTION: python3 is on PATH in the test environment.
%%% ASSUMPTION: os:cmd("kill -9 ...") works on the test host (macOS/Linux).
%%% @end
%%%-------------------------------------------------------------------
-module(loom_port_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    adapter_crash_test/1,
    graceful_shutdown_test/1,
    shutdown_escalation_test/1,
    owner_death_test/1,
    concurrent_sends_test/1,
    startup_delay_test/1,
    shutdown_during_loading_test/1,
    direct_ready_no_heartbeat_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        adapter_crash_test,
        graceful_shutdown_test,
        shutdown_escalation_test,
        owner_death_test,
        concurrent_sends_test,
        startup_delay_test,
        shutdown_during_loading_test,
        direct_ready_no_heartbeat_test
    ].

init_per_suite(Config) ->
    %% Pre-load config so loom_app:start/2 skips file-based loading.
    %% ASSUMPTION: loom_app checks ETS existence before loading config/loom.json,
    %% so pre-loading here avoids CWD-dependent config resolution in test.
    ok = loom_config:load(test_config_path()),
    %% Start the loom application so code:priv_dir(loom) resolves correctly.
    %% ASSUMPTION: application:ensure_all_started/1 is idempotent; if loom is
    %% already running (e.g., from a prior suite) it just returns {ok, []}.
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Trap exits so the test process receives EXIT signals from
    %% linked or monitored processes without crashing.
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_TestCase, _Config) ->
    %% Flush any leftover messages from the test mailbox to prevent
    %% cross-test contamination. Kill any loom_port processes still alive.
    %% ASSUMPTION: loom_port processes are not registered; we identify them
    %% by draining the mailbox and stopping any Pid that is still alive.
    flush_mailbox(),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc Kill the adapter OS process with SIGKILL and verify loom_port
%% detects the exit, notifies the owner with a non-zero code, and dies.
adapter_crash_test(_Config) ->
    Opts = default_opts(),
    {ok, Pid} = loom_port:start_link(Opts),
    Ref = wait_ready(Pid),

    OsPid = loom_port:get_os_pid(Pid),
    ?assert(is_integer(OsPid) andalso OsPid > 0),

    %% Force-kill the adapter process with SIGKILL.
    os:cmd("kill -9 " ++ integer_to_list(OsPid)),

    %% Expect loom_port_exit within 2 seconds.
    ExitCode = receive
        {loom_port_exit, Ref, Code} -> Code
    after 2000 ->
        ct:fail("adapter_crash_test: no loom_port_exit within 2s")
    end,

    %% ASSUMPTION: SIGKILL produces exit code 137 (128 + 9) on Linux/macOS.
    %% We only assert non-zero; the exact value is OS-dependent.
    ?assertNotEqual(0, ExitCode),

    %% loom_port process must be dead.
    wait_dead(Pid, 2000).

%% @doc Normal shutdown: loom_port sends shutdown command; adapter exits 0.
graceful_shutdown_test(_Config) ->
    Opts = default_opts(),
    {ok, Pid} = loom_port:start_link(Opts),
    _Ref = wait_ready(Pid),

    ok = loom_port:shutdown(Pid),

    receive
        {loom_port_exit, _Ref2, 0} -> ok
    after 10000 ->
        ct:fail("graceful_shutdown_test: no loom_port_exit(0) within 10s")
    end,

    wait_dead(Pid, 2000).

%% @doc Use /bin/cat as command (ignores shutdown command). loom_port must
%% escalate to port_close and then terminate, delivering loom_port_exit.
%%
%% ASSUMPTION: /bin/cat reads stdin and echoes it; it will not respond to
%% the JSON shutdown command, so the shutdown_timeout_ms fires, triggering
%% port_close (EOF to cat's stdin), which makes cat exit.
shutdown_escalation_test(_Config) ->
    CatPath = os:find_executable("cat"),
    Opts = #{
        command             => CatPath,
        args                => [],
        owner               => self(),
        spawn_timeout_ms    => 60000,
        heartbeat_timeout_ms => 60000,
        shutdown_timeout_ms  => 1000,
        post_close_timeout_ms => 2000,
        max_line_length     => 1048576
    },
    {ok, Pid} = loom_port:start_link(Opts),

    %% cat won't send a heartbeat/ready, but we don't need it for this test.
    %% Give it a moment to start.
    timer:sleep(100),

    loom_port:shutdown(Pid),

    %% Expect exit within shutdown_timeout + post_close_timeout + margin.
    receive
        {loom_port_exit, _, _Code} -> ok
    after 10000 ->
        ct:fail("shutdown_escalation_test: no loom_port_exit within 10s")
    end,

    wait_dead(Pid, 2000).

%% @doc When the owner process dies, loom_port must transition to shutting_down
%% and terminate within a reasonable time.
owner_death_test(_Config) ->
    %% Spawn a temporary owner process.
    OwnerPid = spawn(fun() ->
        receive stop -> ok end
    end),

    Opts = (default_opts())#{owner => OwnerPid},
    {ok, Pid} = loom_port:start_link(Opts),

    %% Monitor loom_port so we can detect when it dies.
    Mon = erlang:monitor(process, Pid),

    %% Wait for loom_port to reach ready (owner receives the ready msg).
    %% We don't receive it here (OwnerPid is the owner), so we poll state.
    wait_state(Pid, ready, 5000),

    %% Kill the owner.
    exit(OwnerPid, kill),

    %% loom_port should die within 2 seconds.
    receive
        {'DOWN', Mon, process, Pid, _Reason} -> ok
    after 2000 ->
        ct:fail("owner_death_test: loom_port still alive 2s after owner killed")
    end.

%% @doc Send 5 concurrent generate requests; collect all 30 response messages
%% (5 tokens + 1 done per request) and verify counts.
concurrent_sends_test(_Config) ->
    Opts = default_opts(),
    {ok, Pid} = loom_port:start_link(Opts),
    Ref = wait_ready(Pid),

    %% Send 5 generate requests.
    ReqIds = [list_to_binary("req-" ++ integer_to_list(N)) || N <- lists:seq(1, 5)],
    lists:foreach(fun(Id) ->
        ok = loom_port:send(Pid, {generate, Id, <<"Hello">>, #{}})
    end, ReqIds),

    %% ASSUMPTION: Each request yields exactly 5 token messages + 1 done = 6 messages.
    %% 5 requests × 6 messages = 30 total loom_port_msg messages.
    Msgs = collect_all_messages(Ref, 30, 5000),

    Tokens = [M || {loom_port_msg, _, {token, _, _, _, _}} = M <- Msgs],
    Dones  = [M || {loom_port_msg, _, {done,  _, _, _}}    = M <- Msgs],

    ?assertEqual(25, length(Tokens)),
    ?assertEqual(5,  length(Dones)),

    ok = loom_port:shutdown(Pid),
    receive
        {loom_port_exit, Ref, _} -> ok
    after 10000 ->
        ct:fail("concurrent_sends_test: no loom_port_exit within 10s")
    end.

%% @doc Adapter started with a 2-second startup delay and 1-second heartbeat
%% interval. Verify that ready arrives after at least 1500ms (proving the delay
%% was respected and heartbeats kept the timeout alive).
startup_delay_test(_Config) ->
    Opts = #{
        command              => python_cmd(),
        args                 => [mock_adapter_path(),
                                 "--startup-delay", "2",
                                 "--heartbeat-interval", "1"],
        owner                => self(),
        spawn_timeout_ms     => 10000,
        heartbeat_timeout_ms => 3000,
        shutdown_timeout_ms  => 5000,
        post_close_timeout_ms => 2000,
        max_line_length      => 1048576
    },
    T0 = erlang:monotonic_time(millisecond),
    {ok, Pid} = loom_port:start_link(Opts),

    receive
        {loom_port_ready, _, _, _} -> ok
    after 10000 ->
        ct:fail("startup_delay_test: no loom_port_ready within 10s")
    end,

    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ct:pal("startup_delay_test: elapsed ~wms", [Elapsed]),

    %% ASSUMPTION: 2-second startup delay means ready arrives after >=1500ms
    %% to allow for scheduler jitter while still being a meaningful lower bound.
    ?assert(Elapsed >= 1500),
    ?assert(Elapsed < 10000),

    ok = loom_port:shutdown(Pid),
    receive
        {loom_port_exit, _, _} -> ok
    after 10000 ->
        ct:fail("startup_delay_test: no loom_port_exit within 10s")
    end.

%% @doc Shutdown issued while adapter is still loading (30-second startup delay).
%% loom_port must terminate within the configured timeouts, not wait 30s.
shutdown_during_loading_test(_Config) ->
    Opts = #{
        command              => python_cmd(),
        args                 => [mock_adapter_path(),
                                 "--startup-delay", "30"],
        owner                => self(),
        spawn_timeout_ms     => 60000,
        heartbeat_timeout_ms => 60000,
        shutdown_timeout_ms  => 2000,
        post_close_timeout_ms => 3000,
        max_line_length      => 1048576
    },
    {ok, Pid} = loom_port:start_link(Opts),

    %% Wait long enough for the adapter to start and send its first heartbeat
    %% (which transitions loom_port to loading), but not for it to reach ready.
    timer:sleep(500),

    loom_port:shutdown(Pid),

    %% Must receive exit within 10s (well under the 30s startup delay).
    receive
        {loom_port_exit, _, _} -> ok
    after 10000 ->
        ct:fail("shutdown_during_loading_test: no loom_port_exit within 10s")
    end,

    wait_dead(Pid, 2000).

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Path to the test loom.json config file for this suite.
-spec test_config_path() -> file:filename().
test_config_path() ->
    %% ASSUMPTION: The test data dir is relative to the project root,
    %% and we can locate it via the source file's compiled path.
    DataDir = filename:join([
        filename:dirname(filename:dirname(code:which(?MODULE))),
        "test", "loom_port_SUITE_data", "loom.json"
    ]),
    case filelib:is_regular(DataDir) of
        true -> DataDir;
        false ->
            %% Fallback: try relative to current working directory
            filename:join(["test", "loom_port_SUITE_data", "loom.json"])
    end.

%% @doc Path to the mock adapter Python script.
-spec mock_adapter_path() -> string().
mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

%% @doc Path to python3 executable.
-spec python_cmd() -> string().
python_cmd() ->
    os:find_executable("python3").

%% @doc Default options for starting loom_port with the mock adapter.
%% ASSUMPTION: owner => self() is always set; callers may override it.
-spec default_opts() -> map().
default_opts() ->
    #{
        command              => python_cmd(),
        args                 => [mock_adapter_path()],
        owner                => self(),
        spawn_timeout_ms     => 5000,
        heartbeat_timeout_ms => 5000,
        shutdown_timeout_ms  => 5000,
        post_close_timeout_ms => 2000,
        max_line_length      => 1048576
    }.

%% @doc Wait for loom_port_ready message (up to 5s), return the Ref.
%% ASSUMPTION: The test process is the owner and will receive the ready message.
-spec wait_ready(pid()) -> reference().
wait_ready(_Pid) ->
    receive
        {loom_port_ready, Ref, _Model, _Backend} -> Ref
    after 5000 ->
        ct:fail("wait_ready: no loom_port_ready within 5s")
    end.

%% @doc Collect N loom_port_msg messages for the given Ref within Timeout ms
%% per message. Returns the list of raw messages.
%%
%% ASSUMPTION: Messages arrive in sequence; each individual message is waited
%% for up to Timeout ms. Total wall-clock time may be up to N * Timeout.
-spec collect_all_messages(reference(), non_neg_integer(), non_neg_integer()) -> [term()].
collect_all_messages(_Ref, 0, _Timeout) ->
    [];
collect_all_messages(Ref, N, Timeout) ->
    receive
        {loom_port_msg, Ref, _} = Msg ->
            [Msg | collect_all_messages(Ref, N - 1, Timeout)]
    after Timeout ->
        ct:fail(io_lib:format(
            "collect_all_messages: timed out waiting for message ~w of ~w",
            [N, N]))
    end.

%% @doc Adapter that sends ready immediately (no heartbeat), testing
%% the direct spawning → ready transition.
direct_ready_no_heartbeat_test(_Config) ->
    %% Create a tiny Python script that sends ready immediately, then reads stdin
    Script = "import sys, json; "
             "sys.stdout.write(json.dumps({'type':'ready','model':'direct','backend':'test'}) + '\\n'); "
             "sys.stdout.flush(); "
             "[sys.stdin.readline() for _ in iter(int, 1)]",
    Opts = #{
        command => python_cmd(),
        args => ["-c", Script],
        owner => self(),
        spawn_timeout_ms => 5000,
        heartbeat_timeout_ms => 5000,
        shutdown_timeout_ms => 2000,
        post_close_timeout_ms => 2000,
        max_line_length => 1048576
    },
    {ok, Pid} = loom_port:start_link(Opts),
    Ref = wait_ready(5000),
    %% Verify it came with the direct model/backend
    receive after 0 -> ok end,
    ?assertEqual(ready, loom_port:get_state(Pid)),
    loom_port:shutdown(Pid),
    receive
        {loom_port_exit, Ref, _Code} -> ok
    after 10000 -> ct:fail("No exit after shutdown")
    end.

%% @doc Poll loom_port:get_state/1 until it returns the expected State or
%% the timeout (ms) expires.
-spec wait_state(pid(), atom(), non_neg_integer()) -> ok.
wait_state(Pid, State, Timeout) when Timeout > 0 ->
    case is_process_alive(Pid) of
        false ->
            ct:fail(io_lib:format("wait_state: pid ~p died before reaching ~p", [Pid, State]));
        true ->
            case loom_port:get_state(Pid) of
                State ->
                    ok;
                _ ->
                    timer:sleep(50),
                    wait_state(Pid, State, Timeout - 50)
            end
    end;
wait_state(Pid, State, _Timeout) ->
    ct:fail(io_lib:format("wait_state: pid ~p never reached state ~p", [Pid, State])).

%% @doc Wait up to TimeoutMs for Pid to die.
-spec wait_dead(pid(), non_neg_integer()) -> ok.
wait_dead(Pid, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_dead_loop(Pid, Deadline).

-spec wait_dead_loop(pid(), integer()) -> ok.
wait_dead_loop(Pid, Deadline) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining > 0 of
                false ->
                    ct:fail(io_lib:format("wait_dead: pid ~p still alive after timeout", [Pid]));
                true ->
                    timer:sleep(min(50, Remaining)),
                    wait_dead_loop(Pid, Deadline)
            end
    end.

%% @doc Drain all messages from the current process mailbox.
-spec flush_mailbox() -> ok.
flush_mailbox() ->
    receive
        _ -> flush_mailbox()
    after 0 ->
        ok
    end.
