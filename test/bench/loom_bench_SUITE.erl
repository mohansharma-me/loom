%%%-------------------------------------------------------------------
%%% @doc Benchmark suite for measuring Port communication overhead.
%%%
%%% Run: rebar3 ct --dir test/bench --suite loom_bench_SUITE
%%% Strict: BENCH_STRICT=true rebar3 ct --dir test/bench --suite loom_bench_SUITE
%%%
%%% Results: _build/bench/results.json + console table
%%% @end
%%%-------------------------------------------------------------------
-module(loom_bench_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

%% Protocol group
-export([
    encode_decode_health/1,
    encode_decode_generate/1,
    encode_decode_large/1
]).

%% Port group
-export([
    health_roundtrip/1,
    token_overhead/1
]).

%% Coordinator group
-export([
    coordinator_ets_read/1,
    coordinator_generate/1
]).

%% Concurrent group
-export([
    concurrent_10/1,
    concurrent_50/1,
    concurrent_100/1
]).

%% Large messages group
-export([
    large_4k/1,
    large_16k/1,
    large_64k/1
]).

%% Pre-encoded inbound JSON for protocol benchmarks (avoids measuring
%% binary construction overhead during the benchmark loop).
-define(HEALTH_RESPONSE_JSON,
    <<"{\"type\":\"health\",\"status\":\"ok\",\"gpu_util\":0.0,"
      "\"mem_used_gb\":0.0,\"mem_total_gb\":80.0}">>).
-define(TOKEN_RESPONSE_JSON,
    <<"{\"type\":\"token\",\"id\":\"bench\",\"token_id\":1,"
      "\"text\":\"hello\",\"finished\":false}">>).

%% Threshold map: benchmark_name => #{metric => max_microseconds}.
-define(THRESHOLDS, #{
    health_roundtrip => #{p50 => 1000, p99 => 2000},
    token_overhead => #{p50 => 500},
    encode_decode_health => #{p50 => 100},
    encode_decode_generate => #{p50 => 100}
}).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [{group, protocol},
     {group, port},
     {group, coordinator},
     {group, concurrent},
     {group, large_messages}].

groups() ->
    [{protocol, [sequence], [
        encode_decode_health,
        encode_decode_generate,
        encode_decode_large
    ]},
     {port, [sequence], [
        health_roundtrip,
        token_overhead
    ]},
     {coordinator, [sequence], [
        coordinator_ets_read,
        coordinator_generate
    ]},
     {concurrent, [sequence], [
        concurrent_10,
        concurrent_50,
        concurrent_100
    ]},
     {large_messages, [sequence], [
        large_4k,
        large_16k,
        large_64k
    ]}].

init_per_suite(Config) ->
    %% ASSUMPTION: loom_config:load/1 must be called before starting loom
    %% so that loom_app:start/2 skips file-based config resolution.
    ok = loom_config:load(fixture_path("minimal.json")),
    {ok, _} = application:ensure_all_started(loom),
    %% ASSUMPTION: Each CT callback (init_per_suite, test cases, end_per_suite)
    %% runs in a SEPARATE OS process in Common Test. A named_table ETS table is
    %% owned by its creating process and is destroyed when that process exits.
    %% To keep the table alive across all callbacks we spawn a dedicated keeper
    %% process that owns the table and stays alive until end_per_suite sends it
    %% a stop message.
    Self = self(),
    Keeper = spawn(fun() ->
        ets:new(loom_bench_results, [named_table, public, set]),
        Self ! {ets_ready, self()},
        receive stop -> ok end
    end),
    receive
        {ets_ready, Keeper} -> ok
    after 5000 ->
        ct:fail(ets_keeper_timeout)
    end,
    [{ets_keeper, Keeper} | Config].

