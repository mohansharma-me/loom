# P0-11: Wire All Phase 0 Components Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire all existing Phase 0 components into `loom_sup` so `rebar3 shell` starts the full application: config loading, HTTP server, engine supervisor with mock adapter.

**Architecture:** `loom_app:start/2` loads config from `loom.json` via `loom_config`, then starts `loom_sup` which supervises `loom_http_server` (Cowboy lifecycle wrapper) followed by one `loom_engine_sup` per configured engine. Config reads are direct ETS lookups (no serialization).

**Tech Stack:** Erlang/OTP 27, Common Test, Cowboy 2.14, loom_config ETS

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/loom_http_util.erl` | Modify | Read config from `loom_config` ETS instead of `application:get_env` |
| `src/loom_http_server.erl` | Create | Thin gen_server lifecycle wrapper for Cowboy start/stop |
| `src/loom_app.erl` | Modify | Load config with fail-fast, skip if pre-loaded (tests) |
| `src/loom_sup.erl` | Modify | Build child specs: HTTP server + engine supervisors from config |
| `src/loom_http.erl` | Modify | Remove manual-start NOTE comment |
| `config/sys.config` | Modify | Remove `{loom, [...]}` section, keep SASL only |
| `test/loom_app_SUITE.erl` | Create | Integration tests for full application startup |
| `test/loom_app_SUITE_data/loom.json` | Create | Test config file with mock adapter |

### Key Mapping: `loom_config` to `loom_engine_sup`

`loom_config:get_engine/1` returns nested sub-maps. `loom_engine_sup:start_link/1` expects flat keys. The flattening happens in `loom_sup`:

```
loom_config format                    loom_engine_sup format
─────────────────────────────────     ──────────────────────────
adapter_cmd (script path)          →  adapter_cmd (python3 executable)
                                      adapter_args ([script path])
gpu_ids                            →  gpus
coordinator.startup_timeout_ms     →  startup_timeout_ms
coordinator.drain_timeout_ms       →  drain_timeout_ms
coordinator.max_concurrent         →  max_concurrent
engine_sup.max_restarts            →  max_restarts
engine_sup.max_period              →  max_period
gpu_monitor.poll_interval_ms       →  gpu_poll_interval
gpu_monitor.poll_timeout_ms        →  poll_timeout_ms
gpu_monitor.thresholds             →  thresholds
backend == <<"mock">>              →  allow_mock_backend => true
port (sub-map)                     →  port_opts (sub-map)
```

**Why split adapter_cmd?** `loom_port` uses `open_port({spawn_executable, Cmd}, [{args, Args}, ...])`. The adapter Python scripts are NOT executable (`-rw-r--r--`), so `Cmd` must be the Python interpreter and the script path goes in `Args`. This matches the pattern used in all existing test suites.

---

### Task 1: Update `loom_http_util:get_config/0` to read from `loom_config` ETS

**Files:**
- Modify: `src/loom_http_util.erl:30-45` (replace `get_config/0` and `default_config/0`)
- Test: `test/loom_app_SUITE.erl` (created in this task as a starting point)

- [ ] **Step 1: Create test file with config reading test**

Create `test/loom_app_SUITE.erl`:

```erlang
-module(loom_app_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    http_config_reads_from_ets_test/1
]).

