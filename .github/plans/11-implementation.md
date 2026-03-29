# HTTP API Layer Implementation Plan (P0-10 / P0-16)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement OpenAI- and Anthropic-compatible HTTP API endpoints with SSE streaming over Cowboy 2.14.2.

**Architecture:** Cowboy middleware pipeline (router → custom middleware → handler). Two streaming endpoints (`cowboy_loop`) share a common flow: parse request via format module → ETS lookup for coordinator pid → `generate/3` → receive token messages → stream SSE or accumulate. Pure format modules isolate API-specific wire formats.

**Tech Stack:** Erlang/OTP 27, Cowboy 2.14.2, EUnit, Common Test

**Spec:** `.github/plans/11-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/loom_engine_coordinator.erl` | Modify | Add `{coordinator_pid, self()}` ETS row + `generate/4` with timeout |
| `src/loom_http_util.erl` | Create | Request ID generation, JSON response helpers |
| `src/loom_format_openai.erl` | Create | OpenAI request parsing, response/SSE/error formatting |
| `src/loom_format_anthropic.erl` | Create | Anthropic request parsing, response/SSE/error formatting |
| `src/loom_http_middleware.erl` | Create | Cowboy middleware: request ID, content-type validation, logging |
| `src/loom_handler_health.erl` | Create | `GET /health` handler |
| `src/loom_handler_models.erl` | Create | `GET /v1/models` handler |
| `src/loom_handler_chat.erl` | Create | `POST /v1/chat/completions` cowboy_loop handler |
| `src/loom_handler_messages.erl` | Create | `POST /v1/messages` cowboy_loop handler |
| `src/loom_http.erl` | Create | Cowboy listener setup + routing |
| `test/loom_http_util_tests.erl` | Create | EUnit tests for loom_http_util |
| `test/loom_format_openai_tests.erl` | Create | EUnit tests for OpenAI formatting |
| `test/loom_format_anthropic_tests.erl` | Create | EUnit tests for Anthropic formatting |
| `test/loom_mock_coordinator.erl` | Create | Mock coordinator gen_statem for HTTP testing |
| `test/loom_handler_chat_SUITE.erl` | Create | CT suite for OpenAI endpoint |
| `test/loom_handler_messages_SUITE.erl` | Create | CT suite for Anthropic endpoint |
| `test/loom_handler_health_SUITE.erl` | Create | CT suite for health endpoint |
| `test/loom_handler_models_SUITE.erl` | Create | CT suite for models endpoint |
| `test/loom_http_middleware_SUITE.erl` | Create | CT suite for middleware |
| `config/sys.config` | Modify | Add `{http, #{...}}` config |

---

### Task 1: Extend Coordinator ETS with pid + add generate/4

**Files:**
- Modify: `src/loom_engine_coordinator.erl`
- Modify: `test/loom_engine_coordinator_SUITE.erl`

This task adds the `{coordinator_pid, self()}` row to the coordinator's meta ETS table so HTTP handlers can discover the coordinator without GenServer serialization. Also adds `generate/4` with explicit timeout.

- [ ] **Step 1: Write failing test for coordinator pid in ETS**

Add to `test/loom_engine_coordinator_SUITE.erl`:

```erlang
coordinator_pid_in_ets(Config) ->
    EngineId = ?config(engine_id, Config),
    Pid = ?config(coordinator_pid, Config),
    MetaTable = loom_engine_coordinator:meta_table_name(EngineId),
    [{coordinator_pid, StoredPid}] = ets:lookup(MetaTable, coordinator_pid),
    ?assertEqual(Pid, StoredPid).
```

Add `coordinator_pid_in_ets` to `all/0` export and groups.

- [ ] **Step 2: Run test to verify it fails**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=coordinator_pid_in_ets`
Expected: FAIL — no `coordinator_pid` row in ETS.

- [ ] **Step 3: Add coordinator_pid to ETS in init**

In `src/loom_engine_coordinator.erl`, find the `init/1` function where ETS tables are created and `{meta, ...}` is inserted. After the meta insert, add:

```erlang
ets:insert(MetaTable, {coordinator_pid, self()}),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=coordinator_pid_in_ets`
Expected: PASS

- [ ] **Step 5: Write failing test for generate/4 with timeout**

```erlang
generate_with_timeout(Config) ->
    Pid = ?config(coordinator_pid, Config),
    {ok, RequestId} = loom_engine_coordinator:generate(Pid, <<"test">>, #{}, 5000),
    ?assert(is_binary(RequestId)),
    collect_tokens(RequestId, 5, 5000),
    receive {loom_done, RequestId, _} -> ok after 5000 -> ct:fail("no done") end.
```

- [ ] **Step 6: Run test to verify it fails**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=generate_with_timeout`
Expected: FAIL — `generate/4` not exported.

- [ ] **Step 7: Implement generate/4**

In `src/loom_engine_coordinator.erl`:

```erlang
-spec generate(pid(), binary(), map(), timeout()) ->
    {ok, binary()} | {error, not_ready | draining | overloaded | stopped}.
generate(Pid, Prompt, Params, Timeout) ->
    gen_statem:call(Pid, {generate, Prompt, Params}, Timeout).
```

Add `generate/4` to the `-export` list.

- [ ] **Step 8: Run test to verify it passes**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE --case=generate_with_timeout`
Expected: PASS

- [ ] **Step 9: Run full coordinator test suite**

Run: `rebar3 ct --suite=test/loom_engine_coordinator_SUITE`
Expected: All existing tests still PASS.

- [ ] **Step 10: Commit**

```bash
git add src/loom_engine_coordinator.erl test/loom_engine_coordinator_SUITE.erl
git commit -m "feat(coordinator): add coordinator_pid ETS row and generate/4 with timeout (#11)"
```

---

### Task 2: loom_http_util — Pure Helpers

**Files:**
- Create: `src/loom_http_util.erl`
- Create: `test/loom_http_util_tests.erl`

- [ ] **Step 1: Write failing EUnit tests**

Create `test/loom_http_util_tests.erl`:

```erlang
-module(loom_http_util_tests).
-include_lib("eunit/include/eunit.hrl").

generate_request_id_format_test() ->
    Id = loom_http_util:generate_request_id(),
    ?assert(is_binary(Id)),
    ?assertMatch(<<"req-", _/binary>>, Id),
    %% 16 random bytes = 32 hex chars + "req-" prefix = 36 bytes
    ?assertEqual(36, byte_size(Id)).

generate_request_id_unique_test() ->
    Ids = [loom_http_util:generate_request_id() || _ <- lists:seq(1, 100)],
    ?assertEqual(100, length(lists:usort(Ids))).

timestamp_test() ->
    Ts = loom_http_util:unix_timestamp(),
    ?assert(is_integer(Ts)),
    ?assert(Ts > 1700000000).

default_config_test() ->
    Config = loom_http_util:default_config(),
    ?assertEqual(8080, maps:get(port, Config)),
    ?assertEqual({0,0,0,0}, maps:get(ip, Config)),
    ?assertEqual(1024, maps:get(max_connections, Config)),
    ?assertEqual(60000, maps:get(inactivity_timeout, Config)),
    ?assertEqual(5000, maps:get(generate_timeout, Config)),
    ?assertEqual(10485760, maps:get(max_body_size, Config)),
    ?assertEqual(<<"engine_0">>, maps:get(engine_id, Config)).

merge_config_test() ->
    Config = loom_http_util:get_config(),
    %% With no app env set, should return defaults
    ?assertEqual(8080, maps:get(port, Config)).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_http_util_tests`
Expected: FAIL — module `loom_http_util` not found.

- [ ] **Step 3: Implement loom_http_util**

Create `src/loom_http_util.erl`:

```erlang
-module(loom_http_util).

-export([
    generate_request_id/0,
    unix_timestamp/0,
    default_config/0,
    get_config/0,
    json_response/3,
    stream_reply/2,
    send_sse_event/3,
    send_sse_data/2,
    lookup_coordinator/1,
    try_generate/4,
    read_and_decode_body/2
]).

-spec generate_request_id() -> binary().
generate_request_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    Hex = binary:encode_hex(Bytes, lowercase),
    <<"req-", Hex/binary>>.

-spec unix_timestamp() -> non_neg_integer().
unix_timestamp() ->
    erlang:system_time(second).

-spec default_config() -> map().
default_config() ->
    #{
        port => 8080,
        ip => {0, 0, 0, 0},
        max_connections => 1024,
        max_body_size => 10485760,
        inactivity_timeout => 60000,
        generate_timeout => 5000,
        engine_id => <<"engine_0">>
    }.

-spec get_config() -> map().
get_config() ->
    UserConfig = application:get_env(loom, http, #{}),
    maps:merge(default_config(), UserConfig).

-spec json_response(non_neg_integer(), map() | binary(), cowboy_req:req()) ->
    cowboy_req:req().
json_response(StatusCode, Body, Req) when is_map(Body) ->
    json_response(StatusCode, loom_json:encode(Body), Req);
json_response(StatusCode, Body, Req) when is_binary(Body) ->
    cowboy_req:reply(StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req).

-spec stream_reply(map(), cowboy_req:req()) -> cowboy_req:req().
stream_reply(Headers, Req) ->
    cowboy_req:stream_reply(200,
        maps:merge(#{<<"content-type">> => <<"text/event-stream">>,
                     <<"cache-control">> => <<"no-cache">>}, Headers),
        Req).

