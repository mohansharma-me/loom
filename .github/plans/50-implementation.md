# CC-02: Structured Logging & Observability — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish logging standards with JSON formatting, propagate request IDs end-to-end, set process-level metadata, retrofit all log statements to structured format, and instrument modules with telemetry events.

**Architecture:** Add `telemetry` dependency, create `loom_log_formatter` for JSON output, configure logger handlers in sys.config, retrofit all 84 log statements to map-only format with consistent metadata, add `logger:set_process_metadata/1` to all long-lived processes, and instrument 8 modules with `telemetry:execute/3` calls.

**Tech Stack:** Erlang/OTP 27+ logger, telemetry library, Cowboy middleware

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `rebar.config` | Add telemetry dependency |
| Modify | `src/loom.app.src` | Add telemetry to applications |
| Create | `src/loom_log_formatter.erl` | JSON log formatter for production |
| Modify | `config/sys.config` | Dev logger handler config |
| Modify | `config/sys.config.src` | Prod logger handler config with JSON formatter |
| Modify | `src/loom_app.erl` | Retrofit log statements |
| Modify | `src/loom_sup.erl` | Retrofit log statements |
| Modify | `src/loom_engine_sup.erl` | Retrofit log statements |
| Modify | `src/loom_engine_coordinator.erl` | Process metadata, request_id propagation, telemetry, log retrofit |
| Modify | `src/loom_gpu_monitor.erl` | Process metadata, telemetry, log retrofit |
| Modify | `src/loom_http_middleware.erl` | Process metadata, telemetry, log retrofit |
| Modify | `src/loom_http_server.erl` | Log retrofit |
| Modify | `src/loom_handler_chat.erl` | Log retrofit |
| Modify | `src/loom_handler_messages.erl` | Log retrofit |
| Modify | `src/loom_port.erl` | Telemetry, log retrofit |
| Modify | `src/loom_os.erl` | Log retrofit |
| Modify | `src/loom_gpu_backend_nvidia.erl` | Log retrofit |
| Modify | `src/loom_cmd.erl` | Log retrofit |
| Modify | `src/loom_http.erl` | Log retrofit |

---

### Task 1: Add telemetry dependency

**Files:**
- Modify: `rebar.config:9-12` (deps)
- Modify: `src/loom.app.src:7-12` (applications)

- [ ] **Step 1: Add telemetry to deps in rebar.config**

In `rebar.config`, replace:

```erlang
{deps, [
    {cowboy, "2.14.2"},
    {prometheus, "6.1.2"}
]}.
```

with:

```erlang
{deps, [
    {cowboy, "2.14.2"},
    {prometheus, "6.1.2"},
    {telemetry, "1.3.0"}
]}.
```

- [ ] **Step 2: Add telemetry to applications in loom.app.src**

In `src/loom.app.src`, replace:

```erlang
    {applications, [
        kernel,
        stdlib,
        sasl,
        cowboy,
        prometheus
    ]},
```

with:

```erlang
    {applications, [
        kernel,
        stdlib,
        sasl,
        cowboy,
        prometheus,
        telemetry
    ]},
```

- [ ] **Step 3: Verify it compiles**

Run: `rebar3 compile`

Expected: telemetry downloaded and compiled. No errors.

- [ ] **Step 4: Commit**

```bash
git add rebar.config rebar.lock src/loom.app.src
git commit -m "feat(deps): add telemetry dependency for observability instrumentation (#50)"
```

---

### Task 2: Create loom_log_formatter module

**Files:**
- Create: `src/loom_log_formatter.erl`
- Create: `test/loom_log_formatter_tests.erl`

- [ ] **Step 1: Write the failing test**