all() ->
    [
        http_config_reads_from_ets_test
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Clean up any leftover ETS table from previous tests
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    Config.

end_per_testcase(_TestCase, _Config) ->
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc get_config/0 returns server config from loom_config ETS
%% plus handler defaults and engine_id from first engine.
http_config_reads_from_ets_test(_Config) ->
    %% Load a test config
    TestConfig = test_config_path(),
    ok = loom_config:load(TestConfig),

    HttpConfig = loom_http_util:get_config(),

    %% Server settings from loom.json
    ?assertEqual(9999, maps:get(port, HttpConfig)),

    %% Handler defaults still present
    ?assert(maps:is_key(max_body_size, HttpConfig)),
    ?assert(maps:is_key(inactivity_timeout, HttpConfig)),
    ?assert(maps:is_key(generate_timeout, HttpConfig)),

    %% engine_id defaults to first engine name
    ?assertEqual(<<"test_engine">>, maps:get(engine_id, HttpConfig)).

%%====================================================================
%% Helpers
%%====================================================================

test_config_path() ->
    DataDir = code:priv_dir(loom),
    %% We'll use the SUITE data dir
    filename:join([filename:dirname(filename:dirname(DataDir)),
                   "test", "loom_app_SUITE_data", "loom.json"]).
```

- [ ] **Step 2: Create test config file**

Create `test/loom_app_SUITE_data/loom.json`:

```json
{
  "engines": [
    {
      "name": "test_engine",
      "backend": "mock",
      "model": "test-model",
      "gpu_ids": []
    }
  ],
  "server": {
    "port": 9999
  }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=http_config_reads_from_ets_test --verbose`

Expected: FAIL — `get_config/0` still reads from `application:get_env`, won't match port 9999.

- [ ] **Step 4: Update `loom_http_util:get_config/0`**

Replace `default_config/0` and `get_config/0` in `src/loom_http_util.erl`:

```erlang
-spec default_config() -> map().
default_config() ->
    #{
        max_body_size => 10485760,
        inactivity_timeout => 60000,
        generate_timeout => 5000
    }.

-spec get_config() -> map().
get_config() ->
    ServerConfig = loom_config:get_server(),
    EngineId = case loom_config:engine_names() of
        [First | _] -> First;
        [] -> <<"engine_0">>
    end,
    HandlerDefaults = default_config(),
    maps:merge(HandlerDefaults, ServerConfig#{engine_id => EngineId}).
```

Key changes:
- `default_config/0` only has handler-specific defaults (timeouts, body size) — server settings (port, ip, max_connections) now come from `loom_config:get_server()`.
- `engine_id` is derived from first engine name in config.
- `maps:merge/2` gives `ServerConfig` priority over `HandlerDefaults` for overlapping keys.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=http_config_reads_from_ets_test --verbose`

Expected: PASS

- [ ] **Step 6: Run existing test suites to check for regressions**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --verbose`

Expected: All existing suites pass. Some handler tests may need adjustment if they depend on `application:get_env(loom, http, #{})` — check and fix.

**IMPORTANT:** If handler tests fail because they expect `application:get_env`-based config, they need `loom_config:load/1` in their `init_per_suite`. Check `test/loom_handler_*_SUITE.erl` for this.

- [ ] **Step 7: Commit**

```bash
git add src/loom_http_util.erl test/loom_app_SUITE.erl test/loom_app_SUITE_data/loom.json
git commit -m "feat(http): read config from loom_config ETS instead of application:get_env

Part of #12 — unified config source for all components."
```

---

### Task 2: Create `loom_http_server` lifecycle wrapper

**Files:**
- Create: `src/loom_http_server.erl`
- Modify: `test/loom_app_SUITE.erl` (add test case)

- [ ] **Step 1: Add test for HTTP server lifecycle**

Add to `test/loom_app_SUITE.erl` exports and `all/0`:

```erlang
-export([
    http_config_reads_from_ets_test/1,
    http_server_lifecycle_test/1
]).

all() ->
    [
        http_config_reads_from_ets_test,
        http_server_lifecycle_test
    ].
```

Add test case:

```erlang
%% @doc loom_http_server starts Cowboy and stops it on terminate.
http_server_lifecycle_test(_Config) ->
    %% Load config with a test port to avoid conflicts
    ok = loom_config:load(test_config_path()),

    %% Start the server
    {ok, Pid} = loom_http_server:start_link(),
    ?assert(is_process_alive(Pid)),

    %% Verify Cowboy is listening
    Port = maps:get(port, loom_config:get_server()),
    {ok, Conn} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    gen_tcp:close(Conn),

    %% Stop the server
    gen_server:stop(Pid),
    timer:sleep(100),

    %% Verify Cowboy is no longer listening
    ?assertMatch({error, _}, gen_tcp:connect({127, 0, 0, 1}, Port,
                                              [binary, {active, false}],
                                              500)).
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=http_server_lifecycle_test --verbose`

Expected: FAIL — module `loom_http_server` does not exist.

- [ ] **Step 3: Create `loom_http_server.erl`**

Create `src/loom_http_server.erl`:

```erlang
-module(loom_http_server).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    case loom_http:start() of
        {ok, _Pid} ->
            ?LOG_INFO(#{msg => http_server_started}),
            {ok, #{}};
        {error, Reason} ->
            ?LOG_ERROR(#{msg => http_server_start_failed, reason => Reason}),
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    loom_http:stop(),
    ok.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=http_server_lifecycle_test --verbose`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_http_server.erl test/loom_app_SUITE.erl
git commit -m "feat(http): add loom_http_server lifecycle gen_server for Cowboy

Thin wrapper that starts Cowboy in init/1 and stops it in terminate/2.
Not in the HTTP request path — just lifecycle coupling with loom_sup.
Part of #12."
```

---

### Task 3: Update `loom_app` with config loading and fail-fast

**Files:**
- Modify: `src/loom_app.erl`
- Modify: `test/loom_app_SUITE.erl` (add test cases)

- [ ] **Step 1: Add fail-fast test**

Add to `test/loom_app_SUITE.erl` exports and `all/0`:

```erlang
-export([
    http_config_reads_from_ets_test/1,
    http_server_lifecycle_test/1,
    app_start_fails_on_bad_config_test/1,
    app_start_skips_reload_if_preloaded_test/1
]).

all() ->
    [
        http_config_reads_from_ets_test,
        http_server_lifecycle_test,
        app_start_fails_on_bad_config_test,
        app_start_skips_reload_if_preloaded_test
    ].
```

Add test cases:

```erlang
%% @doc Application start fails with clear error on invalid config.
app_start_fails_on_bad_config_test(_Config) ->
    %% Point to a nonexistent config file by temporarily modifying the
    %% default config path. We do this by ensuring no ETS table exists
    %% and the default loom.json is not at the expected relative path.
    %%
    %% Since loom_config:load/0 looks for "config/loom.json" relative to CWD,
    %% and we can't control CWD easily, we test loom_app logic by calling
    %% loom_config:load/1 with a bad path directly.
    BadPath = "/nonexistent/loom.json",
    ?assertMatch({error, {config_file, enoent, _}},
                 loom_config:load(BadPath)).

%% @doc If loom_config ETS is already populated, loom_app:start/2 skips
%% config loading (allows tests to pre-load config).
app_start_skips_reload_if_preloaded_test(_Config) ->
    %% Pre-load config
    ok = loom_config:load(test_config_path()),

    %% Verify ETS exists
    ?assertNotEqual(undefined, ets:info(loom_config)),

    %% Store the current server config
    ServerBefore = loom_config:get_server(),

    %% Start the application — should NOT reload config
    {ok, _} = application:ensure_all_started(loom),

    %% Server config should be unchanged (still our test config)
    ServerAfter = loom_config:get_server(),
    ?assertEqual(ServerBefore, ServerAfter),

    %% Clean up
    application:stop(loom).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=app_start_skips_reload_if_preloaded_test --verbose`

Expected: FAIL — current `loom_app:start/2` does not check for pre-loaded config, and `loom_sup:init/1` has no children so the app starts but does nothing useful.

- [ ] **Step 3: Update `loom_app:start/2`**

Replace `src/loom_app.erl`:

```erlang
-module(loom_app).
-behaviour(application).

-export([start/2, stop/1]).

-include_lib("kernel/include/logger.hrl").

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    case ensure_config_loaded() of
        ok ->
            loom_sup:start_link();
        {error, Reason} ->
            ?LOG_ERROR(#{msg => config_load_failed, reason => Reason}),
            {error, {config_error, Reason}}
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.

%% @private If config is already loaded (e.g., by test setup), skip reload.
-spec ensure_config_loaded() -> ok | {error, term()}.
ensure_config_loaded() ->
    case ets:info(loom_config) of
        undefined ->
            ?LOG_INFO(#{msg => loading_config}),
            loom_config:load();
        _ ->
            ?LOG_INFO(#{msg => config_already_loaded, source => pre_existing_ets}),
            ok
    end.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=app_start_fails_on_bad_config_test,app_start_skips_reload_if_preloaded_test --verbose`

Expected: PASS (note: `app_start_skips_reload_if_preloaded_test` may still fail until `loom_sup` has children — it will pass once Task 4 is done; if so, mark this step as partial and revisit after Task 4).

- [ ] **Step 5: Commit**

```bash
git add src/loom_app.erl test/loom_app_SUITE.erl
git commit -m "feat(app): add config loading with fail-fast to loom_app:start/2

Loads loom_config from loom.json on startup. Fails with {error,
{config_error, Reason}} if config is missing or invalid. Skips
reload if ETS is already populated (for test pre-loading).
Part of #12."
```

---

### Task 4: Wire `loom_sup` with child specs

This is the core task — build the supervisor child list from config.

**Files:**
- Modify: `src/loom_sup.erl`
- Modify: `test/loom_app_SUITE.erl` (add integration tests)

- [ ] **Step 1: Add supervisor wiring test**

Add to `test/loom_app_SUITE.erl` exports and `all/0`:

```erlang
-export([
    http_config_reads_from_ets_test/1,
    http_server_lifecycle_test/1,
    app_start_fails_on_bad_config_test/1,
    app_start_skips_reload_if_preloaded_test/1,
    supervisor_has_correct_children_test/1,
    health_endpoint_returns_ready_test/1,
    chat_completions_returns_tokens_test/1
]).

all() ->
    [
        http_config_reads_from_ets_test,
        http_server_lifecycle_test,
        app_start_fails_on_bad_config_test,
        app_start_skips_reload_if_preloaded_test,
        supervisor_has_correct_children_test,
        health_endpoint_returns_ready_test,
        chat_completions_returns_tokens_test
    ].
```

Add a helper for full app startup and the test:

```erlang
%% @doc Full application starts with correct supervisor children.
supervisor_has_correct_children_test(_Config) ->
    ok = loom_config:load(test_config_path()),
    {ok, _} = application:ensure_all_started(loom),

    %% Wait for engine to reach ready
    wait_engine_ready(<<"test_engine">>, 15000),

    %% Check loom_sup children
    Children = supervisor:which_children(loom_sup),

    %% Should have: loom_http_server + 1 engine sup
    ?assertEqual(2, length(Children)),

    %% HTTP server child
    ?assertNotEqual(false, lists:keyfind(loom_http_server, 1, Children)),

    %% Engine supervisor child
    ExpectedEngSup = loom_engine_sup:sup_name(<<"test_engine">>),
    ?assertNotEqual(false, lists:keyfind(ExpectedEngSup, 1, Children)),

    application:stop(loom).
```

Add helper:

```erlang
wait_engine_ready(EngineId, Timeout) when Timeout > 0 ->
    case catch loom_engine_coordinator:get_status(EngineId) of
        ready -> ok;
        _ ->
            timer:sleep(100),
            wait_engine_ready(EngineId, Timeout - 100)
    end;
wait_engine_ready(EngineId, _Timeout) ->
    ct:fail(io_lib:format("Engine ~s never reached ready", [EngineId])).
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=supervisor_has_correct_children_test --verbose`

Expected: FAIL — `loom_sup` has no children.

- [ ] **Step 3: Implement `loom_sup:init/1` with child specs**

Replace `src/loom_sup.erl`:

```erlang
-module(loom_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

-include_lib("kernel/include/logger.hrl").

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    HttpChild = #{
        id => loom_http_server,
        start => {loom_http_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },

    EngineChildren = build_engine_children(),

    {ok, {SupFlags, [HttpChild | EngineChildren]}}.

%%====================================================================
%% Internal
%%====================================================================

-spec build_engine_children() -> [supervisor:child_spec()].
build_engine_children() ->
    Names = loom_config:engine_names(),
    lists:map(fun(Name) ->
        {ok, EngineMap} = loom_config:get_engine(Name),
        ChildConfig = flatten_engine_config(EngineMap),
        SupName = loom_engine_sup:sup_name(Name),
        #{
            id => SupName,
            start => {loom_engine_sup, start_link, [ChildConfig]},
            restart => permanent,
            shutdown => infinity,
            type => supervisor
        }
    end, Names).

%% @doc Flatten loom_config engine map (nested sub-maps) into the flat
%% format loom_engine_sup:start_link/1 expects.
%%
%% ASSUMPTION: All known backends (vllm, mlx, tensorrt, mock) are Python
%% scripts that need python3 as the executable. Custom adapter_cmd in
%% loom.json is used as the command directly (may be a compiled binary).
-spec flatten_engine_config(map()) -> map().
flatten_engine_config(EngineMap) ->
    CoordConfig = maps:get(coordinator, EngineMap, #{}),
    EngSupConfig = maps:get(engine_sup, EngineMap, #{}),
    GpuMonConfig = maps:get(gpu_monitor, EngineMap, #{}),
    PortConfig = maps:get(port, EngineMap, #{}),

    AdapterPath = maps:get(adapter_cmd, EngineMap),
    {Cmd, Args} = adapter_cmd_and_args(AdapterPath),

    Backend = maps:get(backend, EngineMap),
    Base = #{
        engine_id => maps:get(engine_id, EngineMap),
        adapter_cmd => Cmd,
        adapter_args => Args,
        model => maps:get(model, EngineMap),
        backend => Backend,
        gpus => maps:get(gpu_ids, EngineMap, []),
        %% Coordinator settings (flattened)
        startup_timeout_ms => maps:get(startup_timeout_ms, CoordConfig, 120000),
        drain_timeout_ms => maps:get(drain_timeout_ms, CoordConfig, 30000),
        max_concurrent => maps:get(max_concurrent, CoordConfig, 64),
        %% Engine sup settings (flattened)
        max_restarts => maps:get(max_restarts, EngSupConfig, 5),
        max_period => maps:get(max_period, EngSupConfig, 60),
        %% GPU monitor settings (flattened)
        gpu_poll_interval => maps:get(poll_interval_ms, GpuMonConfig, 5000),
        allow_mock_backend => Backend =:= <<"mock">>,
        %% Port opts as sub-map
        port_opts => PortConfig
    },
    %% Forward optional gpu_monitor fields if present
    OptionalGpuMon = [{poll_timeout_ms, poll_timeout_ms}, {thresholds, thresholds}],
    lists:foldl(fun({SrcKey, DstKey}, Acc) ->
        case maps:find(SrcKey, GpuMonConfig) of
            {ok, Val} -> maps:put(DstKey, Val, Acc);
            error -> Acc
        end
    end, Base, OptionalGpuMon).

%% @doc Determine the executable and args for launching an adapter.
%% Python scripts need python3 as the executable; the script is an arg.
-spec adapter_cmd_and_args(string()) -> {string(), [string()]}.
adapter_cmd_and_args(AdapterPath) ->
    case os:find_executable("python3") of
        false ->
            ?LOG_WARNING(#{msg => python3_not_found,
                           hint => "Falling back to adapter path as command"}),
            {AdapterPath, []};
        PythonCmd ->
            {PythonCmd, [AdapterPath]}
    end.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=supervisor_has_correct_children_test --verbose`

Expected: PASS — supervisor has 2 children (http_server + engine_sup), engine reaches ready.

- [ ] **Step 5: Run all existing tests for regressions**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --verbose`

Expected: All suites pass. Watch for:
- Handler test suites that start the app — they may need `loom_config:load/1` in their setup.
- Engine sup tests — they bypass `loom_sup` so should be unaffected.

- [ ] **Step 6: Commit**

```bash
git add src/loom_sup.erl test/loom_app_SUITE.erl
git commit -m "feat(sup): wire HTTP server and engine supervisors into loom_sup

loom_sup:init/1 builds child specs from loom_config ETS:
- loom_http_server (first) for Cowboy lifecycle
- loom_engine_sup per engine with flattened config

Includes flatten_engine_config/1 to map loom_config nested format
to loom_engine_sup flat format. Python backends use python3 as
executable with adapter script as arg.
Part of #12."
```

---

### Task 5: Add HTTP endpoint integration tests

**Files:**
- Modify: `test/loom_app_SUITE.erl` (add health and chat completion tests)

- [ ] **Step 1: Add health endpoint test**

Add test case to `test/loom_app_SUITE.erl`:

```erlang
%% @doc GET /health returns 200 with ready status after app starts.
health_endpoint_returns_ready_test(_Config) ->
    ok = loom_config:load(test_config_path()),
    {ok, _} = application:ensure_all_started(loom),
    wait_engine_ready(<<"test_engine">>, 15000),

    Port = maps:get(port, loom_config:get_server()),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/health",
    {ok, {{_, 200, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),

    Decoded = json:decode(list_to_binary(Body)),
    ?assertEqual(<<"ready">>, maps:get(<<"status">>, Decoded)),
    ?assertEqual(<<"test_engine">>, maps:get(<<"engine_id">>, Decoded)),

    application:stop(loom).
```

Update `init_per_suite` to start `inets` (needed for `httpc`):

```erlang
init_per_suite(Config) ->
    application:ensure_all_started(inets),
    Config.
```

- [ ] **Step 2: Run test to verify it passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=health_endpoint_returns_ready_test --verbose`

Expected: PASS — full app starts, health endpoint returns 200 with ready status.

- [ ] **Step 3: Add chat completions test**

Add test case:

```erlang
%% @doc POST /v1/chat/completions with mock adapter returns tokens.
chat_completions_returns_tokens_test(_Config) ->
    ok = loom_config:load(test_config_path()),
    {ok, _} = application:ensure_all_started(loom),
    wait_engine_ready(<<"test_engine">>, 15000),

    Port = maps:get(port, loom_config:get_server()),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1/chat/completions",
    RequestBody = json:encode(#{
        <<"model">> => <<"test-model">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
        <<"stream">> => false
    }),
    Headers = [{"content-type", "application/json"}],
    {ok, {{_, StatusCode, _}, _RespHeaders, RespBody}} =
        httpc:request(post, {Url, Headers, "application/json",
                             binary_to_list(RequestBody)}, [], []),

    ?assertEqual(200, StatusCode),
    Decoded = json:decode(list_to_binary(RespBody)),
    %% Mock adapter returns a response with choices
    ?assert(maps:is_key(<<"choices">>, Decoded)),

    application:stop(loom).
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite=test/loom_app_SUITE --case=chat_completions_returns_tokens_test --verbose`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add test/loom_app_SUITE.erl
git commit -m "test(app): add integration tests for health and chat completions endpoints

Verifies full application startup with mock adapter: GET /health
returns 200/ready, POST /v1/chat/completions returns tokens.
Part of #12."
```

---

### Task 6: Clean up config and comments

**Files:**
- Modify: `config/sys.config`
- Modify: `src/loom_http.erl`

- [ ] **Step 1: Remove `{loom, [...]}` from sys.config**

Update `config/sys.config` to:

```erlang
[
    {sasl, [
        {sasl_error_logger, {file, "log/sasl-error.log"}},
        {errlog_type, error}
    ]}
].
```

- [ ] **Step 2: Remove manual-start NOTE from loom_http.erl**

In `src/loom_http.erl`, remove lines 7-8:

```
%% NOTE: loom_http is started manually for now. Integration into loom_sup
%% supervision tree is part of P0-11 (#12) — wiring all components together.
```

- [ ] **Step 3: Run full test suite**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --verbose`

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add config/sys.config src/loom_http.erl
git commit -m "chore: remove obsolete loom section from sys.config and manual-start NOTE

sys.config now only contains SASL logging config. All loom config
comes from loom.json via loom_config ETS.
Part of #12."
```

---

### Task 7: Final verification and cleanup

- [ ] **Step 1: Run the full test suite**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --verbose`

Expected: All suites pass, including the new `loom_app_SUITE`.

- [ ] **Step 2: Run Dialyzer**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 dialyzer`

Expected: No new warnings from changed/new files.

- [ ] **Step 3: Verify manual startup**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 shell`

In the shell, verify:
- Application starts without errors
- `supervisor:which_children(loom_sup).` shows HTTP server + engine sup
- `loom_engine_coordinator:get_status(<<"engine_0">>).` returns `ready`
- `curl http://localhost:8080/health` returns `{"status":"ready",...}`
- `curl http://localhost:8080/v1/models` returns model list

- [ ] **Step 4: Run compilation check**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 compile`

Expected: No warnings.
