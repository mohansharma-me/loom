# MLX Integration Test Suite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** End-to-end integration test suite validating the full Loom stack against a real MLX inference engine on Apple Silicon.

**Architecture:** Single Common Test suite (`loom_mlx_integration_SUITE`) starts the full OTP application with an MLX engine config, waits for model load, runs 8 sequential test cases (health, memory, OpenAI/Anthropic chat + streaming, GPU metrics, crash recovery), then tears down. Prerequisite checks skip the suite gracefully when MLX/model aren't available.

**Tech Stack:** Erlang Common Test, Gun HTTP client (test dep), loom_json for JSON, loom_test_helpers for app lifecycle.

---

## File Structure

| File | Responsibility |
|------|---------------|
| `test/integration/loom_mlx_integration_SUITE.erl` | Test suite: prerequisites, app lifecycle, 8 test cases, HTTP/SSE helpers |
| `test/integration/README.md` | Setup instructions and run commands |

---

### Task 1: Suite Skeleton with Prerequisite Skip Logic

**Files:**
- Create: `test/integration/loom_mlx_integration_SUITE.erl`

This task creates the module, CT callbacks, and prerequisite checking in `init_per_suite`. No test cases yet — just the skeleton that either starts the app or skips.

- [ ] **Step 1: Create the suite file with module header, exports, and macros**

```erlang
%%%-------------------------------------------------------------------
%%% @doc End-to-end integration tests with real MLX inference engine.
%%%
%%% Requires Apple Silicon Mac with mlx-lm installed and the test model
%%% cached locally. The suite auto-skips with setup instructions if
%%% prerequisites are not met.
%%%
%%% ASSUMPTION: python3 is on PATH.
%%% ASSUMPTION: The huggingface-hub cache is at ~/.cache/huggingface/hub/.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_mlx_integration_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, init_per_suite/1, end_per_suite/1]).

%% Test cases
-export([
    health_endpoint_test/1,
    memory_metrics_test/1,
    chat_completion_openai_test/1,
    chat_completion_anthropic_test/1,
    sse_streaming_openai_test/1,
    sse_streaming_anthropic_test/1,
    gpu_metrics_sanity_test/1,
    crash_recovery_test/1
]).

-define(MODEL, <<"mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit">>).
-define(ENGINE_ID, <<"mlx_integration_engine">>).
-define(BASE_PORT, 18080).
-define(ENGINE_READY_TIMEOUT, 120000).
-define(REQUEST_TIMEOUT, 60000).

all() ->
    [health_endpoint_test,
     memory_metrics_test,
     chat_completion_openai_test,
     chat_completion_anthropic_test,
     sse_streaming_openai_test,
     sse_streaming_anthropic_test,
     gpu_metrics_sanity_test,
     crash_recovery_test].
```

- [ ] **Step 2: Add init_per_suite with prerequisite checks and app startup**