```erlang
-module(loom_log_formatter_tests).
-include_lib("eunit/include/eunit.hrl").

%% Test: report (map) format produces valid JSON with required fields
format_report_map_test() ->
    Event = #{
        level => info,
        msg => {report, #{msg => engine_started, engine_id => <<"e1">>}},
        meta => #{time => 1711612800000000, pid => self()}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"info">>, maps:get(<<"level">>, Map)),
    ?assertEqual(<<"engine_started">>, maps:get(<<"msg">>, Map)),
    ?assertEqual(<<"e1">>, maps:get(<<"engine_id">>, Map)),
    ?assert(maps:is_key(<<"time">>, Map)).

%% Test: string format logs produce JSON with msg field
format_string_test() ->
    Event = #{
        level => warning,
        msg => {string, "something happened"},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"warning">>, maps:get(<<"level">>, Map)),
    ?assertEqual(<<"something happened">>, maps:get(<<"msg">>, Map)).

%% Test: format+args logs produce JSON
format_args_test() ->
    Event = #{
        level => error,
        msg => {Format, Args} = {"error: ~p", [timeout]},
        meta => #{time => 1711612800000000}
    },
    _ = Format, _ = Args,
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"error">>, maps:get(<<"level">>, Map)),
    ?assert(is_binary(maps:get(<<"msg">>, Map))).

%% Test: nested maps are flattened with underscore-joined keys
flatten_nested_test() ->
    Event = #{
        level => info,
        msg => {report, #{msg => test, error => #{reason => timeout, code => 500}}},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    Map = loom_json:decode(Bin),
    ?assertEqual(<<"timeout">>, maps:get(<<"error_reason">>, Map)),
    ?assertEqual(500, maps:get(<<"error_code">>, Map)).

%% Test: check_config always returns ok
check_config_test() ->
    ok = loom_log_formatter:check_config(#{}).

%% Test: output ends with newline
newline_terminated_test() ->
    Event = #{
        level => info,
        msg => {report, #{msg => test}},
        meta => #{time => 1711612800000000}
    },
    Result = loom_log_formatter:format(Event, #{}),
    Bin = iolist_to_binary(Result),
    ?assertEqual($\n, binary:last(Bin)).
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `rebar3 eunit --module=loom_log_formatter_tests`

Expected: FAIL — module loom_log_formatter not found.

- [ ] **Step 3: Write loom_log_formatter implementation**

```erlang
-module(loom_log_formatter).

%% Logger formatter callbacks
-export([format/2, check_config/1]).

%% @doc Format a log event as a single JSON line.
%% Merges process metadata with per-call metadata, flattens nested maps
%% one level using underscore-joined keys.
-spec format(logger:log_event(), logger:formatter_config()) -> unicode:chardata().
format(#{level := Level, msg := Msg, meta := Meta}, _Config) ->
    Time = format_time(maps:get(time, Meta, erlang:system_time(microsecond))),
    MsgFields = extract_msg(Msg),
    %% Merge metadata (process + per-call), excluding internal OTP keys
    FilteredMeta = maps:without([time, pid, gl, mfa, file, line, domain,
                                  report_cb, error_logger], Meta),
    Base = #{<<"time">> => Time, <<"level">> => atom_to_binary(Level)},
    Merged = maps:merge(Base, maps:merge(to_binary_keys(FilteredMeta),
                                          to_binary_keys(MsgFields))),
    Flattened = flatten_one_level(Merged),
    [loom_json:encode(Flattened), $\n].

%% @doc Validate formatter config. We accept any config.
-spec check_config(logger:formatter_config()) -> ok.
check_config(_Config) ->
    ok.

%%% Internal

-spec extract_msg(logger:log_event_msg_list()) -> map().
extract_msg({report, Report}) when is_map(Report) ->
    Report;
extract_msg({report, Report}) when is_list(Report) ->
    maps:from_list(Report);
extract_msg({string, String}) ->
    #{msg => iolist_to_binary([String])};
extract_msg({Format, Args}) when is_list(Format) orelse is_binary(Format) ->
    #{msg => iolist_to_binary(io_lib:format(Format, Args))};
extract_msg(_) ->
    #{}.

-spec format_time(integer()) -> binary().
format_time(TimeMicros) ->
    %% Convert microseconds since epoch to ISO 8601
    Seconds = TimeMicros div 1000000,
    Micros = TimeMicros rem 1000000,
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~6..0BZ",
                                    [Y, Mo, D, H, Mi, S, Micros])).

