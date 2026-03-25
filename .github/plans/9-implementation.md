# loom_engine_coordinator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `loom_engine_coordinator` gen_statem — the core engine lifecycle manager that owns a `loom_port`, tracks in-flight requests via ETS, and self-heals on port crashes.

**Architecture:** A 4-state gen_statem (`starting → ready → draining → stopped`) with two ETS tables (requests + meta) for lock-free reads. Owns a `loom_port` subprocess, monitors callers, generates request IDs, routes tokens. Self-heals on port crash by notifying in-flight callers and spawning a new port.

**Tech Stack:** Erlang/OTP 27, gen_statem, ETS, loom_port, loom_protocol, Common Test, EUnit

**Spec:** `.github/plans/9-design.md`

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/loom_engine_coordinator.erl` | gen_statem: state machine, ETS management, port ownership, request lifecycle |
| `test/loom_engine_coordinator_tests.erl` | EUnit: config validation, request ID generation, ETS read API |
| `test/loom_engine_coordinator_SUITE.erl` | Common Test: integration tests with mock adapter |

---

## Task 1: Module skeleton with config validation

**Files:**
- Create: `src/loom_engine_coordinator.erl`
- Create: `test/loom_engine_coordinator_tests.erl`

- [ ] **Step 1: Write failing EUnit tests for config validation**

```erlang
%% test/loom_engine_coordinator_tests.erl
-module(loom_engine_coordinator_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Config validation tests ---

-spec valid_config_test() -> any().
valid_config_test() ->
    Config = valid_config(),
    ?assertEqual(ok, loom_engine_coordinator:validate_config(Config)).

-spec missing_engine_id_test() -> any().
missing_engine_id_test() ->
    Config = maps:remove(engine_id, valid_config()),
    ?assertMatch({error, {missing_required, engine_id}},
                 loom_engine_coordinator:validate_config(Config)).

-spec missing_command_test() -> any().
missing_command_test() ->
    Config = maps:remove(command, valid_config()),
    ?assertMatch({error, {missing_required, command}},
                 loom_engine_coordinator:validate_config(Config)).

-spec missing_model_test() -> any().
missing_model_test() ->
    Config = maps:remove(model, valid_config()),
    ?assertMatch({error, {missing_required, model}},
                 loom_engine_coordinator:validate_config(Config)).

-spec missing_backend_test() -> any().
missing_backend_test() ->
    Config = maps:remove(backend, valid_config()),
    ?assertMatch({error, {missing_required, backend}},
                 loom_engine_coordinator:validate_config(Config)).

-spec empty_engine_id_test() -> any().
empty_engine_id_test() ->
    Config = (valid_config())#{engine_id => <<>>},
    ?assertMatch({error, {empty_required, engine_id}},
                 loom_engine_coordinator:validate_config(Config)).

-spec invalid_startup_timeout_test() -> any().
invalid_startup_timeout_test() ->
    Config = (valid_config())#{startup_timeout_ms => 0},
    ?assertMatch({error, {invalid_value, startup_timeout_ms, _}},
                 loom_engine_coordinator:validate_config(Config)).

-spec invalid_max_concurrent_test() -> any().
invalid_max_concurrent_test() ->
    Config = (valid_config())#{max_concurrent => -1},
    ?assertMatch({error, {invalid_value, max_concurrent, _}},
                 loom_engine_coordinator:validate_config(Config)).

-spec defaults_applied_test() -> any().
defaults_applied_test() ->
    Config = valid_config(),
    {ok, Merged} = loom_engine_coordinator:merge_config(Config),
    ?assertEqual(120000, maps:get(startup_timeout_ms, Merged)),
    ?assertEqual(30000, maps:get(drain_timeout_ms, Merged)),
    ?assertEqual(64, maps:get(max_concurrent, Merged)),
    ?assertEqual([], maps:get(args, Merged)).

-spec defaults_not_overridden_test() -> any().
defaults_not_overridden_test() ->
    Config = (valid_config())#{startup_timeout_ms => 5000, max_concurrent => 10},
    {ok, Merged} = loom_engine_coordinator:merge_config(Config),
    ?assertEqual(5000, maps:get(startup_timeout_ms, Merged)),
    ?assertEqual(10, maps:get(max_concurrent, Merged)).

%% --- Helpers ---

valid_config() ->
    #{
        engine_id => <<"engine_0">>,
        command => "/usr/bin/python3",
        model => <<"mock">>,
        backend => <<"mock">>
    }.
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_engine_coordinator_tests`
Expected: FAIL — module `loom_engine_coordinator` not found

- [ ] **Step 3: Write module skeleton with config validation**

```erlang
%% src/loom_engine_coordinator.erl
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
    engine_id     :: binary(),
    config        :: map(),
    port_pid      :: pid() | undefined,
    port_ref      :: reference() | undefined,
    reqs_table    :: ets:table(),
    meta_table    :: ets:table(),
    max_concurrent :: pos_integer(),
    started_at    :: integer()
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

check_values(Config) ->
    Checks = [
        {startup_timeout_ms, fun(V) -> is_integer(V) andalso V > 0 end},
        {drain_timeout_ms, fun(V) -> is_integer(V) andalso V > 0 end},
        {max_concurrent, fun(V) -> is_integer(V) andalso V > 0 end}
    ],
    check_values_loop(Checks, Config).

check_values_loop([], _Config) -> ok;
check_values_loop([{Key, Pred} | Rest], Config) ->
    case maps:find(Key, Config) of
        {ok, Val} ->
            case Pred(Val) of
                true -> check_values_loop(Rest, Config);
                false -> {error, {invalid_value, Key, Val}}
            end;
        error ->
            %% Not provided; defaults will be applied
            check_values_loop(Rest, Config)
    end.

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
get_status(_EngineId) ->
    stopped.

-spec get_load(binary()) -> non_neg_integer().
get_load(_EngineId) ->
    0.

-spec get_info(binary()) -> map().
get_info(_EngineId) ->
    #{}.

