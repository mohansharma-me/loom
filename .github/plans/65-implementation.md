# `loom_config` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `loom_config`, a module that loads, validates, merges, and serves Loom configuration from a JSON file (`config/loom.json`), stored in an ETS table for fast concurrent reads.

**Architecture:** Single module with pure functions for parsing/validation/merging and an ETS table for storage. Called once at app startup before the supervisor tree. No GenServer — config is immutable after load. OTP 27's built-in `json:decode/1` for parsing. Merge precedence: per-engine overrides > `defaults` section > hardcoded defaults.

**Tech Stack:** Erlang/OTP 27, `json:decode/1`, ETS, EUnit, Common Test

**Design Spec:** `.github/plans/65-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/loom_config.erl` | Create | Config loading, validation, merging, ETS storage, public API |
| `test/loom_config_tests.erl` | Create | EUnit tests for pure functions (parsing, merging, validation, adapter resolution) |
| `test/loom_config_SUITE.erl` | Create | CT suite for ETS integration (load→get cycle, concurrent reads, reload) |
| `config/loom.json` | Create | Default config file for development |
| `test/fixtures/` | Create dir | Test JSON config fixtures |
| `src/loom_engine_sup.erl` | Modify | Update engine_id regex to allow hyphens and dots |
| `src/loom_engine_coordinator.erl` | Modify | Update engine_id regex to allow hyphens and dots |

---

### Task 1: Module skeleton with hardcoded defaults and ETS table

**Files:**
- Create: `src/loom_config.erl`
- Create: `test/loom_config_tests.erl`

- [ ] **Step 1: Write failing test for hardcoded defaults**

Create `test/loom_config_tests.erl`:

```erlang
-module(loom_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Hardcoded defaults ---

server_defaults_test() ->
    Defaults = loom_config:server_defaults(),
    ?assertEqual(8080, maps:get(port, Defaults)),
    ?assertEqual({0,0,0,0}, maps:get(ip, Defaults)),
    ?assertEqual(1024, maps:get(max_connections, Defaults)),
    ?assertEqual(10485760, maps:get(max_body_size, Defaults)),
    ?assertEqual(60000, maps:get(inactivity_timeout, Defaults)),
    ?assertEqual(5000, maps:get(generate_timeout, Defaults)).

port_defaults_test() ->
    Defaults = loom_config:port_defaults(),
    ?assertEqual(1048576, maps:get(max_line_length, Defaults)),
    ?assertEqual(5000, maps:get(spawn_timeout_ms, Defaults)),
    ?assertEqual(15000, maps:get(heartbeat_timeout_ms, Defaults)),
    ?assertEqual(10000, maps:get(shutdown_timeout_ms, Defaults)),
    ?assertEqual(5000, maps:get(post_close_timeout_ms, Defaults)).

gpu_monitor_defaults_test() ->
    Defaults = loom_config:gpu_monitor_defaults(),
    ?assertEqual(5000, maps:get(poll_interval_ms, Defaults)),
    ?assertEqual(3000, maps:get(poll_timeout_ms, Defaults)),
    ?assertEqual(auto, maps:get(backend, Defaults)),
    Thresholds = maps:get(thresholds, Defaults),
    ?assertEqual(85.0, maps:get(temperature_c, Thresholds)),
    ?assertEqual(95.0, maps:get(mem_percent, Thresholds)).

coordinator_defaults_test() ->
    Defaults = loom_config:coordinator_defaults(),
    ?assertEqual(120000, maps:get(startup_timeout_ms, Defaults)),
    ?assertEqual(30000, maps:get(drain_timeout_ms, Defaults)),
    ?assertEqual(64, maps:get(max_concurrent, Defaults)).

engine_sup_defaults_test() ->
    Defaults = loom_config:engine_sup_defaults(),
    ?assertEqual(5, maps:get(max_restarts, Defaults)),
    ?assertEqual(60, maps:get(max_period, Defaults)).
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: FAIL — module `loom_config` not found.

- [ ] **Step 3: Write module skeleton with defaults**

Create `src/loom_config.erl`:

```erlang
-module(loom_config).

%% Public API
-export([load/0, load/1]).
-export([get/2, get_engine/1, engine_names/0, get_server/0]).

%% Defaults (exported for testing)
-export([server_defaults/0, port_defaults/0, gpu_monitor_defaults/0,
         coordinator_defaults/0, engine_sup_defaults/0]).

-define(TABLE, loom_config).
-define(DEFAULT_PATH, "config/loom.json").

%%% ===================================================================
%%% Hardcoded defaults
%%% ===================================================================

-spec server_defaults() -> map().
server_defaults() ->
    #{port => 8080,
      ip => {0, 0, 0, 0},
      max_connections => 1024,
      max_body_size => 10485760,
      inactivity_timeout => 60000,
      generate_timeout => 5000}.

-spec port_defaults() -> map().
port_defaults() ->
    #{max_line_length => 1048576,
      spawn_timeout_ms => 5000,
      heartbeat_timeout_ms => 15000,
      shutdown_timeout_ms => 10000,
      post_close_timeout_ms => 5000}.

-spec gpu_monitor_defaults() -> map().
gpu_monitor_defaults() ->
    #{poll_interval_ms => 5000,
      poll_timeout_ms => 3000,
      backend => auto,
      thresholds => #{temperature_c => 85.0,
                      mem_percent => 95.0}}.

-spec coordinator_defaults() -> map().
coordinator_defaults() ->
    #{startup_timeout_ms => 120000,
      drain_timeout_ms => 30000,
      max_concurrent => 64}.

-spec engine_sup_defaults() -> map().
engine_sup_defaults() ->
    #{max_restarts => 5,
      max_period => 60}.

%%% ===================================================================
%%% Public API (stubs)
%%% ===================================================================

-spec load() -> ok | {error, term()}.
load() ->
    load(?DEFAULT_PATH).

-spec load(file:filename()) -> ok | {error, term()}.
load(_Path) ->
    {error, not_implemented}.

-spec get(list(atom()), term()) -> term().
get(_KeyPath, Default) ->
    Default.

-spec get_engine(binary()) -> {ok, map()} | {error, not_found}.
get_engine(_Name) ->
    {error, not_found}.