```erlang
init_per_suite(Config) ->
    case check_prerequisites() of
        ok ->
            start_mlx_engine(Config);
        {skip, Reason} ->
            {skip, Reason}
    end.

check_prerequisites() ->
    Checks = [
        fun check_platform/0,
        fun check_python/0,
        fun check_mlx/0,
        fun check_model_cached/0
    ],
    run_checks(Checks).

run_checks([]) -> ok;
run_checks([Check | Rest]) ->
    case Check() of
        ok -> run_checks(Rest);
        {skip, _} = Skip -> Skip
    end.

check_platform() ->
    case os:type() of
        {unix, darwin} ->
            case string:trim(os:cmd("sysctl -n hw.optional.arm64 2>/dev/null")) of
                "1" -> ok;
                _ -> {skip, "Requires Apple Silicon Mac (ARM64 macOS)"}
            end;
        _ ->
            {skip, "Requires Apple Silicon Mac (ARM64 macOS)"}
    end.

check_python() ->
    case os:find_executable("python3") of
        false -> {skip, "python3 not found. Install via: brew install python@3.11"};
        _ -> ok
    end.

check_mlx() ->
    Cmd = "python3 -c \"import mlx_lm\" 2>&1; echo $?",
    Result = string:trim(os:cmd(Cmd)),
    %% Last line of output is the exit code
    Lines = string:split(Result, "\n", all),
    ExitCode = string:trim(lists:last(Lines)),
    case ExitCode of
        "0" -> ok;
        _ ->
            {skip, "MLX dependencies not installed. Run:\n"
                   "  pip install mlx-lm>=0.20.0 huggingface-hub psutil"}
    end.

check_model_cached() ->
    Model = binary_to_list(?MODEL),
    Cmd = lists:flatten(io_lib:format(
        "python3 -c \"from huggingface_hub import snapshot_download; "
        "snapshot_download('~s', local_files_only=True)\" 2>&1; echo $?",
        [Model])),
    Result = string:trim(os:cmd(Cmd)),
    Lines = string:split(Result, "\n", all),
    ExitCode = string:trim(lists:last(Lines)),
    case ExitCode of
        "0" -> ok;
        _ ->
            {skip, lists:flatten(io_lib:format(
                "Model not cached locally. Run:\n"
                "  huggingface-cli download ~s\n"
                "First download is ~700MB. Subsequent test runs use the cache.",
                [Model]))}
    end.
```

- [ ] **Step 3: Add start_mlx_engine helper that writes config and starts the app**

```erlang
start_mlx_engine(Config) ->
    Port = find_free_port(?BASE_PORT),
    ConfigMap = #{
        <<"engines">> => [#{
            <<"name">> => ?ENGINE_ID,
            <<"backend">> => <<"mlx">>,
            <<"model">> => ?MODEL,
            <<"gpu_ids">> => [0],
            <<"coordinator">> => #{
                <<"startup_timeout_ms">> => ?ENGINE_READY_TIMEOUT
            }
        }],
        <<"server">> => #{
            <<"port">> => Port
        }
    },
    {ok, ConfigPath} = loom_test_helpers:write_temp_config(ConfigMap),
    loom_test_helpers:cleanup_ets(),
    ok = loom_config:load(ConfigPath),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(loom),

    %% Wait for engine to reach ready state
    ok = wait_engine_ready(?ENGINE_ID, ?ENGINE_READY_TIMEOUT),
    ct:pal("MLX engine ready on port ~B", [Port]),

    [{http_port, Port},
     {config_path, ConfigPath},
     {engine_id, ?ENGINE_ID} | Config].

find_free_port(Port) when Port > ?BASE_PORT + 9 ->
    ct:fail("No free port found in range ~B-~B", [?BASE_PORT, ?BASE_PORT + 9]);
find_free_port(Port) ->
    case gen_tcp:listen(Port, []) of
        {ok, Sock} ->
            gen_tcp:close(Sock),
            Port;
        {error, eaddrinuse} ->
            find_free_port(Port + 1)
    end.

wait_engine_ready(EngineId, Timeout) ->
    loom_test_helpers:wait_for_status(
        fun() ->
            try loom_engine_coordinator:get_status(EngineId)
            catch _:_ -> not_ready
            end
        end,
        ready,
        Timeout).
```

- [ ] **Step 4: Add end_per_suite**

```erlang
end_per_suite(Config) ->
    loom_test_helpers:stop_app(),
    catch application:stop(gun),
    case ?config(config_path, Config) of
        undefined -> ok;
        Path -> file:delete(Path)
    end,
    ok.
```

- [ ] **Step 5: Add stub test cases that just pass (to verify suite compiles and loads)**

```erlang
health_endpoint_test(_Config) -> ok.
memory_metrics_test(_Config) -> ok.
chat_completion_openai_test(_Config) -> ok.
chat_completion_anthropic_test(_Config) -> ok.
sse_streaming_openai_test(_Config) -> ok.
sse_streaming_anthropic_test(_Config) -> ok.
gpu_metrics_sanity_test(_Config) -> ok.
crash_recovery_test(_Config) -> ok.
```