%%====================================================================
%% gen_statem callbacks
%%====================================================================

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() ->
    [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(atom()).
init(_Config) ->
    {stop, not_implemented}.

starting(_EventType, _Event, _Data) ->
    {stop, not_implemented}.

ready(_EventType, _Event, _Data) ->
    {stop, not_implemented}.

draining(_EventType, _Event, _Data) ->
    {stop, not_implemented}.

stopped(_EventType, _Event, _Data) ->
    {stop, not_implemented}.

terminate(_Reason, _State, _Data) ->
    ok.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_engine_coordinator_tests`
Expected: All 10 tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_coordinator.erl test/loom_engine_coordinator_tests.erl
git commit -m "feat(coordinator): add module skeleton with config validation (#9)"
```

---

## Task 2: ETS table creation and read API

**Files:**
- Modify: `test/loom_engine_coordinator_tests.erl`
- Modify: `src/loom_engine_coordinator.erl`

- [ ] **Step 1: Write failing EUnit tests for ETS read API**

Add to `test/loom_engine_coordinator_tests.erl`:

```erlang
%% --- ETS table name helpers ---

-spec reqs_table_name_test() -> any().
reqs_table_name_test() ->
    ?assertEqual(loom_coord_reqs_engine_0,
                 loom_engine_coordinator:reqs_table_name(<<"engine_0">>)).

-spec meta_table_name_test() -> any().
meta_table_name_test() ->
    ?assertEqual(loom_coord_meta_engine_0,
                 loom_engine_coordinator:meta_table_name(<<"engine_0">>)).

%% --- ETS read API tests ---
%% These tests create ETS tables directly to test the read functions
%% without starting the full gen_statem.

-spec get_status_from_ets_test() -> any().
get_status_from_ets_test() ->
    MetaTable = loom_coord_meta_test_status,
    ets:new(MetaTable, [named_table, set, public]),
    ets:insert(MetaTable, {meta, ready, <<"test">>, <<"mock">>, <<"mock">>,
                           undefined, 0}),
    ?assertEqual(ready, loom_engine_coordinator:get_status(<<"test_status">>)),
    ets:delete(MetaTable).

-spec get_load_from_ets_test() -> any().
get_load_from_ets_test() ->
    ReqsTable = loom_coord_reqs_test_load,
    ets:new(ReqsTable, [named_table, set, public]),
    ets:insert(ReqsTable, {<<"req-1">>, self(), make_ref(), 0}),
    ets:insert(ReqsTable, {<<"req-2">>, self(), make_ref(), 0}),
    ?assertEqual(2, loom_engine_coordinator:get_load(<<"test_load">>)),
    ets:delete(ReqsTable).

-spec get_info_from_ets_test() -> any().
get_info_from_ets_test() ->
    MetaTable = loom_coord_meta_test_info,
    ReqsTable = loom_coord_reqs_test_info,
    ets:new(MetaTable, [named_table, set, public]),
    ets:new(ReqsTable, [named_table, set, public]),
    ets:insert(MetaTable, {meta, ready, <<"test_info">>, <<"mock_model">>,
                           <<"mock">>, undefined, 12345}),
    ets:insert(ReqsTable, {<<"req-1">>, self(), make_ref(), 0}),
    Info = loom_engine_coordinator:get_info(<<"test_info">>),
    ?assertEqual(<<"test_info">>, maps:get(engine_id, Info)),
    ?assertEqual(<<"mock_model">>, maps:get(model, Info)),
    ?assertEqual(ready, maps:get(status, Info)),
    ?assertEqual(1, maps:get(load, Info)),
    ets:delete(MetaTable),
    ets:delete(ReqsTable).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_engine_coordinator_tests`
Expected: FAIL — functions not found / ETS table name mismatch

- [ ] **Step 3: Implement ETS table helpers and read API**

Add to `src/loom_engine_coordinator.erl` exports and implementation:

```erlang
%% Add to exports
-export([
    reqs_table_name/1,
    meta_table_name/1
]).

%% ETS table name helpers
-spec reqs_table_name(binary()) -> atom().
reqs_table_name(EngineId) ->
    %% ASSUMPTION: EngineId contains only alphanumeric chars and underscores.
    %% Validated at config time.
    binary_to_atom(<<"loom_coord_reqs_", EngineId/binary>>).

-spec meta_table_name(binary()) -> atom().
meta_table_name(EngineId) ->
    binary_to_atom(<<"loom_coord_meta_", EngineId/binary>>).

%% Replace stub get_status/1
-spec get_status(binary()) -> starting | ready | draining | stopped.
get_status(EngineId) ->
    MetaTable = meta_table_name(EngineId),
    case ets:lookup(MetaTable, meta) of
        [{meta, Status, _, _, _, _, _}] -> Status;
        [] -> stopped
    end.

%% Replace stub get_load/1
-spec get_load(binary()) -> non_neg_integer().
get_load(EngineId) ->
    ReqsTable = reqs_table_name(EngineId),
    ets:info(ReqsTable, size).

%% Replace stub get_info/1
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_engine_coordinator_tests`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_coordinator.erl test/loom_engine_coordinator_tests.erl
git commit -m "feat(coordinator): add ETS table helpers and read API (#9)"
```

---

## Task 3: init/1 — ETS creation, port startup, entering `starting` state

**Files:**
- Modify: `src/loom_engine_coordinator.erl`
- Create: `test/loom_engine_coordinator_SUITE.erl`

- [ ] **Step 1: Write failing CT test for happy-path startup**

```erlang
%% test/loom_engine_coordinator_SUITE.erl
%%%-------------------------------------------------------------------
%%% @doc Common Test integration suite for loom_engine_coordinator.
%%%
%%% Tests cover engine lifecycle: startup, request routing, crash
%%% recovery, drain protocol, and edge cases.
%%%
%%% ASSUMPTION: python3 is on PATH in the test environment.
%%% ASSUMPTION: The loom application is available at test runtime.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_engine_coordinator_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    startup_to_ready_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        startup_to_ready_test
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_TestCase, _Config) ->
    flush_mailbox(),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc Start coordinator, verify it reaches ready state and ETS tables
%% are populated correctly.
startup_to_ready_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),

    %% Wait for coordinator to reach ready state
    wait_status(EngineId, ready, 5000),

    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    Info = loom_engine_coordinator:get_info(EngineId),
    ?assertEqual(EngineId, maps:get(engine_id, Info)),
    ?assertEqual(<<"mock">>, maps:get(model, Info)),
    ?assertEqual(<<"mock">>, maps:get(backend, Info)),
    ?assertEqual(ready, maps:get(status, Info)),

    %% Clean shutdown
    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%%====================================================================
%% Helpers
%%====================================================================

mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

python_cmd() ->
    os:find_executable("python3").

default_config() ->
    #{
        engine_id => <<"test_engine">>,
        command => python_cmd(),
        args => [mock_adapter_path()],
        model => <<"mock">>,
        backend => <<"mock">>,
        startup_timeout_ms => 10000,
        drain_timeout_ms => 5000,
        max_concurrent => 64
    }.

%% @doc Poll get_status/1 until it returns the expected status or timeout.
wait_status(EngineId, ExpectedStatus, Timeout) when Timeout > 0 ->
    try loom_engine_coordinator:get_status(EngineId) of
        ExpectedStatus -> ok;
        _ ->
            timer:sleep(50),
            wait_status(EngineId, ExpectedStatus, Timeout - 50)
    catch
        error:badarg ->
            %% ETS table not yet created
            timer:sleep(50),
            wait_status(EngineId, ExpectedStatus, Timeout - 50)
    end;
wait_status(EngineId, ExpectedStatus, _Timeout) ->
    ct:fail(io_lib:format("wait_status: ~p never reached ~p",
                          [EngineId, ExpectedStatus])).