end_per_suite(Config) ->
    %% Collect all results before stopping keeper
    Results = lists:sort(ets:tab2list(loom_bench_results)),
    %% Stop the ETS keeper process (deletes the table)
    Keeper = ?config(ets_keeper, Config),
    Keeper ! stop,

    %% Print console table
    Table = loom_bench_stats:format_table(Results),
    ct:pal("~s", [Table]),

    %% Check thresholds
    ThresholdResults = loom_bench_stats:check_thresholds(Results, ?THRESHOLDS),
    log_threshold_results(ThresholdResults),

    %% Write JSON
    StrictMode = os:getenv("BENCH_STRICT") =:= "true",
    JsonBin = loom_bench_stats:to_json(Results,
        #{strict_mode => StrictMode, thresholds => ?THRESHOLDS}),
    %% ASSUMPTION: ?FILE resolves to test/bench/loom_bench_SUITE.erl so the
    %% project root is two dirname calls up, giving an absolute path that is
    %% CWD-independent (CT changes CWD during end_per_suite).
    ProjectRoot = filename:dirname(filename:dirname(filename:dirname(?FILE))),
    ResultsDir = filename:join([ProjectRoot, "_build", "bench"]),
    filelib:ensure_dir(filename:join(ResultsDir, "dummy")),
    ResultsFile = filename:join(ResultsDir, "results.json"),
    ok = file:write_file(ResultsFile, JsonBin),
    ct:pal("Results written to ~s", [ResultsFile]),

    %% Enforce thresholds in strict mode
    case StrictMode of
        true ->
            Failures = [R || {_, fail, _} = R <- ThresholdResults],
            case Failures of
                [] -> ok;
                _ -> ct:fail({threshold_violations, Failures})
            end;
        false ->
            ok
    end,

    application:stop(loom),
    ok.

init_per_group(protocol, Config) ->
    Config;
init_per_group(port, Config) ->
    %% ASSUMPTION: init_per_group runs in a short-lived CT process that dies
    %% after returning Config. loom_port monitors its owner; if owner =>
    %% self() the port shuts down immediately when init exits.
    %% Fix: spawn a long-lived keeper process as the port owner. The keeper
    %% forwards loom_port_ready/loom_port_msg to whichever process last
    %% called {register, Pid}. Benchmarks register self() before measuring.
    Self = self(),
    Keeper = spawn(fun() -> port_owner_keeper(Self) end),
    receive
        {port_owner_keeper_ready, Keeper, Pid, Ref} ->
            [{port_pid, Pid}, {port_ref, Ref}, {port_keeper, Keeper} | Config]
    after 15000 ->
        ct:fail(port_keeper_timeout)
    end;
init_per_group(Group, Config) when Group =:= coordinator;
                                   Group =:= concurrent;
                                   Group =:= large_messages ->
    %% ASSUMPTION: init_per_group runs in a short-lived CT process. When CT
    %% tears down the group it sends a non-normal exit to that process, which
    %% propagates via the start_link parent relationship to the coordinator,
    %% causing it to terminate before the test cases run.
    %% Fix: spawn a long-lived keeper process as the coordinator parent. The
    %% keeper calls start_link (becoming the OTP parent) and stays alive until
    %% end_per_group sends it a stop message. Pattern mirrors port_owner_keeper.
    Self = self(),
    EngineId = list_to_binary("bench_" ++ atom_to_list(Group)),
    MaxConcurrent = case Group of
        concurrent -> 200;
        _ -> 64
    end,
    CoordConfig = #{
        engine_id => EngineId,
        command => python_cmd(),
        args => [mock_adapter_path(), "--token-delay", "0",
                 "--startup-delay", "0", "--heartbeat-interval", "5"],
        model => <<"mock">>,
        backend => <<"mock">>,
        startup_timeout_ms => 10000,
        drain_timeout_ms => 5000,
        max_concurrent => MaxConcurrent
    },
    Keeper = spawn(fun() -> coord_keeper(Self, CoordConfig, EngineId) end),
    receive
        {coord_keeper_ready, Keeper, CoordPid} ->
            [{coord_pid, CoordPid}, {engine_id, EngineId},
             {coord_keeper, Keeper} | Config]
    after 15000 ->
        ct:fail(coord_keeper_timeout)
    end.