- [ ] **Step 6: Verify the suite compiles**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 as test compile`
Expected: Clean compilation, no errors.

- [ ] **Step 7: Commit**

```bash
git add test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add MLX integration suite skeleton with prerequisite checks"
```

---

### Task 2: Health Endpoint Test

**Files:**
- Modify: `test/integration/loom_mlx_integration_SUITE.erl`

- [ ] **Step 1: Replace the stub `health_endpoint_test` with the real implementation**

```erlang
health_endpoint_test(Config) ->
    Port = ?config(http_port, Config),
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, 200, _Headers} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual(<<"ready">>, maps:get(<<"status">>, Decoded)),
    ?assertEqual(?ENGINE_ID, maps:get(<<"engine_id">>, Decoded)),
    Load = maps:get(<<"load">>, Decoded),
    ?assert(is_integer(Load)),
    ?assert(Load >= 0),
    gun:close(ConnPid).
```

- [ ] **Step 2: Verify test passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case health_endpoint_test`
Expected: PASS (assuming MLX prerequisites are met; otherwise suite skips).

- [ ] **Step 3: Commit**

```bash
git add test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add health endpoint integration test"
```

---

### Task 3: Memory Metrics Test

**Files:**
- Modify: `test/integration/loom_mlx_integration_SUITE.erl`

- [ ] **Step 1: Add `find_gpu_monitor/1` helper to locate the GPU monitor pid**

```erlang
%% @doc Find the GPU monitor pid from the engine supervisor's children.
find_gpu_monitor(EngineId) ->
    SupName = loom_engine_sup:sup_name(EngineId),
    Children = supervisor:which_children(SupName),
    case [Pid || {{gpu_monitor, _GpuId}, Pid, worker, _} <- Children, is_pid(Pid)] of
        [MonitorPid | _] -> MonitorPid;
        [] -> ct:fail("No GPU monitor found in engine supervisor")
    end.
```

- [ ] **Step 2: Add `get_machine_ram_gb/0` helper**

```erlang
%% @doc Get the machine's total RAM in GB via sysctl.
get_machine_ram_gb() ->
    RamBytes = list_to_integer(string:trim(os:cmd("sysctl -n hw.memsize"))),
    RamBytes / (1024 * 1024 * 1024).
```

- [ ] **Step 3: Replace the stub `memory_metrics_test` with the real implementation**

```erlang
memory_metrics_test(Config) ->
    EngineId = ?config(engine_id, Config),
    MonitorPid = find_gpu_monitor(EngineId),
    %% Force a fresh poll to get current readings
    {ok, Metrics} = loom_gpu_monitor:force_poll(MonitorPid),
    MemTotalGb = maps:get(mem_total_gb, Metrics),
    MemUsedGb = maps:get(mem_used_gb, Metrics),
    MachineRamGb = get_machine_ram_gb(),
    %% Sanity: total matches machine RAM within 0.5 GB
    ?assert(abs(MemTotalGb - MachineRamGb) < 0.5),
    %% Sanity: used is positive and less than total
    ?assert(MemUsedGb > 0),
    ?assert(MemUsedGb < MemTotalGb),
    ct:pal("Memory: ~.1f/~.1f GB used (machine: ~.1f GB)",
           [MemUsedGb, MemTotalGb, MachineRamGb]).
```