-spec engine_names() -> [binary()].
engine_names() ->
    [].

-spec get_server() -> map().
get_server() ->
    server_defaults().
```

- [ ] **Step 4: Run test to verify it passes**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: All 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/loom_config.erl test/loom_config_tests.erl
git commit -m "feat(config): add loom_config skeleton with hardcoded defaults (#65)"
```

---

### Task 2: JSON parsing and ETS storage

**Files:**
- Modify: `test/loom_config_tests.erl`
- Modify: `src/loom_config.erl`
- Create: `test/fixtures/minimal.json`

- [ ] **Step 1: Create test fixture**

Create `test/fixtures/minimal.json`:

```json
{
  "engines": [
    {
      "name": "test_engine",
      "backend": "mock",
      "model": "test-model",
      "gpu_ids": [0]
    }
  ]
}
```

Note: We use `"backend": "mock"` here and skip adapter file existence checks in this task. Adapter resolution and validation are Task 4 and Task 5. For now, `load/1` parses JSON, converts keys, and stores in ETS — it does NOT validate or resolve adapters yet.

- [ ] **Step 2: Write failing tests for JSON parsing and ETS storage**

Add to `test/loom_config_tests.erl`:

```erlang
%% --- JSON parsing ---

load_minimal_config_test() ->
    cleanup_ets(),
    Path = fixture_path("minimal.json"),
    ?assertEqual(ok, loom_config:load(Path)),
    %% ETS table should exist
    ?assertNotEqual(undefined, ets:info(?TABLE)),
    cleanup_ets().

load_file_not_found_test() ->
    cleanup_ets(),
    ?assertMatch({error, {config_file, enoent, _}},
                 loom_config:load("/nonexistent/path.json")),
    cleanup_ets().

load_invalid_json_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{ not valid json">>),
    ?assertMatch({error, {json_parse, _}}, loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

get_nested_value_test() ->
    cleanup_ets(),
    Path = fixture_path("minimal.json"),
    ok = loom_config:load(Path),
    %% Engine names are available
    ?assertEqual([<<"test_engine">>], loom_config:engine_names()),
    cleanup_ets().

get_server_defaults_when_no_server_section_test() ->
    cleanup_ets(),
    Path = fixture_path("minimal.json"),
    ok = loom_config:load(Path),
    Server = loom_config:get_server(),
    ?assertEqual(8080, maps:get(port, Server)),
    ?assertEqual({0,0,0,0}, maps:get(ip, Server)),
    cleanup_ets().

get_with_default_test() ->
    cleanup_ets(),
    Path = fixture_path("minimal.json"),
    ok = loom_config:load(Path),
    ?assertEqual(42, loom_config:get([nonexistent, key], 42)),
    cleanup_ets().

%% --- Helpers ---

-define(TABLE, loom_config).

fixture_path(Name) ->
    filename:join([code:lib_dir(loom, test), "fixtures", Name]).

write_temp_file(Content) ->
    Path = filename:join(["/tmp", "loom_config_test_" ++
                          integer_to_list(erlang:unique_integer([positive]))
                          ++ ".json"]),
    ok = file:write_file(Path, Content),
    Path.

cleanup_ets() ->
    case ets:info(?TABLE) of
        undefined -> ok;
        _ -> ets:delete(?TABLE)
    end.
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: New tests FAIL — `load/1` returns `{error, not_implemented}`.

- [ ] **Step 4: Implement JSON parsing, key conversion, and ETS storage**

Update `src/loom_config.erl` — replace the `load/1` stub and update `get/2`, `engine_names/0`, `get_server/0`:

```erlang
-spec load(file:filename()) -> ok | {error, term()}.
load(Path) ->
    case file:read_file(Path) of
        {error, enoent} ->
            {error, {config_file, enoent, Path}};
        {error, Reason} ->
            {error, {config_file, Reason, Path}};
        {ok, Bin} ->
            parse_and_store(Bin)
    end.

%%% ===================================================================
%%% Internal: parsing and storage
%%% ===================================================================

parse_and_store(Bin) ->
    case catch json:decode(Bin) of
        {'EXIT', Reason} ->
            {error, {json_parse, Reason}};
        {error, Reason} ->
            {error, {json_parse, Reason}};
        Parsed when is_map(Parsed) ->
            store_config(Parsed);
        Other ->
            {error, {json_parse, {expected_object, Other}}}
    end.