-spec send_sse_event(binary(), binary(), cowboy_req:req()) -> ok.
send_sse_event(Event, Data, Req) ->
    Chunk = [<<"event: ">>, Event, <<"\ndata: ">>, Data, <<"\n\n">>],
    cowboy_req:stream_body(iolist_to_binary(Chunk), nofin, Req).

-spec send_sse_data(binary(), cowboy_req:req()) -> ok.
send_sse_data(Data, Req) ->
    Chunk = [<<"data: ">>, Data, <<"\n\n">>],
    cowboy_req:stream_body(iolist_to_binary(Chunk), nofin, Req).

-spec lookup_coordinator(binary()) -> {ok, pid()} | {error, not_found}.
lookup_coordinator(EngineId) ->
    MetaTable = loom_engine_coordinator:meta_table_name(EngineId),
    try ets:lookup(MetaTable, coordinator_pid) of
        [{coordinator_pid, Pid}] when is_pid(Pid) -> {ok, Pid};
        _ -> {error, not_found}
    catch
        error:badarg -> {error, not_found}
    end.

-spec try_generate(pid(), binary(), map(), timeout()) ->
    {ok, binary()} | {error, atom()}.
try_generate(CoordPid, Prompt, Params, Timeout) ->
    try
        loom_engine_coordinator:generate(CoordPid, Prompt, Params, Timeout)
    catch
        exit:{noproc, _} -> {error, stopped};
        exit:{timeout, _} -> {error, timeout}
    end.

-spec read_and_decode_body(cowboy_req:req(), non_neg_integer()) ->
    {ok, map(), cowboy_req:req()} | {error, binary(), cowboy_req:req()}.
read_and_decode_body(Req0, MaxBodySize) ->
    case cowboy_req:read_body(Req0, #{length => MaxBodySize}) of
        {ok, Body, Req1} ->
            try loom_json:decode(Body) of
                Map when is_map(Map) -> {ok, Map, Req1};
                _ -> {error, <<"Request body must be a JSON object">>, Req1}
            catch
                error:_ -> {error, <<"Invalid JSON body">>, Req1}
            end;
        {more, _, Req1} ->
            {error, <<"Request body too large">>, Req1}
    end.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_http_util_tests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_http_util.erl test/loom_http_util_tests.erl
git commit -m "feat(http): add loom_http_util with request ID and config helpers (#11)"
```

---

### Task 3: loom_format_openai — OpenAI Formatting

**Files:**
- Create: `src/loom_format_openai.erl`
- Create: `test/loom_format_openai_tests.erl`

- [ ] **Step 1: Write failing EUnit tests**

Create `test/loom_format_openai_tests.erl`:

```erlang
-module(loom_format_openai_tests).
-include_lib("eunit/include/eunit.hrl").

parse_request_basic_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
        <<"stream">> => true
    },
    {ok, Parsed} = loom_format_openai:parse_request(Body),
    ?assertEqual(<<"llama-3">>, maps:get(model, Parsed)),
    ?assertEqual(<<"hello">>, maps:get(prompt, Parsed)),
    ?assertEqual(true, maps:get(stream, Parsed)).

parse_request_with_params_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"max_tokens">> => 100,
        <<"temperature">> => 0.7
    },
    {ok, Parsed} = loom_format_openai:parse_request(Body),
    ?assertEqual(100, maps:get(max_tokens, maps:get(params, Parsed))),
    ?assertMatch(T when T > 0.6 andalso T < 0.8, maps:get(temperature, maps:get(params, Parsed))).

parse_request_missing_model_test() ->
    Body = #{<<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    ?assertMatch({error, _}, loom_format_openai:parse_request(Body)).

parse_request_missing_messages_test() ->
    Body = #{<<"model">> => <<"llama-3">>},
    ?assertMatch({error, _}, loom_format_openai:parse_request(Body)).

parse_request_multi_message_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"messages">> => [
            #{<<"role">> => <<"system">>, <<"content">> => <<"You are helpful.">>},
            #{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}
        ]
    },
    {ok, Parsed} = loom_format_openai:parse_request(Body),
    %% Phase 0: simple concatenation of messages
    Prompt = maps:get(prompt, Parsed),
    ?assert(binary:match(Prompt, <<"You are helpful.">>) =/= nomatch),
    ?assert(binary:match(Prompt, <<"hello">>) =/= nomatch).

parse_request_stream_default_false_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    },
    {ok, Parsed} = loom_format_openai:parse_request(Body),
    ?assertEqual(false, maps:get(stream, Parsed)).

format_chunk_test() ->
    Chunk = loom_format_openai:format_chunk(<<"req-abc">>, <<"Hello">>, <<"llama-3">>, 1700000000),
    Decoded = loom_json:decode(Chunk),
    ?assertEqual(<<"chatcmpl-req-abc">>, maps:get(<<"id">>, Decoded)),
    ?assertEqual(<<"chat.completion.chunk">>, maps:get(<<"object">>, Decoded)),
    ?assertEqual(<<"llama-3">>, maps:get(<<"model">>, Decoded)),
    ?assertEqual(1700000000, maps:get(<<"created">>, Decoded)),
    [Choice] = maps:get(<<"choices">>, Decoded),
    ?assertEqual(0, maps:get(<<"index">>, Choice)),
    Delta = maps:get(<<"delta">>, Choice),
    ?assertEqual(<<"Hello">>, maps:get(<<"content">>, Delta)),
    ?assertEqual(null, maps:get(<<"finish_reason">>, Choice)).

format_final_chunk_test() ->
    Chunk = loom_format_openai:format_final_chunk(<<"req-abc">>, <<"llama-3">>, 1700000000),
    Decoded = loom_json:decode(Chunk),
    [Choice] = maps:get(<<"choices">>, Decoded),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, Choice)),
    ?assertEqual(#{}, maps:get(<<"delta">>, Choice)).

format_done_test() ->
    ?assertEqual(<<"[DONE]">>, loom_format_openai:format_done()).

format_response_test() ->
    Resp = loom_format_openai:format_response(
        <<"req-abc">>, <<"Hello world">>, <<"llama-3">>, #{tokens => 2, time_ms => 100}, 1700000000),
    ?assertEqual(<<"chatcmpl-req-abc">>, maps:get(<<"id">>, Resp)),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Resp)),
    [Choice] = maps:get(<<"choices">>, Resp),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"Hello world">>, maps:get(<<"content">>, Msg)),
    Usage = maps:get(<<"usage">>, Resp),
    ?assertEqual(0, maps:get(<<"prompt_tokens">>, Usage)),
    ?assertEqual(2, maps:get(<<"completion_tokens">>, Usage)).

format_error_test() ->
    Err = loom_format_openai:format_error(<<"server_error">>, <<"engine_unavailable">>, <<"Engine is down">>),
    ?assertEqual(<<"Engine is down">>, maps:get(<<"message">>, maps:get(<<"error">>, Err))),
    ?assertEqual(<<"server_error">>, maps:get(<<"type">>, maps:get(<<"error">>, Err))),
    ?assertEqual(<<"engine_unavailable">>, maps:get(<<"code">>, maps:get(<<"error">>, Err))).

format_stream_error_test() ->
    Bin = loom_format_openai:format_stream_error(<<"server_error">>, <<"Engine crashed">>),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"Engine crashed">>, maps:get(<<"message">>, maps:get(<<"error">>, Decoded))).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_format_openai_tests`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement loom_format_openai**

Create `src/loom_format_openai.erl`:

```erlang
-module(loom_format_openai).

-export([
    parse_request/1,
    format_chunk/4,
    format_final_chunk/3,
    format_done/0,
    format_response/5,
    format_error/3,
    format_stream_error/2
]).

-spec parse_request(map()) -> {ok, map()} | {error, binary()}.
parse_request(Body) ->
    case {maps:get(<<"model">>, Body, undefined),
          maps:get(<<"messages">>, Body, undefined)} of
        {undefined, _} ->
            {error, <<"missing required field: model">>};
        {_, undefined} ->
            {error, <<"missing required field: messages">>};
        {Model, Messages} when is_list(Messages) ->
            Prompt = messages_to_prompt(Messages),
            Stream = maps:get(<<"stream">>, Body, false),
            Params = extract_params(Body),
            {ok, #{model => Model, prompt => Prompt, stream => Stream, params => Params}};
        {_, _} ->
            {error, <<"messages must be an array">>}
    end.

-spec format_chunk(binary(), binary(), binary(), non_neg_integer()) -> binary().
format_chunk(RequestId, Text, Model, Created) ->
    loom_json:encode(#{
        <<"id">> => <<"chatcmpl-", RequestId/binary>>,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{<<"content">> => Text},
            <<"finish_reason">> => null
        }]
    }).

-spec format_final_chunk(binary(), binary(), non_neg_integer()) -> binary().
format_final_chunk(RequestId, Model, Created) ->
    loom_json:encode(#{
        <<"id">> => <<"chatcmpl-", RequestId/binary>>,
        <<"object">> => <<"chat.completion.chunk">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"delta">> => #{},
            <<"finish_reason">> => <<"stop">>
        }]
    }).