- [ ] **Step 4: Verify test passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case memory_metrics_test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add memory metrics integration test"
```

---

### Task 4: OpenAI Chat Completion Test (Non-Streaming)

**Files:**
- Modify: `test/integration/loom_mlx_integration_SUITE.erl`

- [ ] **Step 1: Replace the stub `chat_completion_openai_test`**

```erlang
chat_completion_openai_test(Config) ->
    Port = ?config(http_port, Config),
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => ?MODEL,
        <<"messages">> => [#{<<"role">> => <<"user">>,
                             <<"content">> => <<"Say hello in one sentence.">>}],
        <<"stream">> => false
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _Headers} = gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    Decoded = loom_json:decode(RespBody),
    %% Verify OpenAI response structure
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Decoded)),
    [Choice] = maps:get(<<"choices">>, Decoded),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    Content = maps:get(<<"content">>, Msg),
    ?assert(is_binary(Content)),
    ?assert(byte_size(Content) > 0),
    %% Verify usage stats
    Usage = maps:get(<<"usage">>, Decoded),
    ?assert(maps:get(<<"prompt_tokens">>, Usage) > 0),
    ?assert(maps:get(<<"completion_tokens">>, Usage) > 0),
    ct:pal("OpenAI response (~B tokens): ~s",
           [maps:get(<<"completion_tokens">>, Usage), Content]),
    gun:close(ConnPid).
```

- [ ] **Step 2: Verify test passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case chat_completion_openai_test`
Expected: PASS — returns a non-empty completion from TinyLlama.

- [ ] **Step 3: Commit**

```bash
git add test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add OpenAI chat completion integration test"
```

---

### Task 5: Anthropic Chat Completion Test (Non-Streaming)

**Files:**
- Modify: `test/integration/loom_mlx_integration_SUITE.erl`

- [ ] **Step 1: Replace the stub `chat_completion_anthropic_test`**

```erlang
chat_completion_anthropic_test(Config) ->
    Port = ?config(http_port, Config),
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => ?MODEL,
        <<"max_tokens">> => 64,
        <<"messages">> => [#{<<"role">> => <<"user">>,
                             <<"content">> => <<"Say hello in one sentence.">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _Headers} = gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    Decoded = loom_json:decode(RespBody),
    %% Verify Anthropic response structure
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Decoded)),
    [ContentBlock] = maps:get(<<"content">>, Decoded),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, ContentBlock)),
    Text = maps:get(<<"text">>, ContentBlock),
    ?assert(is_binary(Text)),
    ?assert(byte_size(Text) > 0),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Decoded)),
    %% Verify usage stats
    Usage = maps:get(<<"usage">>, Decoded),
    ?assert(maps:get(<<"input_tokens">>, Usage) > 0),
    ?assert(maps:get(<<"output_tokens">>, Usage) > 0),
    ct:pal("Anthropic response (~B tokens): ~s",
           [maps:get(<<"output_tokens">>, Usage), Text]),
    gun:close(ConnPid).
```

- [ ] **Step 2: Verify test passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case chat_completion_anthropic_test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add Anthropic chat completion integration test"
```

---

### Task 6: OpenAI SSE Streaming Test

**Files:**
- Modify: `test/integration/loom_mlx_integration_SUITE.erl`

- [ ] **Step 1: Add SSE collection helpers (same pattern as loom_handler_chat_SUITE)**

```erlang
%%====================================================================
%% SSE Helpers
%%====================================================================

%% @doc Collect SSE data lines from a Gun streaming response.
%% Returns list of raw data binaries (including "[DONE]").
collect_sse_data(ConnPid, StreamRef, Acc) ->
    case gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
        {data, nofin, Chunk} ->
            Events = parse_sse_data(Chunk),
            collect_sse_data(ConnPid, StreamRef, Acc ++ Events);
        {data, fin, Chunk} ->
            Events = parse_sse_data(Chunk),
            Acc ++ Events;
        {error, _} ->
            Acc
    end.

parse_sse_data(Chunk) ->
    Lines = binary:split(Chunk, <<"\n">>, [global, trim_all]),
    lists:filtermap(fun(Line) ->
        case Line of
            <<"data: ", Data/binary>> -> {true, Data};
            _ -> false
        end
    end, Lines).

%% @doc Collect SSE events with event type from a Gun streaming response.
%% Returns list of {EventType, DataBinary} tuples.
collect_sse_events(ConnPid, StreamRef, Acc) ->
    case gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
        {data, nofin, Chunk} ->
            Events = parse_sse_events(Chunk),
            collect_sse_events(ConnPid, StreamRef, Acc ++ Events);
        {data, fin, Chunk} ->
            Events = parse_sse_events(Chunk),
            Acc ++ Events;
        {error, _} ->
            Acc
    end.