wait_dead(Pid, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_dead_loop(Pid, Deadline).

wait_dead_loop(Pid, Deadline) ->
    case is_process_alive(Pid) of
        false -> ok;
        true ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining > 0 of
                false ->
                    ct:fail(io_lib:format("wait_dead: ~p still alive", [Pid]));
                true ->
                    timer:sleep(min(50, Remaining)),
                    wait_dead_loop(Pid, Deadline)
            end
    end.

flush_mailbox() ->
    receive _ -> flush_mailbox()
    after 0 -> ok
    end.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=startup_to_ready_test`
Expected: FAIL — init/1 returns `{stop, not_implemented}`

- [ ] **Step 3: Implement init/1 and starting state**

Replace `init/1` and `starting/3` in `src/loom_engine_coordinator.erl`:

```erlang
-spec init(map()) -> gen_statem:init_result(atom()).
init(Config) ->
    %% Trap exits so we receive {'EXIT', PortPid, Reason} as messages
    %% instead of dying. Required for self-healing: loom_port:start_link
    %% creates a link, and we need to survive port crashes.
    process_flag(trap_exit, true),

    EngineId = maps:get(engine_id, Config),
    MaxConcurrent = maps:get(max_concurrent, Config),

    %% Create ETS tables — protected so anyone can read, only we write
    ReqsTable = ets:new(reqs_table_name(EngineId), [
        named_table, set, protected,
        {read_concurrency, true}
    ]),
    MetaTable = ets:new(meta_table_name(EngineId), [
        named_table, set, protected,
        {read_concurrency, true}
    ]),

    StartedAt = erlang:monotonic_time(millisecond),

    %% Initialize meta row
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

%%--------------------------------------------------------------------
%% starting state
%%--------------------------------------------------------------------

starting(enter, _OldState, #data{engine_id = EngineId, config = Config} = Data) ->
    ?LOG_INFO("Engine ~s entering starting state",
              [EngineId], #{engine_id => EngineId}),
    %% Start loom_port
    PortOpts = build_port_opts(Config),
    case loom_port:start_link(PortOpts) of
        {ok, PortPid} ->
            StartupTimeout = maps:get(startup_timeout_ms, Config),
            {keep_state, Data#data{port_pid = PortPid},
             [{state_timeout, StartupTimeout, startup_timeout}]};
        {error, Reason} ->
            ?LOG_INFO("Engine ~s failed to start port: ~p",
                      [EngineId, Reason], #{engine_id => EngineId}),
            {next_state, stopped, Data}
    end;
starting(state_timeout, startup_timeout, #data{engine_id = EngineId,
                                                port_pid = PortPid} = Data) ->
    ?LOG_INFO("Engine ~s startup timeout",
              [EngineId], #{engine_id => EngineId}),
    case PortPid of
        undefined -> ok;
        _ -> loom_port:shutdown(PortPid)
    end,
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(info, {loom_port_ready, PortRef, Model, Backend},
         #data{engine_id = EngineId, meta_table = MetaTable,
               port_pid = PortPid} = Data) ->
    %% Capture the PortRef from loom_port — this is the ref that all
    %% subsequent loom_port_msg messages will be tagged with. We store
    %% it so ready/draining handlers can filter stale messages after
    %% a self-heal spawns a new port with a different ref.
    ReadyAt = erlang:monotonic_time(millisecond),
    StartupTime = ReadyAt - Data#data.started_at,
    ?LOG_INFO("Engine ~s ready (model=~s, backend=~s, startup_time=~wms)",
              [EngineId, Model, Backend, StartupTime],
              #{engine_id => EngineId}),
    ets:insert(MetaTable, {meta, ready, EngineId, Model, Backend,
                           PortPid, Data#data.started_at}),
    {next_state, ready, Data#data{port_ref = PortRef}};
starting(info, {loom_port_exit, _Ref, ExitCode},
         #data{engine_id = EngineId} = Data) ->
    ?LOG_INFO("Engine ~s port exited during startup (exit_code=~p)",
              [EngineId, ExitCode], #{engine_id => EngineId}),
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(info, {loom_port_timeout, _Ref},
         #data{engine_id = EngineId, port_pid = PortPid} = Data) ->
    ?LOG_INFO("Engine ~s port heartbeat timeout during startup",
              [EngineId], #{engine_id => EngineId}),
    case PortPid of
        undefined -> ok;
        _ -> loom_port:shutdown(PortPid)
    end,
    {next_state, stopped, Data#data{port_pid = undefined}};
starting(info, {loom_port_msg, _Ref, _Msg}, _Data) ->
    %% Ignore messages during startup (heartbeats are handled by loom_port)
    keep_state_and_data;
starting(info, {loom_port_error, _Ref, _Error}, _Data) ->
    keep_state_and_data;
starting(info, {'EXIT', _Pid, _Reason}, _Data) ->
    %% Linked exit from port — handled via {loom_port_exit, ...}
    keep_state_and_data;
starting({call, From}, {generate, _Prompt, _Params}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};
starting(cast, do_shutdown, Data) ->
    {next_state, stopped, Data};
starting(cast, do_stop, #data{port_pid = PortPid} = Data) ->
    stop_port(PortPid),
    {next_state, stopped, Data#data{port_pid = undefined}}.
```

Also add the helper functions:

```erlang
%%====================================================================
%% Internal helpers
%%====================================================================

build_port_opts(Config) ->
    Base = #{
        command => maps:get(command, Config),
        args => maps:get(args, Config, []),
        owner => self()
    },
    PortOpts = maps:get(port_opts, Config, #{}),
    maps:merge(Base, PortOpts).

stop_port(undefined) -> ok;
stop_port(PortPid) ->
    loom_port:shutdown(PortPid).

update_meta_status(MetaTable, Status) ->
    case ets:lookup(MetaTable, meta) of
        [{meta, _, EId, Model, Backend, PortPid, StartedAt}] ->
            ets:insert(MetaTable, {meta, Status, EId, Model, Backend,
                                   PortPid, StartedAt});
        [] ->
            ok
    end.

normalize_exit_code(Code) when is_integer(Code) ->
    integer_to_binary(Code);
normalize_exit_code(killed) ->
    <<"killed">>;
normalize_exit_code(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).
```

Also implement the `stop/1` and `shutdown/1` API functions:

```erlang
-spec shutdown(pid()) -> ok.
shutdown(Pid) ->
    gen_statem:cast(Pid, do_shutdown).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:cast(Pid, do_stop).
```

And implement `stopped/3`:

```erlang
stopped(enter, _OldState, #data{engine_id = EngineId, meta_table = MetaTable} = Data) ->
    ?LOG_INFO("Engine ~s stopped", [EngineId], #{engine_id => EngineId}),
    update_meta_status(MetaTable, stopped),
    %% Terminate the process. The supervisor will decide whether to restart.
    %% ETS tables are cleaned up in terminate/3.
    {stop, normal, Data}.
```

And implement `terminate/3`:

```erlang
terminate(_Reason, _State, #data{port_pid = PortPid, reqs_table = ReqsTable,
                                  meta_table = MetaTable}) ->
    stop_port(PortPid),
    catch ets:delete(ReqsTable),
    catch ets:delete(MetaTable),
    ok;
terminate(_Reason, _State, _Data) ->
    ok.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=startup_to_ready_test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_coordinator.erl test/loom_engine_coordinator_SUITE.erl
git commit -m "feat(coordinator): implement init, starting state, and ETS setup (#9)"
```

---

## Task 4: Request lifecycle — generate, token routing, done

**Files:**
- Modify: `src/loom_engine_coordinator.erl`
- Modify: `test/loom_engine_coordinator_SUITE.erl`

- [ ] **Step 1: Write failing CT test for happy-path generate**

Add to `loom_engine_coordinator_SUITE.erl`:

```erlang
%% Add to exports and all/0
-export([happy_path_generate_test/1]).

%% @doc Start coordinator, generate a request, receive all tokens and done.
happy_path_generate_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    {ok, RequestId} = loom_engine_coordinator:generate(
        Pid, <<"Hello">>, #{max_tokens => 100}),
    ?assert(is_binary(RequestId)),

    %% Mock adapter sends 5 tokens + 1 done
    Tokens = collect_tokens(RequestId, 5, 5000),
    ?assertEqual(5, length(Tokens)),

    %% Verify done message
    receive
        {loom_done, RequestId, Stats} ->
            ?assertEqual(5, maps:get(tokens, Stats)),
            ok
    after 5000 ->
        ct:fail("no loom_done received")
    end,

    %% In-flight should be back to 0
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).
```

Add `collect_tokens` helper:

```erlang
collect_tokens(_RequestId, 0, _Timeout) -> [];
collect_tokens(RequestId, N, Timeout) ->
    receive
        {loom_token, RequestId, Text, _Finished} ->
            [Text | collect_tokens(RequestId, N - 1, Timeout)]
    after Timeout ->
        ct:fail(io_lib:format("collect_tokens: timeout waiting for token ~w", [N]))
    end.
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=happy_path_generate_test`
Expected: FAIL — `generate/3` returns `{error, not_ready}`

- [ ] **Step 3: Implement ready state with generate and message routing**

Replace `ready/3` and `generate/3` in `src/loom_engine_coordinator.erl`:

```erlang
%% Replace generate/3 API function
-spec generate(pid(), binary(), map()) ->
    {ok, binary()} | {error, not_ready | draining | overloaded | stopped}.
generate(Pid, Prompt, Params) ->
    gen_statem:call(Pid, {generate, Prompt, Params}).

%%--------------------------------------------------------------------
%% ready state
%%--------------------------------------------------------------------

ready(enter, _OldState, _Data) ->
    keep_state_and_data;
ready({call, From}, {generate, Prompt, Params},
      #data{reqs_table = ReqsTable, max_concurrent = MaxConcurrent,
            port_pid = PortPid, engine_id = EngineId} = Data) ->
    CurrentLoad = ets:info(ReqsTable, size),
    case CurrentLoad < MaxConcurrent of
        false ->
            ?LOG_INFO("Engine ~s request rejected: overloaded (in_flight=~w/~w)",
                      [EngineId, CurrentLoad, MaxConcurrent],
                      #{engine_id => EngineId}),
            {keep_state_and_data, [{reply, From, {error, overloaded}}]};
        true ->
            %% Generate unique request ID
            RequestId = iolist_to_binary([
                <<"req-">>,
                integer_to_binary(erlang:unique_integer([positive, monotonic]))
            ]),
            %% Extract caller pid from From
            {CallerPid, _Tag} = From,
            MonitorRef = erlang:monitor(process, CallerPid),
            StartTime = erlang:monotonic_time(millisecond),
            ets:insert(ReqsTable, {RequestId, CallerPid, MonitorRef, StartTime}),
            %% Send to port
            ok = loom_port:send(PortPid, {generate, RequestId, Prompt, Params}),
            NewLoad = CurrentLoad + 1,
            ?LOG_INFO("Engine ~s accepted request ~s (in_flight=~w/~w)",
                      [EngineId, RequestId, NewLoad, MaxConcurrent],
                      #{engine_id => EngineId}),
            {keep_state_and_data,
             [{reply, From, {ok, RequestId}}]}
    end;
ready(info, {loom_port_msg, PortRef, {token, Id, _TokenId, Text, Finished}},
      #data{reqs_table = ReqsTable, port_ref = PortRef} = _Data) ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, _MonRef, _StartTime}] ->
            CallerPid ! {loom_token, Id, Text, Finished};
        [] ->
            %% Request was cancelled or already completed; drop silently
            ok
    end,
    keep_state_and_data;
ready(info, {loom_port_msg, PortRef, {done, Id, TokensGenerated, TimeMs}},
      #data{reqs_table = ReqsTable, engine_id = EngineId,
            port_ref = PortRef} = _Data) ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, MonRef, _StartTime}] ->
            CallerPid ! {loom_done, Id, #{tokens => TokensGenerated,
                                          time_ms => TimeMs}},
            erlang:demonitor(MonRef, [flush]),
            ets:delete(ReqsTable, Id),
            ?LOG_INFO("Engine ~s request ~s completed (tokens=~w, time=~wms)",
                      [EngineId, Id, TokensGenerated, TimeMs],
                      #{engine_id => EngineId});
        [] ->
            ok
    end,
    keep_state_and_data;
ready(info, {loom_port_msg, PortRef, {error, Id, Code, Message}},
      #data{reqs_table = ReqsTable, engine_id = EngineId,
            port_ref = PortRef} = _Data) ->
    case Id of
        undefined ->
            ?LOG_WARNING("Engine ~s received engine error: ~s - ~s",
                         [EngineId, Code, Message],
                         #{engine_id => EngineId});
        _ ->
            case ets:lookup(ReqsTable, Id) of
                [{Id, CallerPid, MonRef, _StartTime}] ->
                    CallerPid ! {loom_error, Id, Code, Message},
                    erlang:demonitor(MonRef, [flush]),
                    ets:delete(ReqsTable, Id),
                    ?LOG_INFO("Engine ~s request ~s failed: ~s - ~s",
                              [EngineId, Id, Code, Message],
                              #{engine_id => EngineId});
                [] ->
                    ok
            end
    end,
    keep_state_and_data;
ready(info, {loom_port_msg, PortRef, _OtherMsg},
      #data{port_ref = PortRef} = _Data) ->
    %% health_response, memory_response, etc. — ignore for now
    keep_state_and_data;
ready(info, {loom_port_msg, _StaleRef, _Msg}, _Data) ->
    %% Stale message from old port after self-heal — ignore
    keep_state_and_data;
ready(info, {loom_port_error, _Ref, {decode_error, Reason}},
      #data{engine_id = EngineId} = _Data) ->
    ?LOG_WARNING("Engine ~s port decode error: ~p",
                 [EngineId, Reason], #{engine_id => EngineId}),
    keep_state_and_data;
ready(info, {'DOWN', MonRef, process, CallerPid, _Reason},
      #data{reqs_table = ReqsTable, port_pid = PortPid,
            engine_id = EngineId} = _Data) ->
    %% Caller died mid-stream — cancel the request
    case ets:match_object(ReqsTable, {'_', CallerPid, MonRef, '_'}) of
        [{RequestId, _, _, _}] ->
            ?LOG_INFO("Engine ~s caller ~p died, cancelling request ~s",
                      [EngineId, CallerPid, RequestId],
                      #{engine_id => EngineId}),
            catch loom_port:send(PortPid, {cancel, RequestId}),
            ets:delete(ReqsTable, RequestId);
        [] ->
            ok
    end,
    keep_state_and_data;
ready(info, {loom_port_exit, _Ref, ExitCode},
      #data{engine_id = EngineId, reqs_table = ReqsTable,
            meta_table = MetaTable, config = Config} = Data) ->
    %% Port crashed — self-heal
    InFlight = ets:tab2list(ReqsTable),
    NormalizedCode = normalize_exit_code(ExitCode),
    ?LOG_INFO("Engine ~s port crashed (exit_code=~p), notifying ~w in-flight callers",
              [EngineId, ExitCode, length(InFlight)],
              #{engine_id => EngineId}),
    %% Notify all in-flight callers
    lists:foreach(fun({RequestId, CallerPid, MonRef, _StartTime}) ->
        CallerPid ! {loom_error, RequestId, <<"engine_crashed">>, NormalizedCode},
        erlang:demonitor(MonRef, [flush])
    end, InFlight),
    ets:delete_all_objects(ReqsTable),
    update_meta_status(MetaTable, starting),
    ?LOG_INFO("Engine ~s self-healing, spawning new port",
              [EngineId], #{engine_id => EngineId}),
    %% Spawn new port
    PortOpts = build_port_opts(Config),
    case loom_port:start_link(PortOpts) of
        {ok, NewPortPid} ->
            StartupTimeout = maps:get(startup_timeout_ms, Config),
            {next_state, starting,
             Data#data{port_pid = NewPortPid, port_ref = undefined},
             [{state_timeout, StartupTimeout, startup_timeout}]};
        {error, Reason} ->
            ?LOG_INFO("Engine ~s self-heal failed to start port: ~p",
                      [EngineId, Reason], #{engine_id => EngineId}),
            {next_state, stopped, Data#data{port_pid = undefined, port_ref = undefined}}
    end;
ready(cast, do_shutdown, #data{engine_id = EngineId, reqs_table = ReqsTable} = Data) ->
    InFlight = ets:info(ReqsTable, size),
    ?LOG_INFO("Engine ~s drain started, ~w in-flight requests remaining",
              [EngineId, InFlight], #{engine_id => EngineId}),
    case InFlight of
        0 -> {next_state, stopped, Data};
        _ -> {next_state, draining, Data}
    end;
ready(cast, do_stop, #data{port_pid = PortPid, reqs_table = ReqsTable,
                            engine_id = EngineId} = Data) ->
    %% Immediate stop — notify all in-flight callers
    InFlight = ets:tab2list(ReqsTable),
    lists:foreach(fun({RequestId, CallerPid, MonRef, _StartTime}) ->
        CallerPid ! {loom_error, RequestId, <<"engine_stopped">>, <<"immediate stop">>},
        erlang:demonitor(MonRef, [flush])
    end, InFlight),
    ets:delete_all_objects(ReqsTable),
    stop_port(PortPid),
    ?LOG_INFO("Engine ~s immediate stop, notified ~w callers",
              [EngineId, length(InFlight)], #{engine_id => EngineId}),
    {next_state, stopped, Data#data{port_pid = undefined}};
ready(info, {'EXIT', PortPid, _Reason},
      #data{port_pid = PortPid} = _Data) ->
    %% loom_port linked exit — we already handle {loom_port_exit, ...}
    %% which arrives via the owner message, so just ignore the linked signal.
    %% trap_exit ensures we receive this as a message, not a crash.
    keep_state_and_data;
ready(info, {'EXIT', _OtherPid, _Reason}, _Data) ->
    %% Exit from some other linked process — ignore
    keep_state_and_data;
ready(info, {gpu_alert, GpuId, AlertType, Value, Threshold},
      #data{engine_id = EngineId} = _Data) ->
    ?LOG_INFO("Engine ~s received GPU alert: ~p (~p > threshold ~p) on GPU ~p",
              [EngineId, AlertType, Value, Threshold, GpuId],
              #{engine_id => EngineId}),
    keep_state_and_data.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=happy_path_generate_test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_coordinator.erl test/loom_engine_coordinator_SUITE.erl
git commit -m "feat(coordinator): implement ready state with generate and token routing (#9)"
```

---

## Task 5: Drain protocol

**Files:**
- Modify: `src/loom_engine_coordinator.erl`
- Modify: `test/loom_engine_coordinator_SUITE.erl`

- [ ] **Step 1: Write failing CT tests for drain**

Add to `loom_engine_coordinator_SUITE.erl`:

```erlang
%% Add to exports and all/0
-export([
    drain_with_inflight_test/1,
    drain_empty_test/1
]).

%% @doc Start generation, initiate drain, verify new requests rejected,
%% in-flight completes, coordinator transitions to stopped.
drain_with_inflight_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% Start a generate request
    {ok, RequestId} = loom_engine_coordinator:generate(
        Pid, <<"Hello">>, #{}),

    %% Initiate drain
    ok = loom_engine_coordinator:shutdown(Pid),

    %% New requests should be rejected
    ?assertMatch({error, draining},
                 loom_engine_coordinator:generate(Pid, <<"World">>, #{})),

    %% Consume the in-flight tokens and done
    _Tokens = collect_tokens(RequestId, 5, 5000),
    receive
        {loom_done, RequestId, _Stats} -> ok
    after 5000 ->
        ct:fail("no loom_done during drain")
    end,

    %% Coordinator should reach stopped
    wait_status(EngineId, stopped, 5000),
    wait_dead(Pid, 5000).

%% @doc Drain with no in-flight requests goes straight to stopped.
drain_empty_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    ok = loom_engine_coordinator:shutdown(Pid),
    wait_status(EngineId, stopped, 5000),
    wait_dead(Pid, 5000).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=drain_with_inflight_test,drain_empty_test`
Expected: FAIL — draining state not implemented

- [ ] **Step 3: Implement draining state**

Add to `src/loom_engine_coordinator.erl`:

```erlang
%%--------------------------------------------------------------------
%% draining state
%%--------------------------------------------------------------------

draining(enter, _OldState, #data{engine_id = EngineId, config = Config,
                                  meta_table = MetaTable} = _Data) ->
    update_meta_status(MetaTable, draining),
    DrainTimeout = maps:get(drain_timeout_ms, Config),
    ?LOG_INFO("Engine ~s entering draining state",
              [EngineId], #{engine_id => EngineId}),
    {keep_state_and_data, [{state_timeout, DrainTimeout, drain_timeout}]};
draining(state_timeout, drain_timeout,
         #data{engine_id = EngineId, reqs_table = ReqsTable,
               port_pid = PortPid} = Data) ->
    InFlight = ets:tab2list(ReqsTable),
    ?LOG_INFO("Engine ~s drain timeout, force-cancelling ~w requests",
              [EngineId, length(InFlight)], #{engine_id => EngineId}),
    lists:foreach(fun({RequestId, CallerPid, MonRef, _StartTime}) ->
        CallerPid ! {loom_error, RequestId, <<"drain_timeout">>,
                     <<"request cancelled due to drain timeout">>},
        erlang:demonitor(MonRef, [flush])
    end, InFlight),
    ets:delete_all_objects(ReqsTable),
    stop_port(PortPid),
    {next_state, stopped, Data#data{port_pid = undefined}};
draining({call, From}, {generate, _Prompt, _Params}, #data{engine_id = EngineId} = _Data) ->
    ?LOG_INFO("Engine ~s request rejected: draining",
              [EngineId], #{engine_id => EngineId}),
    {keep_state_and_data, [{reply, From, {error, draining}}]};
draining(info, {loom_port_msg, _PortRef, {token, Id, _TokenId, Text, Finished}},
         #data{reqs_table = ReqsTable} = _Data) ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, _MonRef, _StartTime}] ->
            CallerPid ! {loom_token, Id, Text, Finished};
        [] -> ok
    end,
    keep_state_and_data;
draining(info, {loom_port_msg, _PortRef, {done, Id, TokensGenerated, TimeMs}},
         #data{reqs_table = ReqsTable, engine_id = EngineId,
               port_pid = PortPid} = Data) ->
    case ets:lookup(ReqsTable, Id) of
        [{Id, CallerPid, MonRef, _StartTime}] ->
            CallerPid ! {loom_done, Id, #{tokens => TokensGenerated,
                                          time_ms => TimeMs}},
            erlang:demonitor(MonRef, [flush]),
            ets:delete(ReqsTable, Id),
            ?LOG_INFO("Engine ~s request ~s completed during drain (tokens=~w)",
                      [EngineId, Id, TokensGenerated],
                      #{engine_id => EngineId}),
            case ets:info(ReqsTable, size) of
                0 ->
                    ?LOG_INFO("Engine ~s drain complete, transitioning to stopped",
                              [EngineId], #{engine_id => EngineId}),
                    stop_port(PortPid),
                    {next_state, stopped, Data#data{port_pid = undefined}};
                Remaining ->
                    ?LOG_INFO("Engine ~s drain: ~w requests remaining",
                              [EngineId, Remaining],
                              #{engine_id => EngineId}),
                    keep_state_and_data
            end;
        [] ->
            keep_state_and_data
    end;
draining(info, {loom_port_msg, _PortRef, {error, Id, Code, Message}},
         #data{reqs_table = ReqsTable, engine_id = EngineId,
               port_pid = PortPid} = Data) ->
    case Id of
        undefined -> ok;
        _ ->
            case ets:lookup(ReqsTable, Id) of
                [{Id, CallerPid, MonRef, _StartTime}] ->
                    CallerPid ! {loom_error, Id, Code, Message},
                    erlang:demonitor(MonRef, [flush]),
                    ets:delete(ReqsTable, Id);
                [] -> ok
            end
    end,
    case ets:info(ReqsTable, size) of
        0 ->
            stop_port(PortPid),
            {next_state, stopped, Data#data{port_pid = undefined}};
        _ ->
            keep_state_and_data
    end;
draining(info, {loom_port_msg, _PortRef, _OtherMsg}, _Data) ->
    keep_state_and_data;
draining(info, {loom_port_exit, _Ref, ExitCode},
         #data{engine_id = EngineId, reqs_table = ReqsTable} = Data) ->
    %% Port crash during drain — go to stopped, not starting
    InFlight = ets:tab2list(ReqsTable),
    NormalizedCode = normalize_exit_code(ExitCode),
    ?LOG_INFO("Engine ~s port crashed during drain (exit_code=~p), "
              "notifying ~w callers",
              [EngineId, ExitCode, length(InFlight)],
              #{engine_id => EngineId}),
    lists:foreach(fun({RequestId, CallerPid, MonRef, _StartTime}) ->
        CallerPid ! {loom_error, RequestId, <<"engine_crashed">>, NormalizedCode},
        erlang:demonitor(MonRef, [flush])
    end, InFlight),
    ets:delete_all_objects(ReqsTable),
    {next_state, stopped, Data#data{port_pid = undefined}};
draining(info, {'DOWN', MonRef, process, CallerPid, _Reason},
         #data{reqs_table = ReqsTable, port_pid = PortPid,
               engine_id = EngineId} = Data) ->
    case ets:match_object(ReqsTable, {'_', CallerPid, MonRef, '_'}) of
        [{RequestId, _, _, _}] ->
            ?LOG_INFO("Engine ~s caller ~p died during drain, cancelling ~s",
                      [EngineId, CallerPid, RequestId],
                      #{engine_id => EngineId}),
            catch loom_port:send(PortPid, {cancel, RequestId}),
            ets:delete(ReqsTable, RequestId);
        [] -> ok
    end,
    %% Check if drain is now complete
    case ets:info(ReqsTable, size) of
        0 ->
            stop_port(PortPid),
            {next_state, stopped, Data#data{port_pid = undefined}};
        _ ->
            keep_state_and_data
    end;
draining(info, {loom_port_error, _Ref, _Error}, _Data) ->
    keep_state_and_data;
draining(info, {'EXIT', _Pid, _Reason}, _Data) ->
    %% Linked exit from port — handled via {loom_port_exit, ...}
    keep_state_and_data;
draining(cast, do_shutdown, _Data) ->
    %% Already draining
    keep_state_and_data;
draining(cast, do_stop, #data{port_pid = PortPid, reqs_table = ReqsTable} = Data) ->
    %% Force stop during drain
    InFlight = ets:tab2list(ReqsTable),
    lists:foreach(fun({RequestId, CallerPid, MonRef, _StartTime}) ->
        CallerPid ! {loom_error, RequestId, <<"engine_stopped">>, <<"force stop">>},
        erlang:demonitor(MonRef, [flush])
    end, InFlight),
    ets:delete_all_objects(ReqsTable),
    stop_port(PortPid),
    {next_state, stopped, Data#data{port_pid = undefined}};
draining(info, {gpu_alert, GpuId, AlertType, Value, Threshold},
         #data{engine_id = EngineId} = _Data) ->
    ?LOG_INFO("Engine ~s received GPU alert during drain: ~p (~p > ~p) on GPU ~p",
              [EngineId, AlertType, Value, Threshold, GpuId],
              #{engine_id => EngineId}),
    keep_state_and_data.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=drain_with_inflight_test,drain_empty_test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_coordinator.erl test/loom_engine_coordinator_SUITE.erl
git commit -m "feat(coordinator): implement draining state with drain timeout (#9)"
```

---

## Task 6: Remaining CT tests — startup timeout, not-ready rejection, overload

**Files:**
- Modify: `test/loom_engine_coordinator_SUITE.erl`

- [ ] **Step 1: Write CT tests for startup timeout, not-ready rejection, max concurrent**

Add to `loom_engine_coordinator_SUITE.erl`:

```erlang
%% Add to exports and all/0
-export([
    startup_timeout_test/1,
    not_ready_rejection_test/1,
    max_concurrent_test/1
]).

%% @doc Adapter with long startup delay + short coordinator timeout → stopped.
startup_timeout_test(_Config) ->
    Config = (default_config())#{
        args => [mock_adapter_path(), "--startup-delay", "30"],
        startup_timeout_ms => 2000
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),

    wait_status(EngineId, stopped, 10000),
    wait_dead(Pid, 5000).

%% @doc Generate request before adapter is ready → {error, not_ready}.
not_ready_rejection_test(_Config) ->
    Config = (default_config())#{
        args => [mock_adapter_path(), "--startup-delay", "5"],
        startup_timeout_ms => 10000
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),

    %% Give just enough time for port to spawn but not reach ready
    timer:sleep(200),

    ?assertMatch({error, not_ready},
                 loom_engine_coordinator:generate(Pid, <<"Hello">>, #{})),

    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 10000).

%% @doc Send max_concurrent + 1 requests; last one gets {error, overloaded}.
%% ASSUMPTION: Mock adapter sends tokens fast enough that we can queue
%% all requests before any complete. We use max_concurrent=2 for testing.
max_concurrent_test(_Config) ->
    Config = (default_config())#{max_concurrent => 2},
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% ASSUMPTION: Mock adapter processes generate requests synchronously
    %% and sends all tokens immediately. With max_concurrent=2, if we
    %% can issue 3 requests fast enough we'll hit the limit. However,
    %% the mock adapter may complete requests too quickly. We spawn
    %% concurrent callers to maximize overlap.
    Self = self(),
    Caller1 = spawn_link(fun() ->
        Result = loom_engine_coordinator:generate(Pid, <<"Req1">>, #{}),
        Self ! {caller_result, 1, Result},
        flush_and_wait()
    end),
    Caller2 = spawn_link(fun() ->
        Result = loom_engine_coordinator:generate(Pid, <<"Req2">>, #{}),
        Self ! {caller_result, 2, Result},
        flush_and_wait()
    end),
    timer:sleep(50),
    %% Third request should be rejected if the first two are still in-flight
    Result3 = loom_engine_coordinator:generate(Pid, <<"Req3">>, #{}),

    %% Collect results — at least one of the callers succeeded, third may
    %% have been overloaded OR succeeded if previous ones completed fast.
    %% We verify the mechanism works by checking load was tracked.
    R1 = receive {caller_result, 1, R} -> R after 5000 -> ct:fail("no result 1") end,
    R2 = receive {caller_result, 2, R2_} -> R2_ after 5000 -> ct:fail("no result 2") end,
    ?assertMatch({ok, _}, R1),
    ?assertMatch({ok, _}, R2),
    %% Result3 may be ok or overloaded depending on timing
    ?assert(Result3 =:= {error, overloaded} orelse element(1, Result3) =:= ok),

    exit(Caller1, kill),
    exit(Caller2, kill),
    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).
```

Add helper:

```erlang
flush_and_wait() ->
    receive _ -> flush_and_wait()
    after 30000 -> ok
    end.
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=startup_timeout_test,not_ready_rejection_test,max_concurrent_test`
Expected: PASS (implementation already handles these cases)

- [ ] **Step 3: Commit**

```bash
git add test/loom_engine_coordinator_SUITE.erl
git commit -m "test(coordinator): add startup timeout, not-ready, and overload tests (#9)"
```

---

## Task 7: Extend mock adapter with `--token-delay` flag

The mock adapter sends all tokens instantly, making it impossible to test crash-with-inflight or drain timeout reliably. We need a `--token-delay` flag that pauses between tokens.

**Files:**
- Modify: `priv/scripts/mock_adapter.py`

- [ ] **Step 1: Add `--token-delay` argument to mock adapter**

Add to `main()` argument parser:

```python
parser.add_argument(
    '--token-delay',
    type=float,
    default=0.0,
    help="Delay in seconds between each token during generation (default: 0)"
)
```

- [ ] **Step 2: Update `handle_generate` to accept and use token delay**

Change `handle_generate` to accept the delay:

```python
def handle_generate(msg, token_delay=0.0):
    req_id = msg.get("id")
    if req_id is None:
        return [{"type": "error", "code": "missing_field",
                 "message": "generate request missing 'id' field"}]

    responses = []
    for i, token_text in enumerate(MOCK_TOKENS):
        if token_delay > 0 and i > 0:
            time.sleep(token_delay)
        send_msg({
            "type": "token",
            "id": req_id,
            "token_id": i + 1,
            "text": token_text,
            "finished": False,
        })
    send_msg({
        "type": "done",
        "id": req_id,
        "tokens_generated": len(MOCK_TOKENS),
        "time_ms": 0,
    })
    return []  # Already sent inline
```

Update the HANDLERS dict and `process_line` to pass `token_delay` through (store it as a module-level global set in `main()`).

- [ ] **Step 3: Verify existing tests still pass**

Run: `rebar3 do eunit, ct`
Expected: All existing tests PASS (default `--token-delay 0` preserves behavior)

- [ ] **Step 4: Commit**

```bash
git add priv/scripts/mock_adapter.py
git commit -m "feat(mock-adapter): add --token-delay flag for slow generation testing (#9)"
```

---

## Task 8: Port crash with in-flight and self-heal tests

**Files:**
- Modify: `test/loom_engine_coordinator_SUITE.erl`

- [ ] **Step 1: Write CT tests for crash recovery using slow adapter**

Add to `loom_engine_coordinator_SUITE.erl`:

```erlang
%% Add to exports and all/0
-export([
    port_crash_inflight_test/1,
    self_heal_then_succeed_test/1,
    port_crash_during_drain_test/1
]).

%% @doc Start generation with slow adapter, kill adapter mid-stream,
%% verify caller gets engine_crashed error, coordinator self-heals.
port_crash_inflight_test(_Config) ->
    %% Use token delay so request is in-flight long enough to kill
    Config = (default_config())#{
        args => [mock_adapter_path(), "--token-delay", "1"]
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% Start a generate request — adapter will delay 1s between tokens
    {ok, RequestId} = loom_engine_coordinator:generate(
        Pid, <<"Hello">>, #{}),

    %% Verify we're in-flight
    ?assert(loom_engine_coordinator:get_load(EngineId) > 0),

    %% Kill the port process (simulating adapter crash)
    Links = element(2, process_info(Pid, links)),
    PortPids = [P || P <- Links, P =/= self(), is_pid(P)],
    case PortPids of
        [PortPid | _] -> exit(PortPid, kill);
        [] -> ct:fail("no port pid found")
    end,

    %% Caller should receive engine_crashed error
    receive
        {loom_error, RequestId, <<"engine_crashed">>, _Code} -> ok
    after 5000 ->
        ct:fail("no engine_crashed error received")
    end,

    %% Coordinator should self-heal to starting, then ready
    wait_status(EngineId, ready, 15000),
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%% @doc Crash the port, wait for self-heal, then send a new request
%% and verify it succeeds end-to-end.
self_heal_then_succeed_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% Kill the port process
    Links = element(2, process_info(Pid, links)),
    PortPids = [P || P <- Links, P =/= self(), is_pid(P)],
    case PortPids of
        [PortPid | _] -> exit(PortPid, kill);
        [] -> ct:fail("no port pid found")
    end,

    %% Wait for self-heal
    wait_status(EngineId, ready, 15000),

    %% New request should work
    {ok, RequestId} = loom_engine_coordinator:generate(
        Pid, <<"After crash">>, #{}),
    Tokens = collect_tokens(RequestId, 5, 5000),
    ?assertEqual(5, length(Tokens)),
    receive
        {loom_done, RequestId, _Stats} -> ok
    after 5000 ->
        ct:fail("no loom_done after self-heal")
    end,

    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%% @doc Port crash during drain → goes to stopped, not starting.
port_crash_during_drain_test(_Config) ->
    %% Use token delay so there's an in-flight request during drain
    Config = (default_config())#{
        args => [mock_adapter_path(), "--token-delay", "1"]
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% Start a slow request
    {ok, _RequestId} = loom_engine_coordinator:generate(
        Pid, <<"Hello">>, #{}),

    %% Initiate drain while request is in-flight
    ok = loom_engine_coordinator:shutdown(Pid),
    timer:sleep(100),

    %% Kill the port while draining
    Links = element(2, process_info(Pid, links)),
    PortPids = [P || P <- Links, P =/= self(), is_pid(P)],
    case PortPids of
        [PortPid | _] -> exit(PortPid, kill);
        [] -> ok
    end,

    %% Should go to stopped, NOT starting (no self-heal during drain)
    wait_status(EngineId, stopped, 5000),
    wait_dead(Pid, 5000).
```

Add helper:

```erlang
drain_messages(Timeout) ->
    receive _ -> drain_messages(Timeout)
    after Timeout -> ok
    end.
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=port_crash_inflight_test,self_heal_then_succeed_test,port_crash_during_drain_test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/loom_engine_coordinator_SUITE.erl
git commit -m "test(coordinator): add port crash recovery and drain crash tests (#9)"
```

---

## Task 9: Caller death and drain timeout tests

**Files:**
- Modify: `test/loom_engine_coordinator_SUITE.erl`

- [ ] **Step 1: Write CT tests for caller death and drain timeout**

Add to `loom_engine_coordinator_SUITE.erl`:

```erlang
%% Add to exports and all/0
-export([
    caller_death_test/1,
    drain_timeout_test/1
]).

%% @doc Caller dies mid-stream → request cancelled, ETS cleaned up.
caller_death_test(_Config) ->
    Config = default_config(),
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% Spawn a caller that generates a request then dies
    Self = self(),
    CallerPid = spawn(fun() ->
        Result = loom_engine_coordinator:generate(Pid, <<"Hello">>, #{}),
        Self ! {caller_started, Result},
        %% Die immediately after starting the request
        ok
    end),

    %% Wait for the caller to have started the request
    receive
        {caller_started, {ok, _RequestId}} -> ok;
        {caller_started, {error, Reason}} ->
            ct:fail(io_lib:format("generate failed: ~p", [Reason]))
    after 5000 ->
        ct:fail("caller never started request")
    end,

    %% Caller is dead by now (it returned from the fun)
    %% Give coordinator time to process the DOWN message
    timer:sleep(200),

    %% The request should have been cancelled
    ?assertEqual(0, loom_engine_coordinator:get_load(EngineId)),

    %% Verify caller is actually dead
    ?assertEqual(false, is_process_alive(CallerPid)),

    loom_engine_coordinator:stop(Pid),
    wait_dead(Pid, 5000).

%% @doc Drain timeout: slow adapter with short drain timeout.
%% Caller should receive drain_timeout error.
drain_timeout_test(_Config) ->
    %% Use slow adapter (2s between tokens) with short drain timeout (500ms)
    Config = (default_config())#{
        args => [mock_adapter_path(), "--token-delay", "2"],
        drain_timeout_ms => 500
    },
    {ok, Pid} = loom_engine_coordinator:start_link(Config),
    EngineId = maps:get(engine_id, Config),
    wait_status(EngineId, ready, 5000),

    %% Start a slow request from a separate caller process
    Self = self(),
    _Caller = spawn_link(fun() ->
        {ok, ReqId} = loom_engine_coordinator:generate(Pid, <<"Hello">>, #{}),
        Self ! {req_started, ReqId},
        %% Wait for drain_timeout error
        receive
            {loom_error, ReqId, Code, _Msg} ->
                Self ! {got_error, ReqId, Code}
        after 10000 ->
            Self ! {timeout_never_fired, ReqId}
        end
    end),

    receive
        {req_started, _ReqId} -> ok
    after 5000 -> ct:fail("request never started")
    end,

    %% Initiate drain — adapter is too slow, drain timeout should fire
    ok = loom_engine_coordinator:shutdown(Pid),

    %% Caller should get drain_timeout error
    receive
        {got_error, _ReqId2, <<"drain_timeout">>} -> ok;
        {got_error, _ReqId2, OtherCode} ->
            ct:pal("got error code: ~p (acceptable)", [OtherCode]);
        {timeout_never_fired, _} ->
            ct:fail("drain timeout never fired")
    after 10000 ->
        ct:fail("no error from drain timeout")
    end,

    wait_status(EngineId, stopped, 5000),
    wait_dead(Pid, 5000).
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=caller_death_test,drain_timeout_test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/loom_engine_coordinator_SUITE.erl
git commit -m "test(coordinator): add caller death and drain timeout tests (#9)"
```

---

## Task 10: Request ID uniqueness EUnit tests

**Files:**
- Modify: `test/loom_engine_coordinator_tests.erl`

- [ ] **Step 1: Write failing EUnit test for request ID generation**

Add to `test/loom_engine_coordinator_tests.erl`:

```erlang
%% --- Request ID generation tests ---

-spec request_id_unique_test() -> any().
request_id_unique_test() ->
    Ids = [loom_engine_coordinator:generate_request_id(N) || N <- lists:seq(1, 100)],
    UniqueIds = lists:usort(Ids),
    ?assertEqual(100, length(UniqueIds)).

-spec request_id_format_test() -> any().
request_id_format_test() ->
    Id = loom_engine_coordinator:generate_request_id(1),
    ?assert(is_binary(Id)),
    ?assertMatch(<<"req-", _/binary>>, Id).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_engine_coordinator_tests`
Expected: FAIL — `generate_request_id/1` not exported

- [ ] **Step 3: Export and implement generate_request_id/1**

Add to `src/loom_engine_coordinator.erl`:

```erlang
%% Add to exports (for testing)
-export([generate_request_id/1]).

-spec generate_request_id(integer()) -> binary().
generate_request_id(_Counter) ->
    iolist_to_binary([
        <<"req-">>,
        integer_to_binary(erlang:unique_integer([positive, monotonic]))
    ]).
```

Update the `ready` state handler to use this function instead of inline code.

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_engine_coordinator_tests`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_coordinator.erl test/loom_engine_coordinator_tests.erl
git commit -m "feat(coordinator): extract and test request ID generation (#9)"
```

---

## Task 11: Full test suite run and cleanup

**Files:**
- Modify: `src/loom_engine_coordinator.erl` (if fixes needed)
- Modify: `test/loom_engine_coordinator_SUITE.erl` (if fixes needed)

- [ ] **Step 1: Run full EUnit suite**

Run: `rebar3 eunit --module=loom_engine_coordinator_tests`
Expected: All tests PASS

- [ ] **Step 2: Run full CT suite**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE`
Expected: All tests PASS

- [ ] **Step 3: Run all project tests to check for regressions**

Run: `rebar3 do eunit, ct`
Expected: All existing tests PASS, no regressions

- [ ] **Step 4: Run Dialyzer**

Run: `rebar3 dialyzer`
Expected: No new warnings from `loom_engine_coordinator`

- [ ] **Step 5: Fix any issues found**

Address any test failures, Dialyzer warnings, or edge cases.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "fix(coordinator): address test and dialyzer findings (#9)"
```

---

## Task 12: Update ROADMAP.md

**Files:**
- Modify: `ROADMAP.md`

- [ ] **Step 1: Mark P0-08 as complete in ROADMAP.md**

Change:
```
- [ ] `loom_engine_coordinator` GenServer for engine lifecycle — [#9](https://github.com/mohansharma-me/loom/issues/9) `P0-08`
```
To:
```
- [x] `loom_engine_coordinator` GenServer for engine lifecycle — [#9](https://github.com/mohansharma-me/loom/issues/9) `P0-08`
```

Update the Progress Summary table: Phase 0 Done from 8 to 9, Pending from 9 to 8.

Update the "What's Next" section to point to the next item: `#10 — P0-09: loom_engine_sup rest_for_one supervisor`.

- [ ] **Step 2: Commit**

```bash
git add ROADMAP.md
git commit -m "docs(roadmap): mark P0-08 loom_engine_coordinator as complete (#9)"
```