end_per_group(protocol, _Config) ->
    ok;
end_per_group(port, Config) ->
    Keeper = ?config(port_keeper, Config),
    PortPid = ?config(port_pid, Config),
    loom_port:shutdown(PortPid),
    wait_process_dead(PortPid, 5000),
    Keeper ! stop,
    ok;
end_per_group(_Group, Config) ->
    CoordPid = ?config(coord_pid, Config),
    Keeper = ?config(coord_keeper, Config),
    loom_engine_coordinator:stop(CoordPid),
    wait_process_dead(CoordPid, 5000),
    Keeper ! stop,
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%%====================================================================
%% Protocol group benchmarks
%%====================================================================

encode_decode_health(_Config) ->
    Msg = {health},
    Samples = time_iterations(fun() ->
        _Encoded = loom_protocol:encode(Msg),
        {ok, _} = loom_protocol:decode(?HEALTH_RESPONSE_JSON)
    end, 10000),
    store_result(encode_decode_health, Samples).

encode_decode_generate(_Config) ->
    Msg = {generate, <<"bench-id">>, <<"Hello world">>, #{max_tokens => 100}},
    Samples = time_iterations(fun() ->
        _Encoded = loom_protocol:encode(Msg),
        {ok, _} = loom_protocol:decode(?TOKEN_RESPONSE_JSON)
    end, 10000),
    store_result(encode_decode_generate, Samples).

encode_decode_large(_Config) ->
    Sizes = [{encode_large_4k, 4096},
             {encode_large_16k, 16384},
             {encode_large_64k, 65536}],
    lists:foreach(fun({Name, Size}) ->
        Prompt = binary:copy(<<"x">>, Size),
        Msg = {generate, <<"bench-id">>, Prompt, #{max_tokens => 100}},
        Samples = time_iterations(fun() ->
            _Encoded = loom_protocol:encode(Msg)
        end, 1000),
        store_result(Name, Samples)
    end, Sizes).

%%====================================================================
%% Port group benchmarks
%%====================================================================

health_roundtrip(Config) ->
    PortPid = ?config(port_pid, Config),
    PortRef = ?config(port_ref, Config),
    Keeper = ?config(port_keeper, Config),
    %% Register this test process as the current receiver for port messages.
    Keeper ! {register, self()},
    Samples = lists:map(fun(_) ->
        T0 = erlang:monotonic_time(microsecond),
        ok = loom_port:send(PortPid, {health}),
        receive
            {loom_port_msg, PortRef, {health_response, _, _, _, _}} ->
                erlang:monotonic_time(microsecond) - T0
        after 5000 ->
            ct:fail(health_response_timeout)
        end
    end, lists:seq(1, 1000)),
    store_result(health_roundtrip, Samples).

token_overhead(Config) ->
    PortPid = ?config(port_pid, Config),
    PortRef = ?config(port_ref, Config),
    Keeper = ?config(port_keeper, Config),
    %% Register this test process as the current receiver for port messages.
    Keeper ! {register, self()},
    %% ASSUMPTION: Mock adapter produces 5 tokens per generate request.
    TokensPerRequest = 5,
    AllSamples = lists:flatmap(fun(I) ->
        Id = integer_to_binary(I),
        ok = loom_port:send(PortPid,
            {generate, Id, <<"bench prompt">>, #{max_tokens => 100}}),
        TokenTimestamps = collect_port_token_timestamps(PortRef, Id, TokensPerRequest),
        %% Wait for done message
        receive
            {loom_port_msg, PortRef, {done, Id, _, _}} -> ok
        after 5000 ->
            ct:fail(done_timeout)
        end,
        inter_token_deltas(TokenTimestamps)
    end, lists:seq(1, 500)),
    store_result(token_overhead, AllSamples).

%%====================================================================
%% Coordinator group benchmarks
%%====================================================================

coordinator_ets_read(Config) ->
    EngineId = ?config(engine_id, Config),
    Samples = time_iterations(fun() ->
        _Status = loom_engine_coordinator:get_status(EngineId),
        _Load = loom_engine_coordinator:get_load(EngineId),
        _Info = loom_engine_coordinator:get_info(EngineId)
    end, 10000),
    store_result(coordinator_ets_read, Samples).

coordinator_generate(Config) ->
    CoordPid = ?config(coord_pid, Config),
    %% ASSUMPTION: Mock adapter produces 5 tokens per generate request.
    TokensPerRequest = 5,
    Samples = lists:map(fun(_) ->
        T0 = erlang:monotonic_time(microsecond),
        {ok, ReqId} = loom_engine_coordinator:generate(
            CoordPid, <<"bench prompt">>, #{max_tokens => 100}),
        collect_coordinator_tokens(ReqId, TokensPerRequest),
        receive
            {loom_done, ReqId, _Stats} ->
                erlang:monotonic_time(microsecond) - T0
        after 5000 ->
            ct:fail(coordinator_done_timeout)
        end
    end, lists:seq(1, 500)),
    store_result(coordinator_generate, Samples).

%%====================================================================
%% Concurrent group benchmarks
%%====================================================================

concurrent_10(Config) ->
    run_concurrent_bench(10, 100, Config).

concurrent_50(Config) ->
    run_concurrent_bench(50, 50, Config).

concurrent_100(Config) ->
    run_concurrent_bench(100, 20, Config).

%%====================================================================
%% Large messages group benchmarks
%%====================================================================

large_4k(Config) ->
    run_large_message_bench(large_4k, 4096, 200, Config).

large_16k(Config) ->
    run_large_message_bench(large_16k, 16384, 100, Config).

large_64k(Config) ->
    run_large_message_bench(large_64k, 65536, 50, Config).

%%====================================================================
%% Helpers
%%====================================================================

%% @doc Benchmark generate requests with a large prompt through the coordinator.
%% ASSUMPTION: Mock adapter produces 5 tokens per generate request regardless
%% of prompt size.
run_large_message_bench(Name, PromptSize, Iterations, Config) ->
    CoordPid = ?config(coord_pid, Config),
    TokensPerRequest = 5,
    Prompt = binary:copy(<<"x">>, PromptSize),
    Samples = lists:map(fun(_) ->
        T0 = erlang:monotonic_time(microsecond),
        {ok, ReqId} = loom_engine_coordinator:generate(
            CoordPid, Prompt, #{max_tokens => 100}),
        collect_coordinator_tokens(ReqId, TokensPerRequest),
        receive
            {loom_done, ReqId, _Stats} ->
                erlang:monotonic_time(microsecond) - T0
        after 10000 ->
            ct:fail({large_msg_done_timeout, Name})
        end
    end, lists:seq(1, Iterations)),
    store_result(Name, Samples).

%% @doc Time N iterations of Fun, return list of microsecond timings.
time_iterations(Fun, N) ->
    lists:map(fun(_) ->
        T0 = erlang:monotonic_time(microsecond),
        Fun(),
        erlang:monotonic_time(microsecond) - T0
    end, lists:seq(1, N)).

%% @doc Store benchmark result in the shared ETS table.
store_result(Name, Samples) ->
    Stats = loom_bench_stats:calculate(Samples),
    true = ets:insert(loom_bench_results, {Name, Stats}).

%% @doc Path to the mock adapter script.
mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

%% @doc Python 3 executable path.
python_cmd() ->
    os:find_executable("python3").

%% @doc Path to test fixture file.
%% ASSUMPTION: ?FILE resolves to the absolute path of this source file at
%% compile time. Since this suite lives in test/bench/, fixtures are one
%% level up at test/fixtures/.
fixture_path(Filename) ->
    TestDir = filename:dirname(filename:dirname(?FILE)),
    filename:join([TestDir, "fixtures", Filename]).

%% @doc Poll coordinator status until ready or timeout.
wait_coordinator_ready(EngineId, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_status(EngineId) of
        ready -> ok;
        _ ->
            timer:sleep(50),
            wait_coordinator_ready(EngineId, Timeout - 50)
    end;
wait_coordinator_ready(EngineId, _Timeout) ->
    ct:fail({coordinator_ready_timeout, EngineId}).

%% @doc Wait for a process to terminate.
wait_process_dead(Pid, Timeout) when Timeout > 0 ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            timer:sleep(50),
            wait_process_dead(Pid, Timeout - 50)
    end;
wait_process_dead(Pid, _Timeout) ->
    ct:fail({process_still_alive, Pid}).

%% @doc Log threshold check results.
log_threshold_results(Results) ->
    Passed = length([R || {_, pass, _} = R <- Results]),
    Failed = length([R || {_, fail, _} = R <- Results]),
    Total = Passed + Failed,
    lists:foreach(fun
        ({Name, pass, _}) ->
            ct:pal("[PASS] ~s", [Name]);
        ({Name, fail, Violations}) ->
            lists:foreach(fun({Metric, Actual, Limit}) ->
                ct:pal("[WARN] ~s.~s: ~s >= ~s (limit)",
                    [Name, Metric,
                     loom_bench_stats:format_duration(Actual),
                     loom_bench_stats:format_duration(Limit)])
            end, Violations)
    end, Results),
    ct:pal("Threshold checks: ~B/~B PASS", [Passed, Total]).

%% @doc Long-lived keeper process that owns loom_engine_coordinator across CT
%% process boundaries.
%%
%% CT runs init_per_group, each test case, and end_per_group in separate
%% processes. gen_statem:start_link records the calling process as the OTP
%% parent. When CT tears down a group it sends a non-normal exit to the
%% init_per_group process; that exit propagates via the parent relationship
%% and kills the coordinator before the test cases run.
%%
%% This keeper is spawned with plain spawn/1 (no link) from init_per_group,
%% becomes the coordinator parent via start_link, and lives until end_per_group
%% sends it a stop message.
%%
%% Protocol:
%%   stop  — shut down the keeper (coordinator is already stopped by then)
%%
%% On startup the caller (init_per_group process) receives:
%%   {coord_keeper_ready, KeeperPid, CoordPid}
coord_keeper(Caller, CoordConfig, EngineId) ->
    process_flag(trap_exit, true),
    {ok, Pid} = loom_engine_coordinator:start_link(CoordConfig),
    wait_coordinator_ready(EngineId, 10000),
    Caller ! {coord_keeper_ready, self(), Pid},
    receive stop -> ok end.

%% @doc Long-lived keeper process that owns loom_port across CT process boundaries.
%%
%% CT runs init_per_group, each test case, and end_per_group in separate OS
%% processes. loom_port monitors its owner and shuts down when the owner dies.
%% This keeper stays alive for the entire group, forwarding port messages to
%% whichever test case PID last sent {register, Pid}.
%%
%% Protocol:
%%   {register, Pid}  — set the forward target
%%   stop             — shut down the keeper
%%
%% On startup the caller (init_per_group process) receives:
%%   {port_owner_keeper_ready, KeeperPid, PortPid, PortRef}
port_owner_keeper(Caller) ->
    Opts = #{
        command => python_cmd(),
        args => [mock_adapter_path(), "--token-delay", "0",
                 "--startup-delay", "0", "--heartbeat-interval", "5"],
        owner => self(),
        spawn_timeout_ms => 10000,
        heartbeat_timeout_ms => 15000,
        max_line_length => 1048576
    },
    {ok, Pid} = loom_port:start_link(Opts),
    Ref = receive
        {loom_port_ready, R, _Model, _Backend} -> R
    after 15000 ->
        ct:fail(port_keeper_ready_timeout)
    end,
    Caller ! {port_owner_keeper_ready, self(), Pid, Ref},
    port_owner_keeper_loop(undefined).

port_owner_keeper_loop(Receiver) ->
    receive
        {register, Pid} ->
            port_owner_keeper_loop(Pid);
        stop ->
            ok;
        Msg when Receiver =/= undefined ->
            Receiver ! Msg,
            port_owner_keeper_loop(Receiver);
        _Msg ->
            %% No receiver registered yet — drop
            port_owner_keeper_loop(Receiver)
    end.

%% @doc Collect timestamps for each token arrival from loom_port.
%% Returns list of monotonic timestamps in microseconds.
collect_port_token_timestamps(PortRef, Id, N) ->
    collect_port_token_timestamps(PortRef, Id, N, []).

collect_port_token_timestamps(_PortRef, _Id, 0, Acc) ->
    lists:reverse(Acc);
collect_port_token_timestamps(PortRef, Id, N, Acc) ->
    receive
        {loom_port_msg, PortRef, {token, Id, _, _, _}} ->
            T = erlang:monotonic_time(microsecond),
            collect_port_token_timestamps(PortRef, Id, N - 1, [T | Acc])
    after 5000 ->
        ct:fail({token_timeout, {remaining, N}})
    end.

%% @doc Collect N token messages from the coordinator for a given request.
collect_coordinator_tokens(_ReqId, 0) ->
    ok;
collect_coordinator_tokens(ReqId, N) ->
    receive
        {loom_token, ReqId, _Text, _Finished} ->
            collect_coordinator_tokens(ReqId, N - 1)
    after 5000 ->
        ct:fail({coordinator_token_timeout, {remaining, N}})
    end.

%% @doc Calculate deltas between consecutive timestamps.
%% [T1, T2, T3] -> [T2-T1, T3-T2]
inter_token_deltas([]) -> [];
inter_token_deltas([_]) -> [];
inter_token_deltas(Timestamps) ->
    Pairs = lists:zip(lists:droplast(Timestamps), tl(Timestamps)),
    [B - A || {A, B} <- Pairs].

%% @doc Run N concurrent generate requests for Rounds rounds, collect
%% per-request latency samples. Uses barrier sync so all workers start
%% simultaneously.
%% ASSUMPTION: Mock adapter produces 5 tokens per generate request.
run_concurrent_bench(N, Rounds, Config) ->
    CoordPid = ?config(coord_pid, Config),
    TokensPerRequest = 5,
    AllSamples = lists:flatmap(fun(_Round) ->
        BarrierRef = make_ref(),
        Parent = self(),
        Workers = [spawn_link(fun() ->
            %% Wait for barrier release
            receive {go, BarrierRef} -> ok end,
            T0 = erlang:monotonic_time(microsecond),
            {ok, ReqId} = loom_engine_coordinator:generate(
                CoordPid, <<"bench concurrent">>, #{max_tokens => 100}),
            collect_coordinator_tokens(ReqId, TokensPerRequest),
            receive
                {loom_done, ReqId, _Stats} ->
                    Elapsed = erlang:monotonic_time(microsecond) - T0,
                    Parent ! {bench_done, self(), Elapsed}
            after 30000 ->
                Parent ! {bench_done, self(), timeout}
            end
        end) || _ <- lists:seq(1, N)],
        %% Release all workers simultaneously
        [W ! {go, BarrierRef} || W <- Workers],
        %% Collect results
        lists:map(fun(W) ->
            receive
                {bench_done, W, timeout} -> ct:fail({worker_timeout, W});
                {bench_done, W, Elapsed} -> Elapsed
            after 60000 ->
                ct:fail({collect_timeout, W})
            end
        end, Workers)
    end, lists:seq(1, Rounds)),
    BenchName = list_to_atom("concurrent_" ++ integer_to_list(N)),
    store_result(BenchName, AllSamples).