parse_sse_events(Chunk) ->
    Blocks = binary:split(Chunk, <<"\n\n">>, [global, trim_all]),
    lists:filtermap(fun(Block) ->
        Lines = binary:split(Block, <<"\n">>, [global]),
        EventType = find_sse_field(<<"event: ">>, Lines),
        Data = find_sse_field(<<"data: ">>, Lines),
        case {EventType, Data} of
            {undefined, undefined} -> false;
            {undefined, D} -> {true, {<<"data">>, D}};
            {E, D} -> {true, {E, D}}
        end
    end, Blocks).

find_sse_field(Prefix, Lines) ->
    PLen = byte_size(Prefix),
    case lists:filtermap(fun(Line) ->
        case Line of
            <<Prefix:PLen/binary, Rest/binary>> -> {true, Rest};
            _ -> false
        end
    end, Lines) of
        [Value | _] -> Value;
        [] -> undefined
    end.
```

- [ ] **Step 2: Replace the stub `sse_streaming_openai_test`**

```erlang
sse_streaming_openai_test(Config) ->
    Port = ?config(http_port, Config),
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => ?MODEL,
        <<"messages">> => [#{<<"role">> => <<"user">>,
                             <<"content">> => <<"Say hello in one sentence.">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, Headers} = gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertMatch(<<"text/event-stream", _/binary>>, ContentType),
    %% Collect all SSE data chunks
    Events = collect_sse_data(ConnPid, StreamRef, []),
    ?assert(length(Events) >= 3),
    %% Last event should be [DONE]
    ?assertEqual(<<"[DONE]">>, lists:last(Events)),
    %% Parse JSON chunks (excluding [DONE])
    JsonEvents = lists:droplast(Events),
    ?assert(length(JsonEvents) >= 2),
    %% Verify each chunk has the expected structure
    lists:foreach(fun(DataBin) ->
        Chunk = loom_json:decode(DataBin),
        [Choice] = maps:get(<<"choices">>, Chunk),
        _Delta = maps:get(<<"delta">>, Choice)
    end, JsonEvents),
    %% Verify the last JSON chunk has finish_reason
    LastJson = loom_json:decode(lists:last(JsonEvents)),
    [LastChoice] = maps:get(<<"choices">>, LastJson),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, LastChoice)),
    %% Concatenate all token content
    Tokens = lists:filtermap(fun(DataBin) ->
        Chunk = loom_json:decode(DataBin),
        [Choice] = maps:get(<<"choices">>, Chunk),
        Delta = maps:get(<<"delta">>, Choice),
        case maps:find(<<"content">>, Delta) of
            {ok, C} when is_binary(C), byte_size(C) > 0 -> {true, C};
            _ -> false
        end
    end, JsonEvents),
    FullContent = iolist_to_binary(Tokens),
    ?assert(byte_size(FullContent) > 0),
    ct:pal("OpenAI streaming: ~B chunks, content: ~s",
           [length(JsonEvents), FullContent]),
    gun:close(ConnPid).
```

- [ ] **Step 3: Verify test passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case sse_streaming_openai_test`
Expected: PASS — receives multiple SSE chunks with token content, ending with [DONE].

- [ ] **Step 4: Commit**

```bash
git add test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add OpenAI SSE streaming integration test"
```

---

### Task 7: Anthropic SSE Streaming Test

**Files:**
- Modify: `test/integration/loom_mlx_integration_SUITE.erl`

- [ ] **Step 1: Replace the stub `sse_streaming_anthropic_test`**