-spec to_binary_keys(map()) -> map().
to_binary_keys(Map) ->
    maps:fold(fun(K, V, Acc) ->
        BinKey = if
            is_atom(K) -> atom_to_binary(K);
            is_binary(K) -> K;
            true -> iolist_to_binary(io_lib:format("~p", [K]))
        end,
        maps:put(BinKey, safe_value(V), Acc)
    end, #{}, Map).

-spec safe_value(term()) -> term().
safe_value(V) when is_binary(V) -> V;
safe_value(V) when is_atom(V) -> atom_to_binary(V);
safe_value(V) when is_integer(V) -> V;
safe_value(V) when is_float(V) -> V;
safe_value(V) when is_list(V) ->
    case io_lib:printable_unicode_list(V) of
        true -> list_to_binary(V);
        false -> [safe_value(E) || E <- V]
    end;
safe_value(V) when is_map(V) -> to_binary_keys(V);
safe_value(V) when is_pid(V) -> list_to_binary(pid_to_list(V));
safe_value(V) when is_reference(V) -> list_to_binary(ref_to_list(V));
safe_value(V) when is_port(V) -> list_to_binary(port_to_list(V));
safe_value(V) -> iolist_to_binary(io_lib:format("~p", [V])).

-spec flatten_one_level(map()) -> map().
flatten_one_level(Map) ->
    maps:fold(fun(K, V, Acc) when is_map(V) ->
        %% Flatten: #{<<"error">> => #{<<"reason">> => timeout}}
        %% becomes #{<<"error_reason">> => timeout}
        maps:fold(fun(InnerK, InnerV, InnerAcc) ->
            FlatKey = <<K/binary, "_", (to_bin_key(InnerK))/binary>>,
            maps:put(FlatKey, safe_value(InnerV), InnerAcc)
        end, Acc, to_binary_keys(V));
    (K, V, Acc) ->
        maps:put(K, V, Acc)
    end, #{}, Map).

-spec to_bin_key(term()) -> binary().
to_bin_key(K) when is_binary(K) -> K;
to_bin_key(K) when is_atom(K) -> atom_to_binary(K);
to_bin_key(K) -> iolist_to_binary(io_lib:format("~p", [K])).
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `rebar3 eunit --module=loom_log_formatter_tests`

Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/loom_log_formatter.erl test/loom_log_formatter_tests.erl
git commit -m "feat: add loom_log_formatter for JSON log output (#50)"
```

---

### Task 3: Configure logger handlers in sys.config

**Files:**
- Modify: `config/sys.config`
- Modify: `config/sys.config.src`

- [ ] **Step 1: Update dev config (sys.config)**

Replace the full `config/sys.config` with:

```erlang
[
    {kernel, [
        {logger_level, info},
        {logger, [
            {handler, default, logger_std_h, #{
                config => #{type => standard_io},
                formatter => {logger_formatter, #{
                    template => [time, " [", level, "] ", msg, "\n"],
                    single_line => true
                }}
            }}
        ]}
    ]},
    {sasl, [
        {sasl_error_logger, false}
    ]}
].
```

- [ ] **Step 2: Update prod config (sys.config.src)**

Replace the full `config/sys.config.src` with:

```erlang
[
    {loom, []},
    {kernel, [
        {logger_level, info},
        {logger, [
            {handler, default, logger_std_h, #{
                config => #{type => standard_io},
                formatter => {loom_log_formatter, #{}}
            }}
        ]}
    ]},
    {sasl, [
        {sasl_error_logger, false}
    ]}
].
```

- [ ] **Step 3: Verify dev config compiles**

Run: `rebar3 release`

Expected: Release builds without errors.

- [ ] **Step 4: Commit**

```bash
git add config/sys.config config/sys.config.src
git commit -m "feat: configure logger handlers for dev (text) and prod (JSON) (#50)"
```

---

### Task 4: Add process metadata to long-lived processes

**Files:**
- Modify: `src/loom_engine_coordinator.erl`
- Modify: `src/loom_gpu_monitor.erl`
- Modify: `src/loom_http_middleware.erl`

- [ ] **Step 1: Add process metadata to loom_engine_coordinator init/1**

In `src/loom_engine_coordinator.erl`, find the `init/1` function. After the line that creates the meta table and before the line that starts the port, add:

```erlang
    logger:set_process_metadata(#{engine_id => EngineId}),
```

- [ ] **Step 2: Add process metadata to loom_gpu_monitor init/1**

In `src/loom_gpu_monitor.erl`, in the `init/1` function, after the `GpuId` and engine_id are resolved from `Opts`, add:

```erlang
    EngineId = maps:get(engine_id, Opts, undefined),
    logger:set_process_metadata(#{engine_id => EngineId, gpu_id => GpuId}),
```

- [ ] **Step 3: Add process metadata to loom_http_middleware execute/2**

In `src/loom_http_middleware.erl`, after `RequestId = loom_http_util:generate_request_id()`, add:

```erlang
    logger:set_process_metadata(#{request_id => RequestId}),
```

- [ ] **Step 4: Verify compilation and tests**

Run: `rebar3 compile && rebar3 eunit && rebar3 ct --verbose`

Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add src/loom_engine_coordinator.erl src/loom_gpu_monitor.erl src/loom_http_middleware.erl
git commit -m "feat: add logger process metadata to coordinator, gpu_monitor, middleware (#50)"
```

---

### Task 5: Retrofit log statements — application lifecycle modules

Retrofit `loom_app.erl`, `loom_sup.erl`, `loom_http_server.erl`, `loom_http.erl` to map-only format.

**Files:**
- Modify: `src/loom_app.erl`
- Modify: `src/loom_sup.erl`
- Modify: `src/loom_http_server.erl`
- Modify: `src/loom_http.erl`

- [ ] **Step 1: Retrofit loom_app.erl**

These are already map format — verify no changes needed. Current log statements:
- `?LOG_ERROR(#{msg => config_load_failed, reason => Reason})` ✓
- `?LOG_INFO(#{msg => loading_config})` ✓
- `?LOG_INFO(#{msg => config_already_loaded, source => pre_existing_ets})` ✓

No changes needed.

- [ ] **Step 2: Retrofit loom_sup.erl**

Current: `?LOG_ERROR(#{msg => engine_config_not_found, engine_name => Name})` ✓

No changes needed.

- [ ] **Step 3: Retrofit loom_http_server.erl**

Current statements are already map format:
- `?LOG_INFO(#{msg => http_server_started})` ✓
- `?LOG_ERROR(#{msg => http_server_start_failed, reason => Reason})` ✓
- `?LOG_WARNING(#{msg => unexpected_message, info => Info})` ✓
- `?LOG_INFO(#{msg => http_server_terminating, reason => Reason})` ✓

No changes needed.

- [ ] **Step 4: Retrofit loom_http.erl**

Current: `?LOG_INFO(#{msg => starting_http, port => Port, ip => Ip})` ✓

No changes needed.

- [ ] **Step 5: Commit (skip if no changes)**

Application lifecycle modules already use map-only format. No commit needed for this task.

---

### Task 6: Retrofit log statements — loom_os.erl and loom_cmd.erl

**Files:**
- Modify: `src/loom_os.erl`
- Modify: `src/loom_cmd.erl`

- [ ] **Step 1: Retrofit loom_os.erl**

Replace string-format log statements with map format:

```erlang
%% Line 29: Replace
?LOG_DEBUG("loom_os: force_kill called with undefined pid, skipping")
%% With
?LOG_DEBUG(#{msg => force_kill_skipped, reason => undefined_pid})

%% Line 32: Replace
?LOG_WARNING("loom_os: force-killing OS process ~b", [OsPid])
%% With
?LOG_WARNING(#{msg => force_killing_os_process, os_pid => OsPid})

%% Lines 46-47: Replace
?LOG_DEBUG("loom_os: force_kill output for OS pid ~b: ~s", [OsPid, Output])
%% With
?LOG_DEBUG(#{msg => force_kill_output, os_pid => OsPid, output => list_to_binary(Output)})

%% Line 51: Replace
?LOG_ERROR("loom_os: force_kill called with invalid pid: ~p", [BadPid])
%% With
?LOG_ERROR(#{msg => force_kill_invalid_pid, bad_pid => BadPid})
```

- [ ] **Step 2: Retrofit loom_cmd.erl**

Replace string-format log statements:

```erlang
%% Lines 55-56: Replace
?LOG_WARNING("loom_cmd: command timed out after ~bms: ~s", [Timeout, Cmd])
%% With
?LOG_WARNING(#{msg => command_timeout, timeout_ms => Timeout, command => list_to_binary(Cmd)})

%% Lines 82-83: Replace
?LOG_WARNING("loom_cmd: command timed out after ~bms: ~s", [OrigTimeout, Cmd])
%% With
?LOG_WARNING(#{msg => command_timeout, timeout_ms => OrigTimeout, command => list_to_binary(Cmd)})
```

- [ ] **Step 3: Verify compilation and tests**

Run: `rebar3 compile && rebar3 eunit && rebar3 ct --verbose`

Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add src/loom_os.erl src/loom_cmd.erl
git commit -m "refactor: retrofit loom_os and loom_cmd to structured map logging (#50)"
```

---

### Task 7: Retrofit log statements — loom_engine_coordinator.erl

This is the largest module. Read the full file, find ALL string-format log statements, and convert each to map format. The `engine_id` will come from process metadata (set in Task 4), so it doesn't need to be in every log call — but include it for log statements emitted before process metadata is set (i.e., during init before `set_process_metadata`).

**Files:**
- Modify: `src/loom_engine_coordinator.erl`

- [ ] **Step 1: Read the full file and identify all log statements**

Run: `grep -n 'LOG_' src/loom_engine_coordinator.erl`

- [ ] **Step 2: Convert each string-format log to map format**

For each `?LOG_*("format ~p", [Args], #{metadata})` pattern, convert to `?LOG_*( #{msg => descriptive_atom, key => value})`.

Example conversions:
```erlang
%% BEFORE:
?LOG_WARNING("Engine ~s port error during startup: ~p", [EngineId, Error], #{engine_id => EngineId})
%% AFTER:
?LOG_WARNING(#{msg => port_error_during_startup, error => Error})

%% BEFORE:
?LOG_INFO("Engine ~s coordinator starting", [EngineId])
%% AFTER:
?LOG_INFO(#{msg => coordinator_starting})
```

Note: `engine_id` comes from process metadata automatically after init.

- [ ] **Step 3: Verify compilation and tests**

Run: `rebar3 compile && rebar3 eunit && rebar3 ct --verbose`

Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add src/loom_engine_coordinator.erl
git commit -m "refactor: retrofit loom_engine_coordinator to structured map logging (#50)"
```

---

### Task 8: Retrofit log statements — remaining modules

**Files:**
- Modify: `src/loom_engine_sup.erl`
- Modify: `src/loom_gpu_monitor.erl`
- Modify: `src/loom_gpu_backend_nvidia.erl`
- Modify: `src/loom_http_middleware.erl`
- Modify: `src/loom_handler_chat.erl`
- Modify: `src/loom_handler_messages.erl`

- [ ] **Step 1: Identify all remaining string-format logs**

Run: `grep -rn 'LOG_.*"' src/ --include='*.erl' | grep -v '#{msg =>'`

This finds log statements using string format (not map format).

- [ ] **Step 2: Convert each to map format**

Follow the same pattern as Tasks 6-7. For each module:
- GPU monitor logs: `gpu_id` and `engine_id` come from process metadata
- HTTP middleware logs: `request_id` comes from process metadata
- Handler logs: `request_id` comes from process metadata

- [ ] **Step 3: Verify compilation and tests**

Run: `rebar3 compile && rebar3 eunit && rebar3 ct --verbose`

Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add src/loom_engine_sup.erl src/loom_gpu_monitor.erl src/loom_gpu_backend_nvidia.erl \
    src/loom_http_middleware.erl src/loom_handler_chat.erl src/loom_handler_messages.erl
git commit -m "refactor: retrofit remaining modules to structured map logging (#50)"
```

---

### Task 9: Add telemetry instrumentation — HTTP layer

**Files:**
- Modify: `src/loom_http_middleware.erl`

- [ ] **Step 1: Write test for HTTP telemetry events**

Create `test/loom_telemetry_tests.erl`:

```erlang
-module(loom_telemetry_tests).
-include_lib("eunit/include/eunit.hrl").

http_request_events_test() ->
    Self = self(),
    Ref = make_ref(),
    Handler = fun(Event, Measurements, Metadata, {Pid, Tag}) ->
        Pid ! {Tag, Event, Measurements, Metadata}
    end,
    telemetry:attach(<<"test-http-start">>, [loom, http, request_start],
                     Handler, {Self, Ref}),
    telemetry:attach(<<"test-http-stop">>, [loom, http, request_stop],
                     Handler, {Self, Ref}),
    try
        %% Simulate what middleware does
        loom_http_middleware:emit_request_start(<<"GET">>, <<"/health">>, <<"req-123">>),
        receive {Ref, [loom, http, request_start], Measurements, Meta} ->
            ?assert(maps:is_key(system_time, Measurements)),
            ?assertEqual(<<"GET">>, maps:get(method, Meta)),
            ?assertEqual(<<"/health">>, maps:get(path, Meta)),
            ?assertEqual(<<"req-123">>, maps:get(request_id, Meta))
        after 1000 -> ?assert(false)
        end,

        loom_http_middleware:emit_request_stop(1500, <<"GET">>, <<"/health">>,
                                               <<"req-123">>, 200),
        receive {Ref, [loom, http, request_stop], Measurements2, Meta2} ->
            ?assertEqual(1500, maps:get(duration, Measurements2)),
            ?assertEqual(200, maps:get(status, Meta2))
        after 1000 -> ?assert(false)
        end
    after
        telemetry:detach(<<"test-http-start">>),
        telemetry:detach(<<"test-http-stop">>)
    end.
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `rebar3 eunit --module=loom_telemetry_tests`

Expected: FAIL — emit_request_start/3 and emit_request_stop/5 not defined.

- [ ] **Step 3: Add telemetry emit functions to loom_http_middleware**

Add to `src/loom_http_middleware.erl` exports and implementations:

```erlang
-export([execute/2, emit_request_start/3, emit_request_stop/5]).

-spec emit_request_start(binary(), binary(), binary()) -> ok.
emit_request_start(Method, Path, RequestId) ->
    telemetry:execute(
        [loom, http, request_start],
        #{system_time => erlang:system_time(millisecond)},
        #{method => Method, path => Path, request_id => RequestId}
    ).

-spec emit_request_stop(non_neg_integer(), binary(), binary(), binary(),
                         non_neg_integer()) -> ok.
emit_request_stop(Duration, Method, Path, RequestId, Status) ->
    telemetry:execute(
        [loom, http, request_stop],
        #{duration => Duration},
        #{method => Method, path => Path, request_id => RequestId, status => Status}
    ).
```

In `execute/2`, add the telemetry call after the request_id is generated:

```erlang
    emit_request_start(Method, Path, RequestId),
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `rebar3 eunit --module=loom_telemetry_tests`

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/loom_http_middleware.erl test/loom_telemetry_tests.erl
git commit -m "feat: add telemetry events for HTTP request start/stop (#50)"
```

---

### Task 10: Add telemetry instrumentation — engine layer

**Files:**
- Modify: `src/loom_engine_coordinator.erl`

- [ ] **Step 1: Add telemetry tests for engine events**

Append to `test/loom_telemetry_tests.erl`:

```erlang
engine_state_change_event_test() ->
    Self = self(),
    Ref = make_ref(),
    Handler = fun(_Event, Measurements, Metadata, {Pid, Tag}) ->
        Pid ! {Tag, Measurements, Metadata}
    end,
    telemetry:attach(<<"test-engine-state">>, [loom, engine, state_change],
                     Handler, {Self, Ref}),
    try
        telemetry:execute(
            [loom, engine, state_change],
            #{system_time => erlang:system_time(millisecond)},
            #{engine_id => <<"e1">>, old_state => starting, new_state => ready}
        ),
        receive {Ref, _M, Meta} ->
            ?assertEqual(<<"e1">>, maps:get(engine_id, Meta)),
            ?assertEqual(starting, maps:get(old_state, Meta)),
            ?assertEqual(ready, maps:get(new_state, Meta))
        after 1000 -> ?assert(false)
        end
    after
        telemetry:detach(<<"test-engine-state">>)
    end.
```

- [ ] **Step 2: Add request_id parameter to generate and instrument state transitions**

First, update `generate/3` and `generate/4` to accept an optional `request_id` in the Params map (or as a separate arg) so the HTTP layer's request_id flows through. The handler already has `RequestId` — pass it as `#{request_id => RequestId}` merged into Params, or add a `generate/5` overload. The coordinator should store this in the ETS request tracking and include it in log metadata and telemetry.

Then, in each state transition function (starting → ready, ready → draining, etc.), add:

```erlang
telemetry:execute(
    [loom, engine, state_change],
    #{system_time => erlang:system_time(millisecond)},
    #{engine_id => EngineId, old_state => OldState, new_state => NewState}
),
```

Add `telemetry:execute` for `[loom, engine, generate_start]` in the `generate/3,4` function when a request is accepted, and `[loom, engine, generate_stop]` when done/error is received. Add `[loom, engine, token]` when a token message is forwarded.

- [ ] **Step 3: Verify compilation and tests**

Run: `rebar3 compile && rebar3 eunit && rebar3 ct --verbose`

Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add src/loom_engine_coordinator.erl test/loom_telemetry_tests.erl
git commit -m "feat: add telemetry events for engine lifecycle, generate, token (#50)"
```

---

### Task 11: Add telemetry instrumentation — GPU and Port layers

**Files:**
- Modify: `src/loom_gpu_monitor.erl`
- Modify: `src/loom_port.erl`

- [ ] **Step 1: Add GPU poll telemetry to loom_gpu_monitor**

After a successful poll in `handle_info({:poll, ...})`, add:

```erlang
telemetry:execute(
    [loom, gpu, poll],
    #{gpu_util => maps:get(gpu_util, Metrics),
      mem_used_gb => maps:get(mem_used_gb, Metrics),
      mem_total_gb => maps:get(mem_total_gb, Metrics),
      temperature_c => maps:get(temperature_c, Metrics)},
    #{engine_id => EngineId, gpu_id => GpuId}
),
```

Where EngineId and GpuId come from the process state.

- [ ] **Step 2: Add Port message telemetry to loom_port**

In the ready state handler for `{send, Msg}`, after encoding:

```erlang
telemetry:execute(
    [loom, port, message_out],
    #{byte_size => byte_size(Encoded)},
    #{engine_id => maps:get(engine_id, Opts, undefined)}
),
```

In the data handler for incoming port data, after decoding a complete line:

```erlang
telemetry:execute(
    [loom, port, message_in],
    #{byte_size => byte_size(Line)},
    #{engine_id => maps:get(engine_id, Opts, undefined)}
),
```

- [ ] **Step 3: Verify compilation and tests**

Run: `rebar3 compile && rebar3 eunit && rebar3 ct --verbose`

Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add src/loom_gpu_monitor.erl src/loom_port.erl
git commit -m "feat: add telemetry events for GPU poll and Port message I/O (#50)"
```

---

### Task 12: Final verification

- [ ] **Step 1: Run full test suite**

Run: `rebar3 eunit && rebar3 ct --verbose`

Expected: All tests pass.

- [ ] **Step 2: Run Dialyzer**

Run: `rebar3 dialyzer`

Expected: Zero warnings.

- [ ] **Step 3: Verify no string-format logs remain**

Run: `grep -rn 'LOG_.*"' src/ --include='*.erl' | grep -v '#{msg =>' | grep -v '%'`

Expected: No results (all log statements use map format).

- [ ] **Step 4: Verify telemetry events are instrumented**

Run: `grep -rn 'telemetry:execute' src/ --include='*.erl'`

Expected: Events in loom_http_middleware, loom_engine_coordinator, loom_gpu_monitor, loom_port.