store_config(Parsed) ->
    ensure_table(),
    %% Store raw parsed config for get/2
    Atomized = atomize_keys(Parsed),
    ets:insert(?TABLE, {{config, parsed}, Atomized}),
    %% Pre-merge and store server config
    ServerJson = maps:get(server, Atomized, #{}),
    ServerMerged = maps:merge(server_defaults(), ServerJson),
    ets:insert(?TABLE, {{server, config}, ServerMerged}),
    %% Pre-merge and store each engine config
    Engines = maps:get(engines, Atomized, []),
    Defaults = maps:get(defaults, Atomized, #{}),
    EngineNames = lists:map(fun(E) ->
        Name = maps:get(name, E),
        Merged = merge_engine(E, Defaults),
        ets:insert(?TABLE, {{engine, Name}, Merged}),
        Name
    end, Engines),
    ets:insert(?TABLE, {{engine, names}, EngineNames}),
    ok.

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [set, named_table, public,
                             {read_concurrency, true}]);
        _ ->
            ets:delete_all_objects(?TABLE)
    end,
    ok.

%% Deep-convert binary map keys to atoms (top-level and nested maps).
%% JSON arrays stay as lists. Only map keys are converted.
atomize_keys(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        Key = key_to_atom(K),
        maps:put(Key, atomize_keys(V), Acc)
    end, #{}, Map);
atomize_keys(List) when is_list(List) ->
    lists:map(fun atomize_keys/1, List);
atomize_keys(Other) ->
    Other.

key_to_atom(K) when is_binary(K) -> binary_to_atom(K, utf8);
key_to_atom(K) when is_atom(K) -> K.

%% Merge a single engine config with defaults.
%% Per-engine sub-sections override defaults sub-sections.
merge_engine(Engine, Defaults) ->
    PortDefaults = maps:get(port, Defaults, #{}),
    GpuMonDefaults = maps:get(gpu_monitor, Defaults, #{}),
    CoordDefaults = maps:get(coordinator, Defaults, #{}),
    SupDefaults = maps:get(engine_sup, Defaults, #{}),

    EnginePort = maps:get(port, Engine, #{}),
    EngineGpuMon = maps:get(gpu_monitor, Engine, #{}),
    EngineCoord = maps:get(coordinator, Engine, #{}),

    Engine#{
        port => deep_merge(port_defaults(), deep_merge(PortDefaults, EnginePort)),
        gpu_monitor => deep_merge(gpu_monitor_defaults(), deep_merge(GpuMonDefaults, EngineGpuMon)),
        coordinator => deep_merge(coordinator_defaults(), deep_merge(CoordDefaults, EngineCoord)),
        engine_sup => maps:merge(engine_sup_defaults(), SupDefaults),
        gpu_ids => maps:get(gpu_ids, Engine, []),
        tp_size => maps:get(tp_size, Engine, 1)
    }.

%% Deep merge: nested maps are merged recursively, scalars overwrite.
deep_merge(Base, Override) when is_map(Base), is_map(Override) ->
    maps:fold(fun(K, V, Acc) ->
        case maps:find(K, Acc) of
            {ok, AccV} when is_map(AccV), is_map(V) ->
                maps:put(K, deep_merge(AccV, V), Acc);
            _ ->
                maps:put(K, V, Acc)
        end
    end, Base, Override);
deep_merge(_Base, Override) ->
    Override.

%% --- Updated public API ---

-spec get(list(atom()), term()) -> term().
get(KeyPath, Default) ->
    case ets:info(?TABLE) of
        undefined -> Default;
        _ ->
            case ets:lookup(?TABLE, {config, parsed}) of
                [{{config, parsed}, Config}] ->
                    get_nested(KeyPath, Config, Default);
                [] -> Default
            end
    end.

-spec get_engine(binary()) -> {ok, map()} | {error, not_found}.
get_engine(Name) ->
    case ets:lookup(?TABLE, {engine, Name}) of
        [{{engine, Name}, Config}] -> {ok, Config};
        [] -> {error, not_found}
    end.

-spec engine_names() -> [binary()].
engine_names() ->
    case ets:info(?TABLE) of
        undefined -> [];
        _ ->
            case ets:lookup(?TABLE, {engine, names}) of
                [{{engine, names}, Names}] -> Names;
                [] -> []
            end
    end.

-spec get_server() -> map().
get_server() ->
    case ets:info(?TABLE) of
        undefined -> server_defaults();
        _ ->
            case ets:lookup(?TABLE, {server, config}) of
                [{{server, config}, Config}] -> Config;
                [] -> server_defaults()
            end
    end.

get_nested([], Value, _Default) ->
    Value;
get_nested([Key | Rest], Map, Default) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, Value} -> get_nested(Rest, Value, Default);
        error -> Default
    end;
get_nested(_, _, Default) ->
    Default.
```

- [ ] **Step 5: Create fixtures directory and ensure test can find it**

The `fixture_path/1` helper uses `code:lib_dir(loom, test)`. The `test/fixtures/` directory must exist with the JSON files. Verify this works:

Run: `ls test/fixtures/minimal.json`
Expected: File exists.

- [ ] **Step 6: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: All tests PASS.

- [ ] **Step 7: Commit**

```bash
git add src/loom_config.erl test/loom_config_tests.erl test/fixtures/minimal.json
git commit -m "feat(config): implement JSON parsing and ETS storage (#65)"
```

---

### Task 3: Deep merge logic

**Files:**
- Modify: `test/loom_config_tests.erl`
- Create: `test/fixtures/full.json`
- Create: `test/fixtures/overrides.json`

- [ ] **Step 1: Create test fixtures**

Create `test/fixtures/full.json`:

```json
{
  "engines": [
    {
      "name": "test_engine",
      "backend": "mock",
      "model": "test-model",
      "gpu_ids": [0, 1]
    }
  ],
  "defaults": {
    "port": {
      "heartbeat_timeout_ms": 20000
    },
    "gpu_monitor": {
      "poll_interval_ms": 10000,
      "thresholds": {
        "temperature_c": 90.0
      }
    },
    "coordinator": {
      "max_concurrent": 128
    },
    "engine_sup": {
      "max_restarts": 10
    }
  },
  "server": {
    "port": 9090,
    "max_connections": 2048
  }
}
```

Create `test/fixtures/overrides.json`:

```json
{
  "engines": [
    {
      "name": "engine_a",
      "backend": "mock",
      "model": "model-a",
      "gpu_ids": [0],
      "port": {
        "heartbeat_timeout_ms": 30000
      },
      "gpu_monitor": {
        "poll_interval_ms": 2000,
        "thresholds": {
          "mem_percent": 80.0
        }
      },
      "coordinator": {
        "max_concurrent": 256
      }
    },
    {
      "name": "engine_b",
      "backend": "mock",
      "model": "model-b",
      "gpu_ids": [1]
    }
  ],
  "defaults": {
    "port": {
      "heartbeat_timeout_ms": 20000
    },
    "coordinator": {
      "max_concurrent": 128
    }
  }
}
```

- [ ] **Step 2: Write failing tests for merge logic**

Add to `test/loom_config_tests.erl`:

```erlang
%% --- Merge logic ---

merge_defaults_override_hardcoded_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("full.json")),
    {ok, E} = loom_config:get_engine(<<"test_engine">>),
    %% defaults override hardcoded
    Port = maps:get(port, E),
    ?assertEqual(20000, maps:get(heartbeat_timeout_ms, Port)),
    %% hardcoded values still present when not overridden
    ?assertEqual(5000, maps:get(spawn_timeout_ms, Port)),
    %% gpu_monitor defaults override hardcoded
    GpuMon = maps:get(gpu_monitor, E),
    ?assertEqual(10000, maps:get(poll_interval_ms, GpuMon)),
    %% deep merge: threshold override keeps non-overridden keys
    Thresholds = maps:get(thresholds, GpuMon),
    ?assertEqual(90.0, maps:get(temperature_c, Thresholds)),
    ?assertEqual(95.0, maps:get(mem_percent, Thresholds)),
    %% coordinator
    Coord = maps:get(coordinator, E),
    ?assertEqual(128, maps:get(max_concurrent, Coord)),
    ?assertEqual(120000, maps:get(startup_timeout_ms, Coord)),
    %% engine_sup
    Sup = maps:get(engine_sup, E),
    ?assertEqual(10, maps:get(max_restarts, Sup)),
    ?assertEqual(60, maps:get(max_period, Sup)),
    cleanup_ets().

merge_server_section_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("full.json")),
    Server = loom_config:get_server(),
    ?assertEqual(9090, maps:get(port, Server)),
    ?assertEqual(2048, maps:get(max_connections, Server)),
    %% hardcoded default still present
    ?assertEqual({0,0,0,0}, maps:get(ip, Server)),
    cleanup_ets().

per_engine_overrides_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("overrides.json")),
    %% engine_a has per-engine overrides
    {ok, A} = loom_config:get_engine(<<"engine_a">>),
    PortA = maps:get(port, A),
    ?assertEqual(30000, maps:get(heartbeat_timeout_ms, PortA)),
    CoordA = maps:get(coordinator, A),
    ?assertEqual(256, maps:get(max_concurrent, CoordA)),
    GpuMonA = maps:get(gpu_monitor, A),
    ?assertEqual(2000, maps:get(poll_interval_ms, GpuMonA)),
    %% deep merge: per-engine threshold overrides merge with hardcoded
    ThresholdsA = maps:get(thresholds, GpuMonA),
    ?assertEqual(80.0, maps:get(mem_percent, ThresholdsA)),
    ?assertEqual(85.0, maps:get(temperature_c, ThresholdsA)),
    %% engine_b has no per-engine overrides — gets defaults only
    {ok, B} = loom_config:get_engine(<<"engine_b">>),
    PortB = maps:get(port, B),
    ?assertEqual(20000, maps:get(heartbeat_timeout_ms, PortB)),
    CoordB = maps:get(coordinator, B),
    ?assertEqual(128, maps:get(max_concurrent, CoordB)),
    cleanup_ets().

engine_names_ordering_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("overrides.json")),
    ?assertEqual([<<"engine_a">>, <<"engine_b">>], loom_config:engine_names()),
    cleanup_ets().

get_engine_not_found_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("minimal.json")),
    ?assertEqual({error, not_found}, loom_config:get_engine(<<"nonexistent">>)),
    cleanup_ets().

get_nested_deep_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("full.json")),
    ?assertEqual(9090, loom_config:get([server, port], 0)),
    ?assertEqual(42, loom_config:get([server, nonexistent], 42)),
    ?assertEqual(99, loom_config:get([totally, missing, path], 99)),
    cleanup_ets().
```

- [ ] **Step 3: Run tests to verify they fail or pass**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: Tests should PASS if the merge logic from Task 2 is correct. If any fail, fix the merge logic.

- [ ] **Step 4: Fix any issues found, then commit**

```bash
git add test/loom_config_tests.erl test/fixtures/full.json test/fixtures/overrides.json
git commit -m "test(config): add merge logic and override tests (#65)"
```

---

### Task 4: Adapter resolution

**Files:**
- Modify: `test/loom_config_tests.erl`
- Modify: `src/loom_config.erl`

- [ ] **Step 1: Write failing tests for adapter resolution**

Add to `test/loom_config_tests.erl`:

```erlang
%% --- Adapter resolution ---

resolve_adapter_vllm_test() ->
    Expected = filename:join([code:priv_dir(loom), "python", "loom_adapter.py"]),
    ?assertEqual({ok, Expected},
                 loom_config:resolve_adapter(#{backend => <<"vllm">>})).

resolve_adapter_mlx_test() ->
    Expected = filename:join([code:priv_dir(loom), "python", "loom_adapter_mlx.py"]),
    ?assertEqual({ok, Expected},
                 loom_config:resolve_adapter(#{backend => <<"mlx">>})).

resolve_adapter_tensorrt_test() ->
    Expected = filename:join([code:priv_dir(loom), "python", "loom_adapter_trt.py"]),
    ?assertEqual({ok, Expected},
                 loom_config:resolve_adapter(#{backend => <<"tensorrt">>})).

resolve_adapter_custom_overrides_backend_test() ->
    ?assertEqual({ok, "/custom/adapter.py"},
                 loom_config:resolve_adapter(#{backend => <<"vllm">>,
                                               adapter_cmd => <<"/custom/adapter.py">>})).

resolve_adapter_mock_test() ->
    Expected = filename:join([code:priv_dir(loom), "python", "loom_adapter_mock.py"]),
    ?assertEqual({ok, Expected},
                 loom_config:resolve_adapter(#{backend => <<"mock">>})).

resolve_adapter_unknown_no_cmd_test() ->
    ?assertEqual({error, {unknown_backend, <<"foo">>}},
                 loom_config:resolve_adapter(#{backend => <<"foo">>})).

resolve_adapter_unknown_with_cmd_test() ->
    ?assertEqual({ok, "/my/custom.py"},
                 loom_config:resolve_adapter(#{backend => <<"foo">>,
                                               adapter_cmd => <<"/my/custom.py">>})).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: FAIL — `resolve_adapter/1` not exported.

- [ ] **Step 3: Implement adapter resolution**

Add to `src/loom_config.erl` exports:

```erlang
-export([resolve_adapter/1]).
```

Add implementation:

```erlang
-spec resolve_adapter(map()) -> {ok, string()} | {error, term()}.
resolve_adapter(#{adapter_cmd := Cmd}) when is_binary(Cmd), byte_size(Cmd) > 0 ->
    {ok, binary_to_list(Cmd)};
resolve_adapter(#{adapter_cmd := Cmd}) when is_list(Cmd), length(Cmd) > 0 ->
    {ok, Cmd};
resolve_adapter(#{backend := Backend}) ->
    case adapter_filename(Backend) of
        {ok, Filename} ->
            {ok, filename:join([code:priv_dir(loom), "python", Filename])};
        error ->
            {error, {unknown_backend, Backend}}
    end;
resolve_adapter(_) ->
    {error, {unknown_backend, undefined}}.

adapter_filename(<<"vllm">>) -> {ok, "loom_adapter.py"};
adapter_filename(<<"mlx">>) -> {ok, "loom_adapter_mlx.py"};
adapter_filename(<<"tensorrt">>) -> {ok, "loom_adapter_trt.py"};
adapter_filename(<<"mock">>) -> {ok, "loom_adapter_mock.py"};
adapter_filename(_) -> error.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/loom_config.erl test/loom_config_tests.erl
git commit -m "feat(config): implement adapter resolution from backend name (#65)"
```

---

### Task 5: Validation

**Files:**
- Modify: `test/loom_config_tests.erl`
- Modify: `src/loom_config.erl`

- [ ] **Step 1: Write failing tests for validation**

Add to `test/loom_config_tests.erl`:

```erlang
%% --- Validation ---

validate_missing_engines_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{}">>),
    ?assertMatch({error, {validation, {missing_field, root, engines}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engines_empty_list_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": []}">>),
    ?assertMatch({error, {validation, {empty_engines}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engines_not_list_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": \"not a list\"}">>),
    ?assertMatch({error, {validation, {invalid_type, engines, expected_list}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_missing_name_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"backend\": \"mock\", \"model\": \"m\"}]}">>),
    ?assertMatch({error, {validation, {missing_field, engine, name}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_missing_backend_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"e\", \"model\": \"m\"}]}">>),
    ?assertMatch({error, {validation, {missing_field, engine, backend}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_missing_model_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"e\", \"backend\": \"mock\"}]}">>),
    ?assertMatch({error, {validation, {missing_field, engine, model}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_invalid_name_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"bad name!\", \"backend\": \"mock\", \"model\": \"m\"}]}">>),
    ?assertMatch({error, {validation, {invalid_engine_name, _}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_engine_name_with_hyphens_and_dots_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"qwen2.5-1.5b\", \"backend\": \"mock\", \"model\": \"m\"}]}">>),
    ?assertEqual(ok, loom_config:load(Path)),
    ?assertEqual([<<"qwen2.5-1.5b">>], loom_config:engine_names()),
    file:delete(Path),
    cleanup_ets().

validate_duplicate_engine_names_test() ->
    cleanup_ets(),
    Json = <<"{\"engines\": [
        {\"name\": \"e1\", \"backend\": \"mock\", \"model\": \"m\"},
        {\"name\": \"e1\", \"backend\": \"mock\", \"model\": \"m2\"}
    ]}">>,
    Path = write_temp_file(Json),
    ?assertMatch({error, {validation, {duplicate_engine, <<"e1">>}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_unknown_backend_no_adapter_cmd_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"e1\", \"backend\": \"unknown_thing\", \"model\": \"m\"}]}">>),
    ?assertMatch({error, {validation, {unknown_backend, _, engine, _}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_unknown_backend_with_adapter_cmd_test() ->
    cleanup_ets(),
    Json = <<"{\"engines\": [{\"name\": \"e1\", \"backend\": \"custom\", \"model\": \"m\", \"adapter_cmd\": \"/bin/true\"}]}">>,
    Path = write_temp_file(Json),
    ?assertEqual(ok, loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_invalid_gpu_ids_test() ->
    cleanup_ets(),
    Path = write_temp_file(<<"{\"engines\": [{\"name\": \"e\", \"backend\": \"mock\", \"model\": \"m\", \"gpu_ids\": \"not_a_list\"}]}">>),
    ?assertMatch({error, {validation, {invalid_type, gpu_ids, expected_list}}},
                 loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().

validate_invalid_timeout_type_test() ->
    cleanup_ets(),
    Json = <<"{\"engines\": [{\"name\": \"e\", \"backend\": \"mock\", \"model\": \"m\"}], \"defaults\": {\"coordinator\": {\"max_concurrent\": \"not_int\"}}}">>,
    Path = write_temp_file(Json),
    ?assertMatch({error, {validation, _}}, loom_config:load(Path)),
    file:delete(Path),
    cleanup_ets().
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: Validation tests FAIL — `load/1` currently does not validate.

- [ ] **Step 3: Implement validation**

Update `src/loom_config.erl` — insert validation between parsing and storing. Replace `store_config/1`:

```erlang
store_config(Parsed) ->
    Atomized = atomize_keys(Parsed),
    case validate(Atomized) of
        ok ->
            do_store(Atomized);
        {error, _} = Err ->
            Err
    end.

do_store(Atomized) ->
    ensure_table(),
    ets:insert(?TABLE, {{config, parsed}, Atomized}),
    ServerJson = maps:get(server, Atomized, #{}),
    ServerMerged = maps:merge(server_defaults(), ServerJson),
    ets:insert(?TABLE, {{server, config}, ServerMerged}),
    Engines = maps:get(engines, Atomized, []),
    Defaults = maps:get(defaults, Atomized, #{}),
    EngineNames = lists:map(fun(E) ->
        Name = maps:get(name, E),
        Merged = merge_engine(E, Defaults),
        ets:insert(?TABLE, {{engine, Name}, Merged}),
        Name
    end, Engines),
    ets:insert(?TABLE, {{engine, names}, EngineNames}),
    ok.

%%% ===================================================================
%%% Validation
%%% ===================================================================

validate(Config) ->
    case validate_engines_present(Config) of
        ok ->
            Engines = maps:get(engines, Config),
            case validate_engines(Engines, []) of
                ok -> validate_defaults(Config);
                Err -> Err
            end;
        Err -> Err
    end.

validate_engines_present(#{engines := Engines}) when is_list(Engines), length(Engines) > 0 ->
    ok;
validate_engines_present(#{engines := []}) ->
    {error, {validation, {empty_engines}}};
validate_engines_present(#{engines := _}) ->
    {error, {validation, {invalid_type, engines, expected_list}}};
validate_engines_present(_) ->
    {error, {validation, {missing_field, root, engines}}}.

validate_engines([], _Seen) ->
    ok;
validate_engines([Engine | Rest], Seen) ->
    case validate_single_engine(Engine, Seen) of
        {ok, Name} -> validate_engines(Rest, [Name | Seen]);
        {error, _} = Err -> Err
    end.

validate_single_engine(Engine, Seen) ->
    case validate_required_engine_fields(Engine) of
        {ok, Name} ->
            case lists:member(Name, Seen) of
                true -> {error, {validation, {duplicate_engine, Name}}};
                false ->
                    case validate_engine_name_format(Name) of
                        ok ->
                            case validate_engine_backend(Engine) of
                                ok -> validate_engine_optional_fields(Engine, Name);
                                Err -> Err
                            end;
                        Err -> Err
                    end
            end;
        Err -> Err
    end.

validate_required_engine_fields(Engine) ->
    case maps:find(name, Engine) of
        {ok, Name} when is_binary(Name) ->
            case maps:find(backend, Engine) of
                {ok, _Backend} ->
                    case maps:find(model, Engine) of
                        {ok, _Model} -> {ok, Name};
                        error -> {error, {validation, {missing_field, engine, model}}}
                    end;
                error -> {error, {validation, {missing_field, engine, backend}}}
            end;
        error -> {error, {validation, {missing_field, engine, name}}}
    end.

validate_engine_name_format(Name) ->
    %% ASSUMPTION: Updated regex to allow hyphens and dots per README examples
    case re:run(Name, <<"^[a-zA-Z0-9._-]+$">>) of
        {match, _} when byte_size(Name) =< 64 -> ok;
        _ -> {error, {validation, {invalid_engine_name, Name}}}
    end.

validate_engine_backend(#{adapter_cmd := Cmd}) when is_binary(Cmd), byte_size(Cmd) > 0 ->
    ok;
validate_engine_backend(#{backend := Backend}) ->
    case adapter_filename(Backend) of
        {ok, _} -> ok;
        error -> {error, {validation, {unknown_backend, Backend, engine, maps:get(name, #{}, <<"unknown">>)}}}
    end;
validate_engine_backend(_) ->
    ok.

validate_engine_backend(#{adapter_cmd := Cmd}, _Name) when is_binary(Cmd), byte_size(Cmd) > 0 ->
    ok;
validate_engine_backend(#{backend := Backend}, Name) ->
    case adapter_filename(Backend) of
        {ok, _} -> ok;
        error -> {error, {validation, {unknown_backend, Backend, engine, Name}}}
    end.

validate_engine_optional_fields(Engine, Name) ->
    case maps:find(gpu_ids, Engine) of
        {ok, GpuIds} when not is_list(GpuIds) ->
            {error, {validation, {invalid_type, gpu_ids, expected_list}}};
        _ ->
            {ok, Name}
    end.

validate_defaults(#{defaults := Defaults}) when is_map(Defaults) ->
    validate_defaults_sections(Defaults);
validate_defaults(_) ->
    ok.

validate_defaults_sections(Defaults) ->
    Validators = [
        {coordinator, fun validate_positive_integer_fields/2,
         [startup_timeout_ms, drain_timeout_ms, max_concurrent]},
        {port, fun validate_positive_integer_fields/2,
         [max_line_length, spawn_timeout_ms, heartbeat_timeout_ms,
          shutdown_timeout_ms, post_close_timeout_ms]},
        {gpu_monitor, fun validate_positive_integer_fields/2,
         [poll_interval_ms, poll_timeout_ms]},
        {engine_sup, fun validate_positive_integer_fields/2,
         [max_restarts, max_period]}
    ],
    validate_sections(Defaults, Validators).

validate_sections(_Defaults, []) ->
    ok;
validate_sections(Defaults, [{Section, ValidatorFun, Fields} | Rest]) ->
    case maps:find(Section, Defaults) of
        {ok, SectionMap} when is_map(SectionMap) ->
            case ValidatorFun(SectionMap, Fields) of
                ok -> validate_sections(Defaults, Rest);
                Err -> Err
            end;
        _ ->
            validate_sections(Defaults, Rest)
    end.

validate_positive_integer_fields(_Map, []) ->
    ok;
validate_positive_integer_fields(Map, [Field | Rest]) ->
    case maps:find(Field, Map) of
        {ok, V} when is_integer(V), V > 0 ->
            validate_positive_integer_fields(Map, Rest);
        {ok, _V} ->
            {error, {validation, {invalid_type, Field, expected_positive_integer}}};
        error ->
            validate_positive_integer_fields(Map, Rest)
    end.
```

Note: The `validate_engine_backend/1` function needs to be replaced with `validate_engine_backend/2` that takes the engine name. Update `validate_single_engine` to call `validate_engine_backend(Engine, Name)` instead of `validate_engine_backend(Engine)`. Remove the arity-1 version.

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/loom_config.erl test/loom_config_tests.erl
git commit -m "feat(config): add config validation with structured errors (#65)"
```

---

### Task 6: Wire adapter resolution into engine merge

**Files:**
- Modify: `test/loom_config_tests.erl`
- Modify: `src/loom_config.erl`

- [ ] **Step 1: Write failing test — get_engine returns adapter_cmd**

Add to `test/loom_config_tests.erl`:

```erlang
%% --- Adapter integrated into engine config ---

engine_config_has_adapter_cmd_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("minimal.json")),
    {ok, E} = loom_config:get_engine(<<"test_engine">>),
    %% mock backend resolves to loom_adapter_mock.py
    AdapterCmd = maps:get(adapter_cmd, E),
    ?assert(is_list(AdapterCmd)),
    ?assertNotEqual(nomatch, string:find(AdapterCmd, "loom_adapter_mock.py")),
    cleanup_ets().

engine_config_custom_adapter_cmd_test() ->
    cleanup_ets(),
    Json = <<"{\"engines\": [{\"name\": \"e1\", \"backend\": \"custom\", \"model\": \"m\", \"adapter_cmd\": \"/bin/true\"}]}">>,
    Path = write_temp_file(Json),
    ok = loom_config:load(Path),
    {ok, E} = loom_config:get_engine(<<"e1">>),
    ?assertEqual("/bin/true", maps:get(adapter_cmd, E)),
    file:delete(Path),
    cleanup_ets().

engine_config_has_engine_id_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("minimal.json")),
    {ok, E} = loom_config:get_engine(<<"test_engine">>),
    %% name is mapped to engine_id for downstream compatibility
    ?assertEqual(<<"test_engine">>, maps:get(engine_id, E)),
    cleanup_ets().
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: FAIL — `adapter_cmd` and `engine_id` not in the merged engine map.

- [ ] **Step 3: Update merge_engine to resolve adapter and map name→engine_id**

Update `merge_engine/2` in `src/loom_config.erl` to add adapter resolution and engine_id mapping at the end:

```erlang
merge_engine(Engine, Defaults) ->
    PortDefaults = maps:get(port, Defaults, #{}),
    GpuMonDefaults = maps:get(gpu_monitor, Defaults, #{}),
    CoordDefaults = maps:get(coordinator, Defaults, #{}),
    SupDefaults = maps:get(engine_sup, Defaults, #{}),

    EnginePort = maps:get(port, Engine, #{}),
    EngineGpuMon = maps:get(gpu_monitor, Engine, #{}),
    EngineCoord = maps:get(coordinator, Engine, #{}),

    %% Resolve adapter command
    {ok, AdapterCmd} = resolve_adapter(Engine),

    Engine#{
        engine_id => maps:get(name, Engine),
        adapter_cmd => AdapterCmd,
        port => deep_merge(port_defaults(), deep_merge(PortDefaults, EnginePort)),
        gpu_monitor => deep_merge(gpu_monitor_defaults(), deep_merge(GpuMonDefaults, EngineGpuMon)),
        coordinator => deep_merge(coordinator_defaults(), deep_merge(CoordDefaults, EngineCoord)),
        engine_sup => maps:merge(engine_sup_defaults(), SupDefaults),
        gpu_ids => maps:get(gpu_ids, Engine, []),
        tp_size => maps:get(tp_size, Engine, 1)
    }.
```

Note: `resolve_adapter/1` is called after validation, so `{ok, _}` is guaranteed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/loom_config.erl test/loom_config_tests.erl
git commit -m "feat(config): wire adapter resolution into engine config merge (#65)"
```

---

### Task 7: IP address parsing in server config

**Files:**
- Modify: `test/loom_config_tests.erl`
- Modify: `src/loom_config.erl`

- [ ] **Step 1: Write failing test for IP parsing**

Add to `test/loom_config_tests.erl`:

```erlang
%% --- Server IP parsing ---

server_ip_string_to_tuple_test() ->
    cleanup_ets(),
    Json = <<"{\"engines\": [{\"name\": \"e\", \"backend\": \"mock\", \"model\": \"m\"}], \"server\": {\"port\": 9090, \"ip\": \"127.0.0.1\"}}">>,
    Path = write_temp_file(Json),
    ok = loom_config:load(Path),
    Server = loom_config:get_server(),
    ?assertEqual({127,0,0,1}, maps:get(ip, Server)),
    ?assertEqual(9090, maps:get(port, Server)),
    file:delete(Path),
    cleanup_ets().

server_ip_default_test() ->
    cleanup_ets(),
    ok = loom_config:load(fixture_path("minimal.json")),
    Server = loom_config:get_server(),
    ?assertEqual({0,0,0,0}, maps:get(ip, Server)),
    cleanup_ets().
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: FAIL — `ip` stays as binary `<<"0.0.0.0">>` from JSON instead of tuple.

- [ ] **Step 3: Add IP parsing to server config merge**

Update `do_store/1` in `src/loom_config.erl` — parse IP string after merging:

```erlang
do_store(Atomized) ->
    ensure_table(),
    ets:insert(?TABLE, {{config, parsed}, Atomized}),
    %% Server config with IP parsing
    ServerJson = maps:get(server, Atomized, #{}),
    ServerMerged0 = maps:merge(server_defaults(), ServerJson),
    ServerMerged = parse_server_ip(ServerMerged0),
    ets:insert(?TABLE, {{server, config}, ServerMerged}),
    %% Engine configs
    Engines = maps:get(engines, Atomized, []),
    Defaults = maps:get(defaults, Atomized, #{}),
    EngineNames = lists:map(fun(E) ->
        Name = maps:get(name, E),
        Merged = merge_engine(E, Defaults),
        ets:insert(?TABLE, {{engine, Name}, Merged}),
        Name
    end, Engines),
    ets:insert(?TABLE, {{engine, names}, EngineNames}),
    ok.

parse_server_ip(#{ip := Ip} = Server) when is_binary(Ip) ->
    case inet:parse_address(binary_to_list(Ip)) of
        {ok, Addr} -> Server#{ip => Addr};
        {error, _} -> Server
    end;
parse_server_ip(Server) ->
    Server.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_config_tests`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add src/loom_config.erl test/loom_config_tests.erl
git commit -m "feat(config): parse IP address strings to tuples in server config (#65)"
```

---

### Task 8: Common Test suite for ETS integration

**Files:**
- Create: `test/loom_config_SUITE.erl`

- [ ] **Step 1: Write CT suite**

Create `test/loom_config_SUITE.erl`:

```erlang
-module(loom_config_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    load_and_read_full_cycle_test/1,
    multiple_engines_test/1,
    concurrent_reads_test/1,
    reload_replaces_config_test/1,
    ets_table_is_public_test/1
]).

all() ->
    [
        load_and_read_full_cycle_test,
        multiple_engines_test,
        concurrent_reads_test,
        reload_replaces_config_test,
        ets_table_is_public_test
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    cleanup_ets(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    cleanup_ets(),
    ok.

%% --- Tests ---

load_and_read_full_cycle_test(_Config) ->
    Path = fixture_path("full.json"),
    ?assertEqual(ok, loom_config:load(Path)),
    %% Read engine
    {ok, Engine} = loom_config:get_engine(<<"test_engine">>),
    ?assertEqual(<<"test_engine">>, maps:get(engine_id, Engine)),
    ?assertEqual(<<"mock">>, maps:get(backend, Engine)),
    ?assertEqual(<<"test-model">>, maps:get(model, Engine)),
    ?assertEqual([0, 1], maps:get(gpu_ids, Engine)),
    %% Read server
    Server = loom_config:get_server(),
    ?assertEqual(9090, maps:get(port, Server)),
    %% Read nested via get/2
    ?assertEqual(9090, loom_config:get([server, port], 0)).

multiple_engines_test(_Config) ->
    Path = fixture_path("overrides.json"),
    ok = loom_config:load(Path),
    ?assertEqual([<<"engine_a">>, <<"engine_b">>], loom_config:engine_names()),
    {ok, A} = loom_config:get_engine(<<"engine_a">>),
    {ok, B} = loom_config:get_engine(<<"engine_b">>),
    ?assertEqual(<<"model-a">>, maps:get(model, A)),
    ?assertEqual(<<"model-b">>, maps:get(model, B)),
    %% Different merge results
    CoordA = maps:get(coordinator, A),
    CoordB = maps:get(coordinator, B),
    ?assertEqual(256, maps:get(max_concurrent, CoordA)),
    ?assertEqual(128, maps:get(max_concurrent, CoordB)).

concurrent_reads_test(_Config) ->
    Path = fixture_path("full.json"),
    ok = loom_config:load(Path),
    Self = self(),
    NumReaders = 50,
    Pids = [spawn_link(fun() ->
        %% Each reader does 100 lookups
        lists:foreach(fun(_) ->
            {ok, _} = loom_config:get_engine(<<"test_engine">>),
            _ = loom_config:get_server(),
            _ = loom_config:engine_names()
        end, lists:seq(1, 100)),
        Self ! {done, self()}
    end) || _ <- lists:seq(1, NumReaders)],
    %% Wait for all readers
    lists:foreach(fun(Pid) ->
        receive {done, Pid} -> ok
        after 5000 -> ct:fail({timeout, Pid})
        end
    end, Pids).

reload_replaces_config_test(_Config) ->
    %% Load initial config
    ok = loom_config:load(fixture_path("minimal.json")),
    ?assertEqual([<<"test_engine">>], loom_config:engine_names()),
    Server1 = loom_config:get_server(),
    ?assertEqual(8080, maps:get(port, Server1)),
    %% Reload with different config
    ok = loom_config:load(fixture_path("full.json")),
    ?assertEqual([<<"test_engine">>], loom_config:engine_names()),
    Server2 = loom_config:get_server(),
    ?assertEqual(9090, maps:get(port, Server2)).

ets_table_is_public_test(_Config) ->
    ok = loom_config:load(fixture_path("minimal.json")),
    %% Verify the ETS table is readable from another process
    Self = self(),
    spawn_link(fun() ->
        Result = loom_config:engine_names(),
        Self ! {result, Result}
    end),
    receive
        {result, Names} -> ?assertEqual([<<"test_engine">>], Names)
    after 5000 -> ct:fail(timeout)
    end.

%% --- Helpers ---

fixture_path(Name) ->
    filename:join([code:lib_dir(loom, test), "fixtures", Name]).

cleanup_ets() ->
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end.
```

- [ ] **Step 2: Run CT suite to verify tests pass**

Run: `rebar3 ct --suite=test/loom_config_SUITE`
Expected: All 5 tests PASS.

- [ ] **Step 3: Commit**

```bash
git add test/loom_config_SUITE.erl
git commit -m "test(config): add Common Test suite for ETS integration (#65)"
```

---

### Task 9: Update engine_id regex in existing modules

**Files:**
- Modify: `src/loom_engine_sup.erl`
- Modify: `src/loom_engine_coordinator.erl`

- [ ] **Step 1: Find the current regex patterns**

In `loom_engine_sup.erl`, find the `validate_engine_id` function containing `<<"^[a-zA-Z0-9_]+$">>`.

In `loom_engine_coordinator.erl`, find the `validate_config` function containing `<<"^[a-zA-Z0-9_]+$">>`.

- [ ] **Step 2: Update loom_engine_sup.erl regex**

Change:
```erlang
<<"^[a-zA-Z0-9_]+$">>
```
To:
```erlang
<<"^[a-zA-Z0-9._-]+$">>
```

- [ ] **Step 3: Update loom_engine_coordinator.erl regex**

Change:
```erlang
<<"^[a-zA-Z0-9_]+$">>
```
To:
```erlang
<<"^[a-zA-Z0-9._-]+$">>
```

- [ ] **Step 4: Run existing tests to verify nothing breaks**

Run: `rebar3 eunit && rebar3 ct`
Expected: All existing tests still PASS.

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_sup.erl src/loom_engine_coordinator.erl
git commit -m "fix(engine): update engine_id regex to allow hyphens and dots (#65)"
```

---

### Task 10: Create default config/loom.json and type specs

**Files:**
- Create: `config/loom.json`
- Modify: `src/loom_config.erl`

- [ ] **Step 1: Create development config file**

Create `config/loom.json`:

```json
{
  "engines": [
    {
      "name": "engine_0",
      "backend": "mock",
      "model": "mock-model",
      "gpu_ids": []
    }
  ],
  "server": {
    "port": 8080
  }
}
```

- [ ] **Step 2: Add full type specs to loom_config.erl**

Add at the top of `src/loom_config.erl` after the module declaration:

```erlang
-type config_path() :: [atom()].
-type validation_error() ::
    {config_file, atom(), file:filename()} |
    {json_parse, term()} |
    {validation, term()}.

-export_type([config_path/0, validation_error/0]).
```

Verify all exported functions have `-spec` annotations (they should from Task 1).

- [ ] **Step 3: Run Dialyzer**

Run: `rebar3 dialyzer`
Expected: No warnings for `loom_config`.

- [ ] **Step 4: Run all tests**

Run: `rebar3 eunit && rebar3 ct`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add config/loom.json src/loom_config.erl
git commit -m "feat(config): add default loom.json and type specs (#65)"
```

---

### Task 11: Final cleanup and xref/dialyzer compliance

**Files:**
- Modify: `src/loom_config.erl` (if needed)

- [ ] **Step 1: Run xref**

Run: `rebar3 xref`
Expected: No undefined function calls, no deprecated calls.

- [ ] **Step 2: Run Dialyzer**

Run: `rebar3 dialyzer`
Expected: No warnings.

- [ ] **Step 3: Run full test suite**

Run: `rebar3 eunit && rebar3 ct`
Expected: All tests PASS across all modules (existing + new).

- [ ] **Step 4: Fix any issues found in steps 1-3**

If xref/dialyzer/tests surface issues, fix them.

- [ ] **Step 5: Commit if any fixes were needed**

```bash
git add -A
git commit -m "fix(config): resolve xref/dialyzer warnings (#65)"
```