```erlang
sse_streaming_anthropic_test(Config) ->
    Port = ?config(http_port, Config),
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => ?MODEL,
        <<"max_tokens">> => 64,
        <<"messages">> => [#{<<"role">> => <<"user">>,
                             <<"content">> => <<"Say hello in one sentence.">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, Headers} = gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertMatch(<<"text/event-stream", _/binary>>, ContentType),
    %% Collect SSE events with event types
    Events = collect_sse_events(ConnPid, StreamRef, []),
    EventTypes = [Type || {Type, _} <- Events],
    %% Verify Anthropic event sequence
    ?assertEqual(<<"message_start">>, hd(EventTypes)),
    ?assertEqual(<<"content_block_start">>, lists:nth(2, EventTypes)),
    ?assertEqual(<<"message_stop">>, lists:last(EventTypes)),
    ?assert(lists:member(<<"message_delta">>, EventTypes)),
    ?assert(lists:member(<<"content_block_stop">>, EventTypes)),
    %% Count content_block_delta events (should be at least 2 for real inference)
    DeltaCount = length([T || T <- EventTypes, T =:= <<"content_block_delta">>]),
    ?assert(DeltaCount >= 2),
    %% Concatenate delta text
    DeltaTexts = lists:filtermap(fun
        ({<<"content_block_delta">>, DataBin}) ->
            Data = loom_json:decode(DataBin),
            Delta = maps:get(<<"delta">>, Data),
            case maps:find(<<"text">>, Delta) of
                {ok, T} when is_binary(T) -> {true, T};
                _ -> false
            end;
        (_) -> false
    end, Events),
    FullText = iolist_to_binary(DeltaTexts),
    ?assert(byte_size(FullText) > 0),
    ct:pal("Anthropic streaming: ~B deltas, content: ~s",
           [DeltaCount, FullText]),
    gun:close(ConnPid).
```

- [ ] **Step 2: Verify test passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case sse_streaming_anthropic_test`
Expected: PASS — receives the full Anthropic SSE event sequence.

- [ ] **Step 3: Commit**

```bash
git add test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add Anthropic SSE streaming integration test"
```

---

### Task 8: GPU Metrics Sanity Test

**Files:**
- Modify: `test/integration/loom_mlx_integration_SUITE.erl`

- [ ] **Step 1: Replace the stub `gpu_metrics_sanity_test`**

```erlang
gpu_metrics_sanity_test(Config) ->
    EngineId = ?config(engine_id, Config),
    MonitorPid = find_gpu_monitor(EngineId),
    {ok, Metrics} = loom_gpu_monitor:force_poll(MonitorPid),
    %% Verify mem_total_gb matches machine RAM
    MemTotalGb = maps:get(mem_total_gb, Metrics),
    MachineRamGb = get_machine_ram_gb(),
    ?assert(abs(MemTotalGb - MachineRamGb) < 0.5),
    %% Verify mem_used_gb is sensible
    MemUsedGb = maps:get(mem_used_gb, Metrics),
    ?assert(MemUsedGb > 0),
    ?assert(MemUsedGb < MemTotalGb),
    %% gpu_util: on Apple Silicon this is 0.0 or -1.0 (no Metal API).
    %% Just verify it's a number.
    GpuUtil = maps:get(gpu_util, Metrics),
    ?assert(is_float(GpuUtil) orelse is_integer(GpuUtil)),
    %% Verify timestamp is recent (within last 30s)
    Timestamp = maps:get(timestamp, Metrics),
    Now = erlang:system_time(millisecond),
    ?assert(Now - Timestamp < 30000),
    ct:pal("GPU metrics: util=~.1f%, mem=~.1f/~.1f GB, age=~Bms",
           [GpuUtil, MemUsedGb, MemTotalGb, Now - Timestamp]).
```

- [ ] **Step 2: Verify test passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case gpu_metrics_sanity_test`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add GPU metrics sanity integration test"
```

---

### Task 9: Crash Recovery Test

**Files:**
- Modify: `test/integration/loom_mlx_integration_SUITE.erl`

- [ ] **Step 1: Add crash recovery helpers (following loom_crash_recovery_SUITE patterns)**

```erlang
%% @doc Find the coordinator pid from the engine supervisor.
find_coordinator(EngineId) ->
    SupName = loom_engine_sup:sup_name(EngineId),
    Children = supervisor:which_children(SupName),
    case lists:keyfind(coordinator, 1, Children) of
        {coordinator, Pid, worker, _} when is_pid(Pid) -> Pid;
        _ -> ct:fail("coordinator not found in supervisor")
    end.