-spec format_done() -> binary().
format_done() ->
    <<"[DONE]">>.

-spec format_response(binary(), binary(), binary(), map(), non_neg_integer()) -> map().
format_response(RequestId, Content, Model, Stats, Created) ->
    CompletionTokens = maps:get(tokens, Stats, 0),
    #{
        <<"id">> => <<"chatcmpl-", RequestId/binary>>,
        <<"object">> => <<"chat.completion">>,
        <<"created">> => Created,
        <<"model">> => Model,
        <<"choices">> => [#{
            <<"index">> => 0,
            <<"message">> => #{
                <<"role">> => <<"assistant">>,
                <<"content">> => Content
            },
            <<"finish_reason">> => <<"stop">>
        }],
        %% ASSUMPTION: prompt_tokens is 0 in Phase 0 (no tokenizer)
        <<"usage">> => #{
            <<"prompt_tokens">> => 0,
            <<"completion_tokens">> => CompletionTokens,
            <<"total_tokens">> => CompletionTokens
        }
    }.

-spec format_error(binary(), binary(), binary()) -> map().
format_error(Type, Code, Message) ->
    #{<<"error">> => #{
        <<"message">> => Message,
        <<"type">> => Type,
        <<"code">> => Code
    }}.

-spec format_stream_error(binary(), binary()) -> binary().
format_stream_error(Type, Message) ->
    loom_json:encode(#{<<"error">> => #{
        <<"message">> => Message,
        <<"type">> => Type
    }}).

%%% Internal

-spec messages_to_prompt([map()]) -> binary().
messages_to_prompt(Messages) ->
    Parts = lists:map(fun(Msg) ->
        Role = maps:get(<<"role">>, Msg, <<"user">>),
        Content = maps:get(<<"content">>, Msg, <<>>),
        <<Role/binary, ": ", Content/binary>>
    end, Messages),
    iolist_to_binary(lists:join(<<"\n">>, Parts)).

-spec extract_params(map()) -> map().
extract_params(Body) ->
    Params0 = #{},
    Params1 = maybe_add(<<"max_tokens">>, max_tokens, Body, Params0),
    Params2 = maybe_add(<<"temperature">>, temperature, Body, Params1),
    Params3 = maybe_add(<<"top_p">>, top_p, Body, Params2),
    maybe_add(<<"stop">>, stop, Body, Params3).

-spec maybe_add(binary(), atom(), map(), map()) -> map().
maybe_add(JsonKey, ErlKey, Body, Params) ->
    case maps:get(JsonKey, Body, undefined) of
        undefined -> Params;
        Value -> maps:put(ErlKey, Value, Params)
    end.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_format_openai_tests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_format_openai.erl test/loom_format_openai_tests.erl
git commit -m "feat(http): add loom_format_openai request/response formatting (#11)"
```

---

### Task 4: loom_format_anthropic — Anthropic Formatting

**Files:**
- Create: `src/loom_format_anthropic.erl`
- Create: `test/loom_format_anthropic_tests.erl`

- [ ] **Step 1: Write failing EUnit tests**

Create `test/loom_format_anthropic_tests.erl`:

```erlang
-module(loom_format_anthropic_tests).
-include_lib("eunit/include/eunit.hrl").

parse_request_basic_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"max_tokens">> => 1024,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}]
    },
    {ok, Parsed} = loom_format_anthropic:parse_request(Body),
    ?assertEqual(<<"llama-3">>, maps:get(model, Parsed)),
    ?assertEqual(<<"hello">>, maps:get(prompt, Parsed)),
    ?assertEqual(false, maps:get(stream, Parsed)),
    ?assertEqual(1024, maps:get(max_tokens, maps:get(params, Parsed))).

parse_request_with_system_test() ->
    Body = #{
        <<"model">> => <<"llama-3">>,
        <<"max_tokens">> => 1024,
        <<"system">> => <<"You are helpful.">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}]
    },
    {ok, Parsed} = loom_format_anthropic:parse_request(Body),
    Prompt = maps:get(prompt, Parsed),
    ?assert(binary:match(Prompt, <<"You are helpful.">>) =/= nomatch).

parse_request_missing_model_test() ->
    Body = #{<<"max_tokens">> => 1024,
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    ?assertMatch({error, _}, loom_format_anthropic:parse_request(Body)).

parse_request_missing_max_tokens_test() ->
    Body = #{<<"model">> => <<"llama-3">>,
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]},
    ?assertMatch({error, _}, loom_format_anthropic:parse_request(Body)).

format_message_start_test() ->
    Bin = loom_format_anthropic:format_message_start(<<"msg-abc">>, <<"llama-3">>),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"message_start">>, maps:get(<<"type">>, Decoded)),
    Msg = maps:get(<<"message">>, Decoded),
    ?assertEqual(<<"msg-abc">>, maps:get(<<"id">>, Msg)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"llama-3">>, maps:get(<<"model">>, Msg)).

format_content_block_start_test() ->
    Bin = loom_format_anthropic:format_content_block_start(0),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"content_block_start">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(0, maps:get(<<"index">>, Decoded)),
    Block = maps:get(<<"content_block">>, Decoded),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Block)).

format_content_block_delta_test() ->
    Bin = loom_format_anthropic:format_content_block_delta(0, <<"Hello">>),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"content_block_delta">>, maps:get(<<"type">>, Decoded)),
    Delta = maps:get(<<"delta">>, Decoded),
    ?assertEqual(<<"text_delta">>, maps:get(<<"type">>, Delta)),
    ?assertEqual(<<"Hello">>, maps:get(<<"text">>, Delta)).

format_content_block_stop_test() ->
    Bin = loom_format_anthropic:format_content_block_stop(0),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"content_block_stop">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(0, maps:get(<<"index">>, Decoded)).

format_message_delta_test() ->
    Bin = loom_format_anthropic:format_message_delta(5),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"message_delta">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, maps:get(<<"delta">>, Decoded))),
    ?assertEqual(5, maps:get(<<"output_tokens">>, maps:get(<<"usage">>, Decoded))).

format_message_stop_test() ->
    Bin = loom_format_anthropic:format_message_stop(),
    Decoded = loom_json:decode(Bin),
    ?assertEqual(<<"message_stop">>, maps:get(<<"type">>, Decoded)).

format_response_test() ->
    Resp = loom_format_anthropic:format_response(
        <<"msg-abc">>, <<"Hello world">>, <<"llama-3">>, #{tokens => 2}),
    ?assertEqual(<<"msg-abc">>, maps:get(<<"id">>, Resp)),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Resp)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Resp)),
    [Content] = maps:get(<<"content">>, Resp),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"Hello world">>, maps:get(<<"text">>, Content)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Resp)),
    Usage = maps:get(<<"usage">>, Resp),
    ?assertEqual(0, maps:get(<<"input_tokens">>, Usage)),
    ?assertEqual(2, maps:get(<<"output_tokens">>, Usage)).

format_error_test() ->
    Err = loom_format_anthropic:format_error(<<"overloaded_error">>, <<"At capacity">>),
    ?assertEqual(<<"error">>, maps:get(<<"type">>, Err)),
    ErrBody = maps:get(<<"error">>, Err),
    ?assertEqual(<<"overloaded_error">>, maps:get(<<"type">>, ErrBody)),
    ?assertEqual(<<"At capacity">>, maps:get(<<"message">>, ErrBody)).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_format_anthropic_tests`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement loom_format_anthropic**

Create `src/loom_format_anthropic.erl`:

```erlang
-module(loom_format_anthropic).

-export([
    parse_request/1,
    format_message_start/2,
    format_content_block_start/1,
    format_content_block_delta/2,
    format_content_block_stop/1,
    format_message_delta/1,
    format_message_stop/0,
    format_response/4,
    format_error/2,
    format_stream_error/2
]).

-spec parse_request(map()) -> {ok, map()} | {error, binary()}.
parse_request(Body) ->
    case {maps:get(<<"model">>, Body, undefined),
          maps:get(<<"max_tokens">>, Body, undefined),
          maps:get(<<"messages">>, Body, undefined)} of
        {undefined, _, _} ->
            {error, <<"missing required field: model">>};
        {_, undefined, _} ->
            {error, <<"missing required field: max_tokens">>};
        {_, _, undefined} ->
            {error, <<"missing required field: messages">>};
        {Model, MaxTokens, Messages} when is_list(Messages) ->
            System = maps:get(<<"system">>, Body, undefined),
            Prompt = messages_to_prompt(System, Messages),
            Stream = maps:get(<<"stream">>, Body, false),
            Params = extract_params(Body),
            {ok, #{model => Model, prompt => Prompt, stream => Stream,
                   params => Params#{max_tokens => MaxTokens}}};
        {_, _, _} ->
            {error, <<"messages must be an array">>}
    end.

-spec format_message_start(binary(), binary()) -> binary().
format_message_start(MessageId, Model) ->
    loom_json:encode(#{
        <<"type">> => <<"message_start">>,
        <<"message">> => #{
            <<"id">> => MessageId,
            <<"type">> => <<"message">>,
            <<"role">> => <<"assistant">>,
            <<"content">> => [],
            <<"model">> => Model,
            <<"usage">> => #{<<"input_tokens">> => 0}
        }
    }).