%% @doc Find the loom_port pid from the coordinator's links.
find_port_pid(CoordPid, EngineId) ->
    SupPid = whereis(loom_engine_sup:sup_name(EngineId)),
    {links, Links} = process_info(CoordPid, links),
    PortPids = [P || P <- Links, is_pid(P), P =/= SupPid],
    case PortPids of
        [PortPid | _] -> PortPid;
        [] -> undefined
    end.

%% @doc Get the OS PID of the adapter process.
get_adapter_os_pid(CoordPid, EngineId) ->
    PortPid = find_port_pid(CoordPid, EngineId),
    ?assert(is_pid(PortPid)),
    OsPid = loom_port:get_os_pid(PortPid),
    ?assert(is_integer(OsPid)),
    OsPid.

%% @doc Poll until status is NOT the given value (or timeout).
wait_status_not(EngineId, Status, Timeout) when Timeout > 0 ->
    Result = try loom_engine_coordinator:get_status(EngineId)
             catch _:_ -> {ets_or_proc_unavailable}
             end,
    case Result of
        Status ->
            timer:sleep(50),
            wait_status_not(EngineId, Status, Timeout - 50);
        _ ->
            ok
    end;
wait_status_not(_EngineId, _Status, _Timeout) ->
    ok.
```

- [ ] **Step 2: Replace the stub `crash_recovery_test`**

```erlang
crash_recovery_test(Config) ->
    EngineId = ?config(engine_id, Config),
    Port = ?config(http_port, Config),

    %% Verify engine is ready before crash
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),

    %% Get the adapter's OS PID
    CoordPid = find_coordinator(EngineId),
    OsPid = get_adapter_os_pid(CoordPid, EngineId),
    ct:pal("Killing MLX adapter OS process: ~B", [OsPid]),

    %% SIGKILL the adapter
    T0 = erlang:monotonic_time(millisecond),
    os:cmd("kill -9 " ++ integer_to_list(OsPid)),

    %% Wait for engine to leave ready (crash detected)
    ok = wait_status_not(EngineId, ready, 10000),
    ct:pal("Engine left ready state"),

    %% Wait for engine to recover to ready (model reload)
    ok = wait_engine_ready(EngineId, ?ENGINE_READY_TIMEOUT),
    T1 = erlang:monotonic_time(millisecond),
    ct:pal("Engine recovered to ready in ~Bms", [T1 - T0]),

    %% Verify the engine actually works post-recovery
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => ?MODEL,
        <<"messages">> => [#{<<"role">> => <<"user">>,
                             <<"content">> => <<"Say hello.">>}],
        <<"stream">> => false
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _Headers} = gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    Decoded = loom_json:decode(RespBody),
    [Choice] = maps:get(<<"choices">>, Decoded),
    Msg = maps:get(<<"message">>, Choice),
    Content = maps:get(<<"content">>, Msg),
    ?assert(byte_size(Content) > 0),
    ct:pal("Post-recovery response: ~s", [Content]),
    gun:close(ConnPid).
```

- [ ] **Step 3: Verify test passes**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case crash_recovery_test`
Expected: PASS — engine crashes, auto-recovers, and serves a successful request.

- [ ] **Step 4: Commit**

```bash
git add test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add crash recovery integration test with SIGKILL"
```

---

### Task 10: README and Full Suite Run

**Files:**
- Create: `test/integration/README.md`
- Modify: `test/integration/loom_mlx_integration_SUITE.erl` (if any fixes needed from full run)

- [ ] **Step 1: Create the README**

```markdown
# Integration Tests

End-to-end integration tests that run against real inference engines on actual hardware.
These tests are **not** part of the standard CI pipeline — they require specific hardware
and model downloads.

## MLX Integration Suite (Apple Silicon)

Tests the full Loom stack with a real MLX inference engine using TinyLlama-1.1B.

### Prerequisites

1. **Apple Silicon Mac** (M1/M2/M3/M4)
2. **Erlang/OTP 27+** and rebar3
3. **Python 3.11+**
   ```bash
   brew install python@3.11
   ```
4. **MLX dependencies**
   ```bash
   pip install mlx-lm>=0.20.0 huggingface-hub psutil
   ```
5. **Download test model** (~700MB, cached for subsequent runs)
   ```bash
   huggingface-cli download mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit
   ```

### Running

Run the full suite:

```bash
rebar3 ct --suite test/integration/loom_mlx_integration_SUITE
```

Run a specific test:

```bash
rebar3 ct --suite test/integration/loom_mlx_integration_SUITE --case health_endpoint_test
```

### Test Cases

| Test | What It Validates |
|------|------------------|
| `health_endpoint_test` | GET /health returns 200 with engine status `ready` |
| `memory_metrics_test` | GPU monitor reports sensible memory values matching machine RAM |
| `chat_completion_openai_test` | POST /v1/chat/completions returns non-empty completion |
| `chat_completion_anthropic_test` | POST /v1/messages returns non-empty completion in Anthropic format |
| `sse_streaming_openai_test` | SSE streaming delivers token chunks ending with [DONE] |
| `sse_streaming_anthropic_test` | SSE streaming follows Anthropic event sequence |
| `gpu_metrics_sanity_test` | GPU metrics have valid types and sensible values |
| `crash_recovery_test` | SIGKILL adapter → auto-restart → successful request |

### Notes

- First inference after model load is slow (~10-20s) due to Metal shader compilation
- The model is cached in `~/.cache/huggingface/hub/` after first download
- Tests use HTTP port 18080 (auto-increments to 18089 if busy)
- Total runtime: ~2-3 minutes
- If prerequisites are missing, the suite **skips** (not fails) with setup instructions
```

- [ ] **Step 2: Run the full suite end-to-end**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 ct --suite test/integration/loom_mlx_integration_SUITE`
Expected: All 8 tests PASS (or suite skips if prerequisites not met).

- [ ] **Step 3: Fix any issues found during full run**

If any test fails, diagnose and fix. Common issues:
- Timeout too short for model reload in crash recovery → increase `?ENGINE_READY_TIMEOUT`
- SSE chunk boundaries split across Gun messages → verify `collect_sse_data` handles partial chunks
- Port conflict → verify `find_free_port` works

- [ ] **Step 4: Commit**

```bash
git add test/integration/README.md test/integration/loom_mlx_integration_SUITE.erl
git commit -m "test(#15): add integration test README and finalize suite"
```

---

## Self-Review

**Spec coverage:**
- Health endpoint ✓ (Task 2)
- Memory metrics ✓ (Task 3)
- Chat completion OpenAI ✓ (Task 4)
- Chat completion Anthropic ✓ (Task 5)
- SSE streaming OpenAI ✓ (Task 6)
- SSE streaming Anthropic ✓ (Task 7)
- GPU metrics sanity ✓ (Task 8)
- Crash recovery SIGKILL ✓ (Task 9)
- Skip logic with instructions ✓ (Task 1)
- README with setup instructions ✓ (Task 10)
- All deliverables from spec covered

**Placeholder scan:** No TBD, TODO, "fill in", or "similar to" references. All code blocks are complete.

**Type consistency:** `?ENGINE_ID`, `?MODEL`, `?BASE_PORT`, `?ENGINE_READY_TIMEOUT`, `?REQUEST_TIMEOUT` used consistently across all tasks. Helper function signatures (`find_gpu_monitor/1`, `find_coordinator/1`, `get_adapter_os_pid/2`, `get_machine_ram_gb/0`, `wait_status_not/3`, `wait_engine_ready/2`) are consistent between definition and use sites.