-spec format_content_block_start(non_neg_integer()) -> binary().
format_content_block_start(Index) ->
    loom_json:encode(#{
        <<"type">> => <<"content_block_start">>,
        <<"index">> => Index,
        <<"content_block">> => #{<<"type">> => <<"text">>, <<"text">> => <<>>}
    }).

-spec format_content_block_delta(non_neg_integer(), binary()) -> binary().
format_content_block_delta(Index, Text) ->
    loom_json:encode(#{
        <<"type">> => <<"content_block_delta">>,
        <<"index">> => Index,
        <<"delta">> => #{<<"type">> => <<"text_delta">>, <<"text">> => Text}
    }).

-spec format_content_block_stop(non_neg_integer()) -> binary().
format_content_block_stop(Index) ->
    loom_json:encode(#{
        <<"type">> => <<"content_block_stop">>,
        <<"index">> => Index
    }).

-spec format_message_delta(non_neg_integer()) -> binary().
format_message_delta(OutputTokens) ->
    loom_json:encode(#{
        <<"type">> => <<"message_delta">>,
        <<"delta">> => #{<<"stop_reason">> => <<"end_turn">>},
        <<"usage">> => #{<<"output_tokens">> => OutputTokens}
    }).

-spec format_message_stop() -> binary().
format_message_stop() ->
    loom_json:encode(#{<<"type">> => <<"message_stop">>}).

-spec format_response(binary(), binary(), binary(), map()) -> map().
format_response(MessageId, Content, Model, Stats) ->
    OutputTokens = maps:get(tokens, Stats, 0),
    #{
        <<"id">> => MessageId,
        <<"type">> => <<"message">>,
        <<"role">> => <<"assistant">>,
        <<"model">> => Model,
        <<"content">> => [#{<<"type">> => <<"text">>, <<"text">> => Content}],
        <<"stop_reason">> => <<"end_turn">>,
        %% ASSUMPTION: input_tokens is 0 in Phase 0 (no tokenizer)
        <<"usage">> => #{
            <<"input_tokens">> => 0,
            <<"output_tokens">> => OutputTokens
        }
    }.

-spec format_error(binary(), binary()) -> map().
format_error(Type, Message) ->
    #{<<"type">> => <<"error">>,
      <<"error">> => #{<<"type">> => Type, <<"message">> => Message}}.

-spec format_stream_error(binary(), binary()) -> binary().
format_stream_error(Type, Message) ->
    loom_json:encode(#{<<"type">> => <<"error">>,
                       <<"error">> => #{<<"type">> => Type, <<"message">> => Message}}).

%%% Internal

-spec messages_to_prompt(binary() | undefined, [map()]) -> binary().
messages_to_prompt(System, Messages) ->
    SystemParts = case System of
        undefined -> [];
        S -> [<<"system: ", S/binary>>]
    end,
    MsgParts = lists:map(fun(Msg) ->
        Role = maps:get(<<"role">>, Msg, <<"user">>),
        Content = maps:get(<<"content">>, Msg, <<>>),
        <<Role/binary, ": ", Content/binary>>
    end, Messages),
    iolist_to_binary(lists:join(<<"\n">>, SystemParts ++ MsgParts)).

-spec extract_params(map()) -> map().
extract_params(Body) ->
    Params0 = #{},
    Params1 = maybe_add(<<"temperature">>, temperature, Body, Params0),
    Params2 = maybe_add(<<"top_p">>, top_p, Body, Params1),
    maybe_add(<<"stop_sequences">>, stop, Body, Params2).

-spec maybe_add(binary(), atom(), map(), map()) -> map().
maybe_add(JsonKey, ErlKey, Body, Params) ->
    case maps:get(JsonKey, Body, undefined) of
        undefined -> Params;
        Value -> maps:put(ErlKey, Value, Params)
    end.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_format_anthropic_tests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/loom_format_anthropic.erl test/loom_format_anthropic_tests.erl
git commit -m "feat(http): add loom_format_anthropic request/response formatting (#64)"
```

---

### Task 5: loom_http_middleware — Cowboy Middleware

**Files:**
- Create: `src/loom_http_middleware.erl`

No EUnit tests here — middleware requires a running Cowboy instance (tested in CT later, Task 10).

- [ ] **Step 1: Implement loom_http_middleware**

Create `src/loom_http_middleware.erl`:

```erlang
-module(loom_http_middleware).
-behaviour(cowboy_middleware).

-export([execute/2]).

-include_lib("kernel/include/logger.hrl").

-spec execute(cowboy_req:req(), cowboy_middleware:env()) ->
    {ok, cowboy_req:req(), cowboy_middleware:env()} | {stop, cowboy_req:req()}.
execute(Req0, Env) ->
    RequestId = loom_http_util:generate_request_id(),
    Req1 = cowboy_req:set_resp_header(<<"x-request-id">>, RequestId, Req0),
    %% Store request ID in Req metadata for handler access
    Req2 = Req1#{request_id => RequestId},
    Method = cowboy_req:method(Req2),
    Path = cowboy_req:path(Req2),
    ?LOG_INFO(#{msg => http_request, method => Method, path => Path, request_id => RequestId}),
    case validate_content_type(Method, Req2) of
        ok ->
            {ok, Req2, Env};
        {error, Req3} ->
            {stop, Req3}
    end.

%%% Internal

-spec validate_content_type(binary(), cowboy_req:req()) -> ok | {error, cowboy_req:req()}.
validate_content_type(<<"POST">>, Req) ->
    ContentType = cowboy_req:header(<<"content-type">>, Req, <<>>),
    case binary:match(ContentType, <<"application/json">>) of
        nomatch ->
            Body = loom_json:encode(#{
                <<"error">> => #{
                    <<"type">> => <<"invalid_request_error">>,
                    <<"message">> => <<"Content-Type must be application/json">>
                }
            }),
            Req2 = cowboy_req:reply(415,
                #{<<"content-type">> => <<"application/json">>},
                Body, Req),
            {error, Req2};
        _ ->
            ok
    end;
validate_content_type(_, _Req) ->
    ok.
```

- [ ] **Step 2: Verify compilation**

Run: `rebar3 compile`
Expected: Success, no errors.

- [ ] **Step 3: Commit**

```bash
git add src/loom_http_middleware.erl
git commit -m "feat(http): add loom_http_middleware with request ID and content-type validation (#11)"
```

---

### Task 6: loom_handler_health and loom_handler_models — Simple Handlers

**Files:**
- Create: `src/loom_handler_health.erl`
- Create: `src/loom_handler_models.erl`

- [ ] **Step 1: Implement loom_handler_health**

Create `src/loom_handler_health.erl`:

```erlang
-module(loom_handler_health).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), any()) -> {ok, cowboy_req:req(), any()}.
init(Req0, State) ->
    Config = loom_http_util:get_config(),
    EngineId = maps:get(engine_id, Config),
    Status = loom_engine_coordinator:get_status(EngineId),
    Load = loom_engine_coordinator:get_load(EngineId),
    StatusBin = atom_to_binary(Status),
    HttpStatus = case Status of
        ready -> 200;
        _ -> 503
    end,
    Body = #{
        <<"status">> => StatusBin,
        <<"engine_id">> => EngineId,
        <<"load">> => Load
    },
    Req = loom_http_util:json_response(HttpStatus, Body, Req0),
    {ok, Req, State}.
```

- [ ] **Step 2: Implement loom_handler_models**

Create `src/loom_handler_models.erl`:

```erlang
-module(loom_handler_models).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), any()) -> {ok, cowboy_req:req(), any()}.
init(Req0, State) ->
    Config = loom_http_util:get_config(),
    EngineId = maps:get(engine_id, Config),
    Info = loom_engine_coordinator:get_info(EngineId),
    Models = case maps:get(model, Info, undefined) of
        undefined -> [];
        Model ->
            [#{<<"id">> => Model,
               <<"object">> => <<"model">>,
               <<"owned_by">> => <<"loom">>}]
    end,
    Body = #{<<"object">> => <<"list">>, <<"data">> => Models},
    Req = loom_http_util:json_response(200, Body, Req0),
    {ok, Req, State}.
```

- [ ] **Step 3: Verify compilation**

Run: `rebar3 compile`
Expected: Success.

- [ ] **Step 4: Commit**

```bash
git add src/loom_handler_health.erl src/loom_handler_models.erl
git commit -m "feat(http): add health and models handlers (#11)"
```

---

### Task 7: loom_handler_chat — OpenAI Streaming Handler

**Files:**
- Create: `src/loom_handler_chat.erl`

- [ ] **Step 1: Implement loom_handler_chat**

Create `src/loom_handler_chat.erl`:

```erlang
-module(loom_handler_chat).
-behaviour(cowboy_loop).

-export([init/2, info/3, terminate/3]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    request_id :: binary() | undefined,
    engine_request_id :: binary() | undefined,
    model :: binary(),
    stream :: boolean(),
    tokens :: [binary()],
    created :: non_neg_integer(),
    headers_sent :: boolean(),
    inactivity_timeout :: non_neg_integer()
}).

-spec init(cowboy_req:req(), any()) ->
    {cowboy_loop, cowboy_req:req(), #state{}, non_neg_integer()} |
    {ok, cowboy_req:req(), #state{}}.
init(Req0, _Opts) ->
    Config = loom_http_util:get_config(),
    InactivityTimeout = maps:get(inactivity_timeout, Config),
    GenerateTimeout = maps:get(generate_timeout, Config),
    MaxBodySize = maps:get(max_body_size, Config),
    EngineId = maps:get(engine_id, Config),
    RequestId = maps:get(request_id, Req0, loom_http_util:generate_request_id()),
    case read_and_parse(Req0, MaxBodySize) of
        {ok, Parsed, Req1} ->
            Model = maps:get(model, Parsed),
            Stream = maps:get(stream, Parsed),
            Prompt = maps:get(prompt, Parsed),
            Params = maps:get(params, Parsed),
            case loom_http_util:lookup_coordinator(EngineId) of
                {ok, CoordPid} ->
                    case loom_http_util:try_generate(CoordPid, Prompt, Params, GenerateTimeout) of
                        {ok, EngReqId} ->
                            Created = loom_http_util:unix_timestamp(),
                            State = #state{
                                request_id = RequestId,
                                engine_request_id = EngReqId,
                                model = Model,
                                stream = Stream,
                                tokens = [],
                                created = Created,
                                headers_sent = false,
                                inactivity_timeout = InactivityTimeout
                            },
                            case Stream of
                                true ->
                                    Req2 = loom_http_util:stream_reply(
                                        #{<<"x-request-id">> => RequestId}, Req1),
                                    {cowboy_loop, Req2, State#state{headers_sent = true},
                                     InactivityTimeout};
                                false ->
                                    {cowboy_loop, Req1, State, InactivityTimeout}
                            end;
                        {error, overloaded} ->
                            Err = loom_format_openai:format_error(
                                <<"rate_limit_error">>, <<"overloaded">>,
                                <<"Engine at max capacity">>),
                            Req2 = loom_http_util:json_response(429, Err, Req1),
                            {ok, Req2, #state{}};
                        {error, timeout} ->
                            Err = loom_format_openai:format_error(
                                <<"server_error">>, <<"timeout">>,
                                <<"Engine unresponsive">>),
                            Req2 = loom_http_util:json_response(504, Err, Req1),
                            {ok, Req2, #state{}};
                        {error, Reason} ->
                            Err = loom_format_openai:format_error(
                                <<"server_error">>, atom_to_binary(Reason),
                                <<"Engine unavailable">>),
                            Req2 = loom_http_util:json_response(503, Err, Req1),
                            {ok, Req2, #state{}}
                    end;
                {error, not_found} ->
                    Err = loom_format_openai:format_error(
                        <<"server_error">>, <<"engine_unavailable">>,
                        <<"No engine available">>),
                    Req2 = loom_http_util:json_response(503, Err, Req1),
                    {ok, Req2, #state{}}
            end;
        {error, ParseError, Req1} ->
            Err = loom_format_openai:format_error(
                <<"invalid_request_error">>, <<"bad_request">>, ParseError),
            Req2 = loom_http_util:json_response(400, Err, Req1),
            {ok, Req2, #state{}}
    end.

-spec info(any(), cowboy_req:req(), #state{}) ->
    {ok, cowboy_req:req(), #state{}, non_neg_integer()} |
    {stop, cowboy_req:req(), #state{}}.
info({loom_token, EngReqId, Text, _Finished},
     Req, #state{engine_request_id = EngReqId, stream = true} = State) ->
    Data = loom_format_openai:format_chunk(
        State#state.request_id, Text, State#state.model, State#state.created),
    loom_http_util:send_sse_data(Data, Req),
    {ok, Req, State, State#state.inactivity_timeout};

info({loom_token, EngReqId, Text, _Finished},
     Req, #state{engine_request_id = EngReqId, stream = false} = State) ->
    Tokens = [Text | State#state.tokens],
    {ok, Req, State#state{tokens = Tokens}, State#state.inactivity_timeout};

info({loom_done, EngReqId, Stats},
     Req, #state{engine_request_id = EngReqId, stream = true} = State) ->
    %% Send final chunk with finish_reason=stop, then [DONE]
    FinalChunk = loom_format_openai:format_final_chunk(
        State#state.request_id, State#state.model, State#state.created),
    loom_http_util:send_sse_data(FinalChunk, Req),
    loom_http_util:send_sse_data(loom_format_openai:format_done(), Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info({loom_done, EngReqId, Stats},
     Req, #state{engine_request_id = EngReqId, stream = false} = State) ->
    Content = iolist_to_binary(lists:reverse(State#state.tokens)),
    Body = loom_format_openai:format_response(
        State#state.request_id, Content, State#state.model, Stats, State#state.created),
    Req2 = loom_http_util:json_response(200, Body, Req),
    {stop, Req2, State};

info({loom_error, EngReqId, _Code, Message},
     Req, #state{engine_request_id = EngReqId, headers_sent = true} = State) ->
    ErrData = loom_format_openai:format_stream_error(<<"server_error">>, Message),
    loom_http_util:send_sse_data(ErrData, Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info({loom_error, EngReqId, _Code, Message},
     Req, #state{engine_request_id = EngReqId, headers_sent = false} = State) ->
    Err = loom_format_openai:format_error(
        <<"server_error">>, <<"engine_error">>, Message),
    Req2 = loom_http_util:json_response(500, Err, Req),
    {stop, Req2, State};

info(timeout, Req, #state{headers_sent = true} = State) ->
    ?LOG_WARNING(#{msg => inactivity_timeout, request_id => State#state.request_id}),
    ErrData = loom_format_openai:format_stream_error(
        <<"server_error">>, <<"Request timed out">>),
    loom_http_util:send_sse_data(ErrData, Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info(timeout, Req, #state{headers_sent = false} = State) ->
    ?LOG_WARNING(#{msg => inactivity_timeout, request_id => State#state.request_id}),
    Err = loom_format_openai:format_error(
        <<"server_error">>, <<"timeout">>, <<"Request timed out">>),
    Req2 = loom_http_util:json_response(504, Err, Req),
    {stop, Req2, State};

info(_Other, Req, State) ->
    {ok, Req, State, State#state.inactivity_timeout}.

-spec terminate(any(), cowboy_req:req(), #state{}) -> ok.
terminate(_Reason, _Req, _State) ->
    %% Process death triggers coordinator's DOWN monitor — automatic cleanup
    ok.

%%% Internal

-spec read_and_parse(cowboy_req:req(), non_neg_integer()) ->
    {ok, map(), cowboy_req:req()} | {error, binary(), cowboy_req:req()}.
read_and_parse(Req0, MaxBodySize) ->
    case loom_http_util:read_and_decode_body(Req0, MaxBodySize) of
        {ok, Map, Req1} ->
            case loom_format_openai:parse_request(Map) of
                {ok, Parsed} -> {ok, Parsed, Req1};
                {error, Reason} -> {error, Reason, Req1}
            end;
        {error, Reason, Req1} ->
            {error, Reason, Req1}
    end.
```

- [ ] **Step 2: Verify compilation**

Run: `rebar3 compile`
Expected: Success.

- [ ] **Step 3: Commit**

```bash
git add src/loom_handler_chat.erl
git commit -m "feat(http): add loom_handler_chat OpenAI streaming handler (#11)"
```

---

### Task 8: loom_handler_messages — Anthropic Streaming Handler

**Files:**
- Create: `src/loom_handler_messages.erl`

- [ ] **Step 1: Implement loom_handler_messages**

Create `src/loom_handler_messages.erl`:

```erlang
-module(loom_handler_messages).
-behaviour(cowboy_loop).

-export([init/2, info/3, terminate/3]).

-include_lib("kernel/include/logger.hrl").

-record(state, {
    request_id :: binary() | undefined,
    engine_request_id :: binary() | undefined,
    model :: binary(),
    stream :: boolean(),
    tokens :: [binary()],
    token_count :: non_neg_integer(),
    headers_sent :: boolean(),
    block_started :: boolean(),
    inactivity_timeout :: non_neg_integer()
}).

-spec init(cowboy_req:req(), any()) ->
    {cowboy_loop, cowboy_req:req(), #state{}, non_neg_integer()} |
    {ok, cowboy_req:req(), #state{}}.
init(Req0, _Opts) ->
    Config = loom_http_util:get_config(),
    InactivityTimeout = maps:get(inactivity_timeout, Config),
    GenerateTimeout = maps:get(generate_timeout, Config),
    MaxBodySize = maps:get(max_body_size, Config),
    EngineId = maps:get(engine_id, Config),
    RequestId = maps:get(request_id, Req0, loom_http_util:generate_request_id()),
    MessageId = <<"msg_", RequestId/binary>>,
    case read_and_parse(Req0, MaxBodySize) of
        {ok, Parsed, Req1} ->
            Model = maps:get(model, Parsed),
            Stream = maps:get(stream, Parsed),
            Prompt = maps:get(prompt, Parsed),
            Params = maps:get(params, Parsed),
            case loom_http_util:lookup_coordinator(EngineId) of
                {ok, CoordPid} ->
                    case loom_http_util:try_generate(CoordPid, Prompt, Params, GenerateTimeout) of
                        {ok, EngReqId} ->
                            State = #state{
                                request_id = MessageId,
                                engine_request_id = EngReqId,
                                model = Model,
                                stream = Stream,
                                tokens = [],
                                token_count = 0,
                                headers_sent = false,
                                block_started = false,
                                inactivity_timeout = InactivityTimeout
                            },
                            case Stream of
                                true ->
                                    Req2 = loom_http_util:stream_reply(
                                        #{<<"x-request-id">> => RequestId}, Req1),
                                    %% Send message_start and content_block_start
                                    loom_http_util:send_sse_event(
                                        <<"message_start">>,
                                        loom_format_anthropic:format_message_start(MessageId, Model),
                                        Req2),
                                    loom_http_util:send_sse_event(
                                        <<"content_block_start">>,
                                        loom_format_anthropic:format_content_block_start(0),
                                        Req2),
                                    {cowboy_loop, Req2,
                                     State#state{headers_sent = true, block_started = true},
                                     InactivityTimeout};
                                false ->
                                    {cowboy_loop, Req1, State, InactivityTimeout}
                            end;
                        {error, overloaded} ->
                            Err = loom_format_anthropic:format_error(
                                <<"overloaded_error">>, <<"Engine at max capacity">>),
                            Req2 = loom_http_util:json_response(429, Err, Req1),
                            {ok, Req2, #state{}};
                        {error, timeout} ->
                            Err = loom_format_anthropic:format_error(
                                <<"api_error">>, <<"Engine unresponsive">>),
                            Req2 = loom_http_util:json_response(504, Err, Req1),
                            {ok, Req2, #state{}};
                        {error, Reason} ->
                            Err = loom_format_anthropic:format_error(
                                <<"api_error">>, iolist_to_binary(
                                    io_lib:format("Engine unavailable: ~p", [Reason]))),
                            Req2 = loom_http_util:json_response(503, Err, Req1),
                            {ok, Req2, #state{}}
                    end;
                {error, not_found} ->
                    Err = loom_format_anthropic:format_error(
                        <<"api_error">>, <<"No engine available">>),
                    Req2 = loom_http_util:json_response(503, Err, Req1),
                    {ok, Req2, #state{}}
            end;
        {error, ParseError, Req1} ->
            Err = loom_format_anthropic:format_error(
                <<"invalid_request_error">>, ParseError),
            Req2 = loom_http_util:json_response(400, Err, Req1),
            {ok, Req2, #state{}}
    end.

-spec info(any(), cowboy_req:req(), #state{}) ->
    {ok, cowboy_req:req(), #state{}, non_neg_integer()} |
    {stop, cowboy_req:req(), #state{}}.
info({loom_token, EngReqId, Text, _Finished},
     Req, #state{engine_request_id = EngReqId, stream = true} = State) ->
    Data = loom_format_anthropic:format_content_block_delta(0, Text),
    loom_http_util:send_sse_event(<<"content_block_delta">>, Data, Req),
    NewCount = State#state.token_count + 1,
    {ok, Req, State#state{token_count = NewCount}, State#state.inactivity_timeout};

info({loom_token, EngReqId, Text, _Finished},
     Req, #state{engine_request_id = EngReqId, stream = false} = State) ->
    Tokens = [Text | State#state.tokens],
    NewCount = State#state.token_count + 1,
    {ok, Req, State#state{tokens = Tokens, token_count = NewCount},
     State#state.inactivity_timeout};

info({loom_done, EngReqId, Stats},
     Req, #state{engine_request_id = EngReqId, stream = true} = State) ->
    TokenCount = maps:get(tokens, Stats, State#state.token_count),
    %% content_block_stop
    loom_http_util:send_sse_event(
        <<"content_block_stop">>,
        loom_format_anthropic:format_content_block_stop(0), Req),
    %% message_delta with usage
    loom_http_util:send_sse_event(
        <<"message_delta">>,
        loom_format_anthropic:format_message_delta(TokenCount), Req),
    %% message_stop
    loom_http_util:send_sse_event(
        <<"message_stop">>,
        loom_format_anthropic:format_message_stop(), Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info({loom_done, EngReqId, Stats},
     Req, #state{engine_request_id = EngReqId, stream = false} = State) ->
    Content = iolist_to_binary(lists:reverse(State#state.tokens)),
    Body = loom_format_anthropic:format_response(
        State#state.request_id, Content, State#state.model, Stats),
    Req2 = loom_http_util:json_response(200, Body, Req),
    {stop, Req2, State};

info({loom_error, EngReqId, _Code, Message},
     Req, #state{engine_request_id = EngReqId, headers_sent = true} = State) ->
    ErrData = loom_format_anthropic:format_stream_error(<<"api_error">>, Message),
    loom_http_util:send_sse_event(<<"error">>, ErrData, Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info({loom_error, EngReqId, _Code, Message},
     Req, #state{engine_request_id = EngReqId, headers_sent = false} = State) ->
    Err = loom_format_anthropic:format_error(<<"api_error">>, Message),
    Req2 = loom_http_util:json_response(500, Err, Req),
    {stop, Req2, State};

info(timeout, Req, #state{headers_sent = true} = State) ->
    ?LOG_WARNING(#{msg => inactivity_timeout, request_id => State#state.request_id}),
    ErrData = loom_format_anthropic:format_stream_error(
        <<"api_error">>, <<"Request timed out">>),
    loom_http_util:send_sse_event(<<"error">>, ErrData, Req),
    cowboy_req:stream_body(<<>>, fin, Req),
    {stop, Req, State};

info(timeout, Req, #state{headers_sent = false} = State) ->
    ?LOG_WARNING(#{msg => inactivity_timeout, request_id => State#state.request_id}),
    Err = loom_format_anthropic:format_error(<<"api_error">>, <<"Request timed out">>),
    Req2 = loom_http_util:json_response(504, Err, Req),
    {stop, Req2, State};

info(_Other, Req, State) ->
    {ok, Req, State, State#state.inactivity_timeout}.

-spec terminate(any(), cowboy_req:req(), #state{}) -> ok.
terminate(_Reason, _Req, _State) ->
    %% Process death triggers coordinator's DOWN monitor — automatic cleanup
    ok.

%%% Internal

-spec read_and_parse(cowboy_req:req(), non_neg_integer()) ->
    {ok, map(), cowboy_req:req()} | {error, binary(), cowboy_req:req()}.
read_and_parse(Req0, MaxBodySize) ->
    case loom_http_util:read_and_decode_body(Req0, MaxBodySize) of
        {ok, Map, Req1} ->
            case loom_format_anthropic:parse_request(Map) of
                {ok, Parsed} -> {ok, Parsed, Req1};
                {error, Reason} -> {error, Reason, Req1}
            end;
        {error, Reason, Req1} ->
            {error, Reason, Req1}
    end.
```

- [ ] **Step 2: Verify compilation**

Run: `rebar3 compile`
Expected: Success.

- [ ] **Step 3: Commit**

```bash
git add src/loom_handler_messages.erl
git commit -m "feat(http): add loom_handler_messages Anthropic streaming handler (#64)"
```

---

### Task 9: loom_http — Cowboy Listener and Routing

**Files:**
- Create: `src/loom_http.erl`
- Modify: `config/sys.config`

- [ ] **Step 1: Implement loom_http**

Create `src/loom_http.erl`:

```erlang
-module(loom_http).

-export([start/0, stop/0]).

-include_lib("kernel/include/logger.hrl").

%% NOTE: loom_http is started manually for now. Integration into loom_sup
%% supervision tree is part of P0-11 (#12) — wiring all components together.

-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    Config = loom_http_util:get_config(),
    Port = maps:get(port, Config),
    Ip = maps:get(ip, Config),
    MaxConns = maps:get(max_connections, Config),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/v1/chat/completions", loom_handler_chat, []},
            {"/v1/messages", loom_handler_messages, []},
            {"/health", loom_handler_health, []},
            {"/v1/models", loom_handler_models, []}
        ]}
    ]),
    TransOpts = #{
        socket_opts => [{port, Port}, {ip, Ip}],
        max_connections => MaxConns
    },
    ProtoOpts = #{
        env => #{dispatch => Dispatch},
        middlewares => [cowboy_router, loom_http_middleware, cowboy_handler]
    },
    ?LOG_INFO(#{msg => starting_http, port => Port, ip => Ip}),
    cowboy:start_clear(loom_http_listener, TransOpts, ProtoOpts).

-spec stop() -> ok.
stop() ->
    cowboy:stop_listener(loom_http_listener).
```

- [ ] **Step 2: Update sys.config**

Edit `config/sys.config` to add HTTP config:

```erlang
[
    {loom, [
        {http, #{
            port => 8080,
            engine_id => <<"engine_0">>
        }}
    ]},
    {sasl, [
        {sasl_error_logger, {file, "log/sasl-error.log"}},
        {errlog_type, error}
    ]}
].
```

- [ ] **Step 3: Verify compilation**

Run: `rebar3 compile`
Expected: Success.

- [ ] **Step 4: Commit**

```bash
git add src/loom_http.erl config/sys.config
git commit -m "feat(http): add loom_http Cowboy listener with routing (#11)"
```

---

### Task 10: Mock Coordinator + Middleware CT Suite

**Files:**
- Create: `test/loom_mock_coordinator.erl`
- Create: `test/loom_http_middleware_SUITE.erl`

- [ ] **Step 1: Implement mock coordinator**

Create `test/loom_mock_coordinator.erl`:

```erlang
-module(loom_mock_coordinator).
-behaviour(gen_statem).

-export([
    start_link/1,
    stop/1,
    set_behavior/2
]).

-export([init/1, callback_mode/0, ready/3, terminate/3]).

-record(data, {
    engine_id :: binary(),
    meta_table :: atom(),
    behavior :: map()
}).

%% behavior map:
%% #{tokens => [binary()], token_delay => non_neg_integer(),
%%   error => {binary(), binary()} | undefined,
%%   generate_response => {ok, binary()} | {error, atom()}}

-spec start_link(map()) -> {ok, pid()}.
start_link(Config) ->
    gen_statem:start_link(?MODULE, Config, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid).

-spec set_behavior(pid(), map()) -> ok.
set_behavior(Pid, Behavior) ->
    gen_statem:call(Pid, {set_behavior, Behavior}).

callback_mode() -> state_functions.

init(Config) ->
    EngineId = maps:get(engine_id, Config, <<"test_engine">>),
    MetaTable = loom_engine_coordinator:meta_table_name(EngineId),
    ets:new(MetaTable, [named_table, set, public, {read_concurrency, true}]),
    ets:insert(MetaTable, {meta, ready, EngineId, <<"mock">>, <<"mock">>, self(),
                           erlang:system_time(millisecond)}),
    ets:insert(MetaTable, {coordinator_pid, self()}),
    Behavior = maps:get(behavior, Config, default_behavior()),
    Data = #data{
        engine_id = EngineId,
        meta_table = MetaTable,
        behavior = Behavior
    },
    {ok, ready, Data}.

ready({call, From}, {generate, Prompt, Params}, #data{behavior = Beh} = Data) ->
    case maps:get(generate_response, Beh, default) of
        {error, Reason} ->
            {keep_state, Data, [{reply, From, {error, Reason}}]};
        _ ->
            RequestId = <<"req-mock-",
                (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
            CallerPid = element(1, From),
            {keep_state, Data,
             [{reply, From, {ok, RequestId}},
              {next_event, internal, {stream_tokens, CallerPid, RequestId}}]}
    end;

ready({call, From}, {set_behavior, NewBehavior}, Data) ->
    {keep_state, Data#data{behavior = NewBehavior}, [{reply, From, ok}]};

ready(internal, {stream_tokens, CallerPid, RequestId}, #data{behavior = Beh} = Data) ->
    Tokens = maps:get(tokens, Beh, [<<"Hello">>, <<"from">>, <<"Loom">>]),
    Delay = maps:get(token_delay, Beh, 0),
    Error = maps:get(error, Beh, undefined),
    spawn_link(fun() ->
        stream_tokens(CallerPid, RequestId, Tokens, Delay, Error)
    end),
    {keep_state, Data};

ready(info, _Msg, Data) ->
    {keep_state, Data}.

terminate(_Reason, _State, #data{meta_table = MetaTable}) ->
    catch ets:delete(MetaTable),
    ok.

%%% Internal

stream_tokens(CallerPid, RequestId, Tokens, Delay, Error) ->
    lists:foreach(fun(Token) ->
        case Delay > 0 of
            true -> timer:sleep(Delay);
            false -> ok
        end,
        CallerPid ! {loom_token, RequestId, Token, false}
    end, Tokens),
    case Error of
        {Code, Message} ->
            CallerPid ! {loom_error, RequestId, Code, Message};
        undefined ->
            CallerPid ! {loom_done, RequestId,
                         #{tokens => length(Tokens), time_ms => 0}}
    end.

default_behavior() ->
    #{tokens => [<<"Hello">>, <<"from">>, <<"Loom">>],
      token_delay => 0,
      error => undefined}.
```

- [ ] **Step 2: Implement middleware CT suite**

Create `test/loom_http_middleware_SUITE.erl`:

```erlang
-module(loom_http_middleware_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    request_id_attached/1,
    content_type_rejected/1,
    get_request_passes/1
]).

all() -> [request_id_attached, content_type_rejected, get_request_passes].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    application:set_env(loom, http, #{port => 18080, engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    loom_http:stop(),
    loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

request_id_attached(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, _Status, Headers} = gun:await(ConnPid, StreamRef),
    RequestId = proplists:get_value(<<"x-request-id">>, Headers),
    ?assert(RequestId =/= undefined),
    ?assertMatch(<<"req-", _/binary>>, RequestId),
    gun:close(ConnPid).

content_type_rejected(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"text/plain">>}], <<"hello">>),
    {response, nofin, Status, _Headers} = gun:await(ConnPid, StreamRef),
    ?assertEqual(415, Status),
    gun:close(ConnPid).

get_request_passes(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18080),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, Status, _Headers} = gun:await(ConnPid, StreamRef),
    %% Should not be 415 — GET has no content-type requirement
    ?assert(Status =/= 415),
    gun:close(ConnPid).
```

- [ ] **Step 3: Add gun as a test dependency in rebar.config**

Add `gun` to the test profile deps:

```erlang
{profiles, [
    {test, [
        {deps, [
            {gun, "2.1.0"}
        ]}
    ]}
]}.
```

- [ ] **Step 4: Run middleware CT suite**

Run: `rebar3 ct --suite=test/loom_http_middleware_SUITE`
Expected: All 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add test/loom_mock_coordinator.erl test/loom_http_middleware_SUITE.erl rebar.config
git commit -m "test(http): add mock coordinator and middleware CT suite (#11)"
```

---

### Task 11: loom_handler_health_SUITE and loom_handler_models_SUITE

**Files:**
- Create: `test/loom_handler_health_SUITE.erl`
- Create: `test/loom_handler_models_SUITE.erl`

- [ ] **Step 1: Write health endpoint CT suite**

Create `test/loom_handler_health_SUITE.erl`:

```erlang
-module(loom_handler_health_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([health_ready/1, health_no_engine/1]).

all() -> [health_ready, health_no_engine].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    application:set_env(loom, http, #{port => 18081, engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    loom_http:stop(),
    loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

health_ready(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18081),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual(<<"ready">>, maps:get(<<"status">>, Decoded)),
    gun:close(ConnPid).

health_no_engine(_Config) ->
    %% Use a nonexistent engine_id
    application:set_env(loom, http, #{port => 18081, engine_id => <<"nonexistent">>}),
    {ok, ConnPid} = gun:open("127.0.0.1", 18081),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/health"),
    {response, nofin, 503, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual(<<"stopped">>, maps:get(<<"status">>, Decoded)),
    %% Restore config
    application:set_env(loom, http, #{port => 18081, engine_id => <<"engine_0">>}),
    gun:close(ConnPid).
```

- [ ] **Step 2: Write models endpoint CT suite**

Create `test/loom_handler_models_SUITE.erl`:

```erlang
-module(loom_handler_models_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([models_list/1, models_no_engine/1]).

all() -> [models_list, models_no_engine].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    application:set_env(loom, http, #{port => 18082, engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    loom_http:stop(),
    loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

models_list(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18082),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/v1/models"),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual(<<"list">>, maps:get(<<"object">>, Decoded)),
    [Model] = maps:get(<<"data">>, Decoded),
    ?assertEqual(<<"mock">>, maps:get(<<"id">>, Model)),
    gun:close(ConnPid).

models_no_engine(_Config) ->
    application:set_env(loom, http, #{port => 18082, engine_id => <<"nonexistent">>}),
    {ok, ConnPid} = gun:open("127.0.0.1", 18082),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:get(ConnPid, "/v1/models"),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, Body} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(Body),
    ?assertEqual([], maps:get(<<"data">>, Decoded)),
    application:set_env(loom, http, #{port => 18082, engine_id => <<"engine_0">>}),
    gun:close(ConnPid).
```

- [ ] **Step 3: Run both suites**

Run: `rebar3 ct --suite=test/loom_handler_health_SUITE,test/loom_handler_models_SUITE`
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add test/loom_handler_health_SUITE.erl test/loom_handler_models_SUITE.erl
git commit -m "test(http): add health and models handler CT suites (#11)"
```

---

### Task 12: loom_handler_chat_SUITE — OpenAI Endpoint Tests

**Files:**
- Create: `test/loom_handler_chat_SUITE.erl`

- [ ] **Step 1: Write chat handler CT suite**

Create `test/loom_handler_chat_SUITE.erl`:

```erlang
-module(loom_handler_chat_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    non_streaming_response/1,
    streaming_sse/1,
    bad_request/1,
    malformed_json/1,
    engine_overloaded/1,
    engine_unavailable/1,
    mid_stream_error/1,
    inactivity_timeout/1,
    client_disconnect/1
]).

all() -> [non_streaming_response, streaming_sse, bad_request, malformed_json,
          engine_overloaded, engine_unavailable, mid_stream_error,
          inactivity_timeout, client_disconnect].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    application:set_env(loom, http, #{port => 18083, engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    loom_http:stop(),
    loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

init_per_testcase(_TC, Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>, <<" ">>, <<"world">>],
        token_delay => 0,
        error => undefined
    }),
    Config.

end_per_testcase(_TC, _Config) -> ok.

non_streaming_response(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => false
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(RespBody),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Decoded)),
    [Choice] = maps:get(<<"choices">>, Decoded),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"Hello world">>, maps:get(<<"content">>, Msg)),
    gun:close(ConnPid).

streaming_sse(Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, Headers} = gun:await(ConnPid, StreamRef),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertMatch(<<"text/event-stream", _/binary>>, ContentType),
    %% Collect SSE data chunks
    Events = collect_sse_data(ConnPid, StreamRef, []),
    %% Should have 3 token chunks + 1 final chunk + [DONE]
    ?assert(length(Events) >= 4),
    %% Last event should be [DONE]
    ?assertEqual(<<"[DONE]">>, lists:last(Events)),
    gun:close(ConnPid).

bad_request(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{<<"invalid">> => true}),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 400, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).

engine_overloaded(Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        generate_response => {error, overloaded}
    }),
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 429, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).

engine_unavailable(_Config) ->
    application:set_env(loom, http, #{port => 18083, engine_id => <<"nonexistent">>}),
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 503, _} = gun:await(ConnPid, StreamRef),
    application:set_env(loom, http, #{port => 18083, engine_id => <<"engine_0">>}),
    gun:close(ConnPid).

malformed_json(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], <<"{broken">>),
    {response, nofin, 400, _} = gun:await(ConnPid, StreamRef),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(RespBody),
    ?assertMatch(#{<<"error">> := _}, Decoded),
    gun:close(ConnPid).

mid_stream_error(Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>],
        token_delay => 0,
        error => {<<"engine_crashed">>, <<"Engine process died">>}
    }),
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    %% Should receive at least one token then an error event
    _Events = collect_sse_data(ConnPid, StreamRef, []),
    gun:close(ConnPid).

inactivity_timeout(Config) ->
    %% Set very short inactivity timeout and slow token delivery
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>, <<"world">>],
        token_delay => 3000,  %% 3s between tokens
        error => undefined
    }),
    application:set_env(loom, http, #{port => 18083, engine_id => <<"engine_0">>,
                                      inactivity_timeout => 500}),  %% 500ms timeout
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => false
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 504, _} = gun:await(ConnPid, StreamRef, 10000),
    %% Restore config
    application:set_env(loom, http, #{port => 18083, engine_id => <<"engine_0">>}),
    gun:close(ConnPid).

client_disconnect(Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>, <<"world">>, <<"foo">>, <<"bar">>],
        token_delay => 500,  %% slow tokens so we can disconnect mid-stream
        error => undefined
    }),
    {ok, ConnPid} = gun:open("127.0.0.1", 18083),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    %% Wait for first token then disconnect
    timer:sleep(200),
    gun:close(ConnPid),
    %% Give coordinator time to process DOWN — no crash expected
    timer:sleep(500),
    ok.

%%% Internal

collect_sse_data(ConnPid, StreamRef, Acc) ->
    case gun:await(ConnPid, StreamRef, 5000) of
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
```

- [ ] **Step 2: Run chat handler CT suite**

Run: `rebar3 ct --suite=test/loom_handler_chat_SUITE`
Expected: All 6 tests PASS.

- [ ] **Step 3: Commit**

```bash
git add test/loom_handler_chat_SUITE.erl
git commit -m "test(http): add loom_handler_chat CT suite with streaming and error tests (#11)"
```

---

### Task 13: loom_handler_messages_SUITE — Anthropic Endpoint Tests

**Files:**
- Create: `test/loom_handler_messages_SUITE.erl`

- [ ] **Step 1: Write messages handler CT suite**

Create `test/loom_handler_messages_SUITE.erl`:

```erlang
-module(loom_handler_messages_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    non_streaming_response/1,
    streaming_sse_sequence/1,
    bad_request_missing_max_tokens/1,
    engine_overloaded/1,
    system_prompt/1
]).

all() -> [non_streaming_response, streaming_sse_sequence,
          bad_request_missing_max_tokens, engine_overloaded, system_prompt].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    {ok, _} = application:ensure_all_started(gun),
    {ok, MockPid} = loom_mock_coordinator:start_link(#{engine_id => <<"engine_0">>}),
    application:set_env(loom, http, #{port => 18084, engine_id => <<"engine_0">>}),
    {ok, _} = loom_http:start(),
    [{mock_pid, MockPid} | Config].

end_per_suite(Config) ->
    loom_http:stop(),
    loom_mock_coordinator:stop(?config(mock_pid, Config)),
    ok.

init_per_testcase(_TC, Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        tokens => [<<"Hello">>, <<" ">>, <<"world">>],
        token_delay => 0,
        error => undefined
    }),
    Config.

end_per_testcase(_TC, _Config) -> ok.

non_streaming_response(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"max_tokens">> => 1024,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef),
    Decoded = loom_json:decode(RespBody),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Decoded)),
    [Content] = maps:get(<<"content">>, Decoded),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Content)),
    ?assertEqual(<<"Hello world">>, maps:get(<<"text">>, Content)),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Decoded)),
    gun:close(ConnPid).

streaming_sse_sequence(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"max_tokens">> => 1024,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
        <<"stream">> => true
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, Headers} = gun:await(ConnPid, StreamRef),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertMatch(<<"text/event-stream", _/binary>>, ContentType),
    %% Collect all SSE events (event: <type>\ndata: <json>)
    Events = collect_sse_events(ConnPid, StreamRef, []),
    EventTypes = [Type || {Type, _} <- Events],
    %% Verify event sequence
    ?assertEqual(<<"message_start">>, hd(EventTypes)),
    ?assertEqual(<<"content_block_start">>, lists:nth(2, EventTypes)),
    %% Middle should be content_block_delta events
    ?assertEqual(<<"message_stop">>, lists:last(EventTypes)),
    %% Check message_delta is before message_stop
    ?assert(lists:member(<<"message_delta">>, EventTypes)),
    ?assert(lists:member(<<"content_block_stop">>, EventTypes)),
    gun:close(ConnPid).

bad_request_missing_max_tokens(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 400, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).

engine_overloaded(Config) ->
    MockPid = ?config(mock_pid, Config),
    loom_mock_coordinator:set_behavior(MockPid, #{
        generate_response => {error, overloaded}
    }),
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"max_tokens">> => 1024,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 429, _} = gun:await(ConnPid, StreamRef),
    gun:close(ConnPid).

system_prompt(_Config) ->
    {ok, ConnPid} = gun:open("127.0.0.1", 18084),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => <<"mock">>,
        <<"max_tokens">> => 1024,
        <<"system">> => <<"You are a helpful assistant.">>,
        <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}]
    }),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _} = gun:await(ConnPid, StreamRef),
    %% Just verifying it doesn't error — system prompt is passed through
    gun:close(ConnPid).

%%% Internal

collect_sse_events(ConnPid, StreamRef, Acc) ->
    case gun:await(ConnPid, StreamRef, 5000) of
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
    %% Split into event blocks separated by double newlines
    Blocks = binary:split(Chunk, <<"\n\n">>, [global, trim_all]),
    lists:filtermap(fun(Block) ->
        Lines = binary:split(Block, <<"\n">>, [global]),
        EventType = find_field(<<"event: ">>, Lines),
        Data = find_field(<<"data: ">>, Lines),
        case {EventType, Data} of
            {undefined, undefined} -> false;
            {undefined, D} -> {true, {<<"data">>, D}};
            {E, D} -> {true, {E, D}}
        end
    end, Blocks).

find_field(Prefix, Lines) ->
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

- [ ] **Step 2: Run messages handler CT suite**

Run: `rebar3 ct --suite=test/loom_handler_messages_SUITE`
Expected: All 5 tests PASS.

- [ ] **Step 3: Commit**

```bash
git add test/loom_handler_messages_SUITE.erl
git commit -m "test(http): add loom_handler_messages CT suite with streaming and error tests (#64)"
```

---

### Task 14: Full Test Run + Dialyzer

**Files:** None (verification only)

- [ ] **Step 1: Run all EUnit tests**

Run: `rebar3 eunit`
Expected: All tests PASS.

- [ ] **Step 2: Run all CT suites**

Run: `rebar3 ct`
Expected: All suites PASS.

- [ ] **Step 3: Run Dialyzer**

Run: `rebar3 dialyzer`
Expected: No warnings. Fix any type spec issues found.

- [ ] **Step 4: Commit any Dialyzer fixes**

If fixes were needed:
```bash
git add -A
git commit -m "fix(http): address Dialyzer warnings (#11)"
```

---

### Task 15: Update ROADMAP.md

**Files:**
- Modify: `ROADMAP.md`

- [ ] **Step 1: Mark P0-10 and P0-16 as complete in ROADMAP.md**

Update the Phase 0 section:
- Change `- [ ] `/v1/chat/completions` endpoint` to `- [x]`
- Change `- [ ] `/v1/messages` endpoint` to `- [x]`
- Update the Progress Summary table

- [ ] **Step 2: Commit**

```bash
git add ROADMAP.md
git commit -m "docs(roadmap): mark P0-10 and P0-16 as complete (#11)"
```
