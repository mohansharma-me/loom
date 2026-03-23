# loom_protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `loom_protocol`, the JSON wire protocol codec that encodes/decodes messages between Erlang and Python inference adapters.

**Architecture:** Pure functional module producing tagged tuples as the canonical internal message type. Uses `loom_json` for raw JSON. Three concerns: encode (outbound tuples → JSON), decode (JSON → validated inbound tuples), and line buffer (partial Port reads → complete lines). TDD with EUnit.

**Tech Stack:** Erlang/OTP 27, EUnit, `loom_json` (existing), rebar3

**Spec:** `.github/plans/4-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/loom_protocol.erl` | Create | Encode, decode, validate, line buffer |
| `test/loom_protocol_tests.erl` | Create | EUnit tests for all protocol functionality |
| `priv/scripts/mock_adapter.py` | Modify | Add `mem_total_gb` to health, `code`/`id` to errors, `cancel`/`shutdown` handlers |
| `test/mock_adapter_test.py` | Modify | Add tests for updated mock adapter |

---

## Task 1: Module skeleton with type specs

**Files:**
- Create: `src/loom_protocol.erl`
- Create: `test/loom_protocol_tests.erl`

- [ ] **Step 1: Create module with exports, types, and stub functions**

```erlang
-module(loom_protocol).

-export([encode/1, decode/1, new_buffer/0, feed/2]).

-export_type([
    outbound_msg/0, inbound_msg/0, generate_params/0,
    buffer/0, decode_error/0
]).

%% --- Types ---

-type generate_params() :: #{
    max_tokens => pos_integer(),
    temperature => float(),
    top_p => float(),
    stop => [binary()]
}.

-type outbound_msg() ::
    {generate, Id :: binary(), Prompt :: binary(), Params :: generate_params()}
  | {health}
  | {memory}
  | {cancel, Id :: binary()}
  | {shutdown}.

-type inbound_msg() ::
    {token, Id :: binary(), TokenId :: non_neg_integer(), Text :: binary(), Finished :: boolean()}
  | {done, Id :: binary(), TokensGenerated :: non_neg_integer(), TimeMs :: non_neg_integer()}
  | {error, Id :: binary() | undefined, Code :: binary(), Message :: binary()}
  | {health_response, Status :: binary(), GpuUtil :: float(), MemUsedGb :: float(), MemTotalGb :: float()}
  | {memory_response, MemoryInfo :: #{binary() => float() | term()}}
  | {ready, Model :: binary(), Backend :: binary()}.

-type buffer() :: binary().

-type decode_error() ::
    {invalid_json, term()}
  | missing_type
  | {unknown_type, binary()}
  | {missing_field, binary(), binary()}
  | {invalid_field, binary(), atom(), term()}.

%% --- Public API ---

-spec encode(outbound_msg()) -> binary().
encode(_Msg) ->
    erlang:error(not_implemented).

-spec decode(binary()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode(_Bin) ->
    erlang:error(not_implemented).

-spec new_buffer() -> buffer().
new_buffer() ->
    <<>>.

-spec feed(binary(), buffer()) -> {[binary()], buffer()}.
feed(_Data, _Buf) ->
    erlang:error(not_implemented).
```

- [ ] **Step 2: Create empty test module**

```erlang
-module(loom_protocol_tests).
-include_lib("eunit/include/eunit.hrl").
```

- [ ] **Step 3: Verify compilation**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 compile`
Expected: Compiles with no errors.

- [ ] **Step 4: Commit**

```bash
git add src/loom_protocol.erl test/loom_protocol_tests.erl
git commit -m "feat(protocol): add loom_protocol module skeleton with type specs (P0-04)"
```

---

## Task 2: Line buffer — `new_buffer/0` and `feed/2`

**Files:**
- Modify: `src/loom_protocol.erl` (replace `feed/2` stub)
- Modify: `test/loom_protocol_tests.erl` (add buffer tests)

- [ ] **Step 1: Write failing buffer tests**

```erlang
%% --- Buffer tests ---

buffer_new_test() ->
    ?assertEqual(<<>>, loom_protocol:new_buffer()).

buffer_single_complete_line_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"hello\n">>, Buf0),
    ?assertEqual([<<"hello">>], Lines),
    ?assertEqual(<<>>, Buf1).

buffer_multiple_lines_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"aaa\nbbb\nccc\n">>, Buf0),
    ?assertEqual([<<"aaa">>, <<"bbb">>, <<"ccc">>], Lines),
    ?assertEqual(<<>>, Buf1).

buffer_partial_read_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines1, Buf1} = loom_protocol:feed(<<"hel">>, Buf0),
    ?assertEqual([], Lines1),
    {Lines2, Buf2} = loom_protocol:feed(<<"lo\n">>, Buf1),
    ?assertEqual([<<"hello">>], Lines2),
    ?assertEqual(<<>>, Buf2).

buffer_partial_then_multiple_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {[], Buf1} = loom_protocol:feed(<<"aa">>, Buf0),
    {Lines, Buf2} = loom_protocol:feed(<<"a\nbbb\ncc">>, Buf1),
    ?assertEqual([<<"aaa">>, <<"bbb">>], Lines),
    ?assertEqual(<<"cc">>, Buf2).

buffer_empty_feed_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<>>, Buf0),
    ?assertEqual([], Lines),
    ?assertEqual(<<>>, Buf1).

buffer_newline_only_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"\n">>, Buf0),
    ?assertEqual([<<>>], Lines),
    ?assertEqual(<<>>, Buf1).

buffer_no_trailing_newline_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"no newline">>, Buf0),
    ?assertEqual([], Lines),
    ?assertEqual(<<"no newline">>, Buf1).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: Failures on all buffer tests except `buffer_new_test`.

- [ ] **Step 3: Implement `feed/2`**

Replace the `feed/2` stub in `src/loom_protocol.erl`:

```erlang
-spec feed(binary(), buffer()) -> {[binary()], buffer()}.
feed(Data, Buf) ->
    Combined = <<Buf/binary, Data/binary>>,
    case binary:split(Combined, <<"\n">>, [global]) of
        [NoNewline] ->
            {[], NoNewline};
        Parts ->
            %% Last element is remainder after final \n (possibly empty)
            {Lines, [Remainder]} = lists:split(length(Parts) - 1, Parts),
            {Lines, Remainder}
    end.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/loom_protocol.erl test/loom_protocol_tests.erl
git commit -m "feat(protocol): implement line buffer feed/2 with tests (P0-04)"
```

---

## Task 3: Encode outbound messages

**Files:**
- Modify: `src/loom_protocol.erl` (replace `encode/1` stub)
- Modify: `test/loom_protocol_tests.erl` (add encode tests)

- [ ] **Step 1: Write failing encode tests**

```erlang
%% --- Encode tests ---

encode_health_test() ->
    Bin = loom_protocol:encode({health}),
    ?assert(is_binary(Bin)),
    ?assertEqual($\n, binary:last(Bin)),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(#{<<"type">> => <<"health">>}, Map).

encode_memory_test() ->
    Bin = loom_protocol:encode({memory}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(#{<<"type">> => <<"memory">>}, Map).

encode_shutdown_test() ->
    Bin = loom_protocol:encode({shutdown}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(#{<<"type">> => <<"shutdown">>}, Map).

encode_cancel_test() ->
    Bin = loom_protocol:encode({cancel, <<"req-42">>}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(<<"cancel">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"req-42">>, maps:get(<<"id">>, Map)).

encode_generate_empty_params_test() ->
    Bin = loom_protocol:encode({generate, <<"req-1">>, <<"Hello">>, #{}}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ?assertEqual(<<"generate">>, maps:get(<<"type">>, Map)),
    ?assertEqual(<<"req-1">>, maps:get(<<"id">>, Map)),
    ?assertEqual(<<"Hello">>, maps:get(<<"prompt">>, Map)),
    ?assertEqual(#{}, maps:get(<<"params">>, Map)).

encode_generate_full_params_test() ->
    Params = #{max_tokens => 100, temperature => 0.7, top_p => 0.9, stop => [<<"END">>]},
    Bin = loom_protocol:encode({generate, <<"req-2">>, <<"Hi">>, Params}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ParamsMap = maps:get(<<"params">>, Map),
    ?assertEqual(100, maps:get(<<"max_tokens">>, ParamsMap)),
    ?assertEqual(0.7, maps:get(<<"temperature">>, ParamsMap)),
    ?assertEqual(0.9, maps:get(<<"top_p">>, ParamsMap)),
    ?assertEqual([<<"END">>], maps:get(<<"stop">>, ParamsMap)).

encode_generate_partial_params_test() ->
    Params = #{max_tokens => 50},
    Bin = loom_protocol:encode({generate, <<"req-3">>, <<"Test">>, Params}),
    Map = loom_json:decode(binary:part(Bin, 0, byte_size(Bin) - 1)),
    ParamsMap = maps:get(<<"params">>, Map),
    ?assertEqual(50, maps:get(<<"max_tokens">>, ParamsMap)),
    ?assertEqual(1, maps:size(ParamsMap)).

encode_bad_input_crashes_test() ->
    ?assertError(function_clause, loom_protocol:encode({bogus})),
    ?assertError(function_clause, loom_protocol:encode(not_a_tuple)).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: All encode tests fail with `not_implemented`.

- [ ] **Step 3: Implement `encode/1`**

Replace the `encode/1` stub in `src/loom_protocol.erl`:

```erlang
-spec encode(outbound_msg()) -> binary().
encode({health}) ->
    terminate_line(loom_json:encode(#{type => health}));
encode({memory}) ->
    terminate_line(loom_json:encode(#{type => memory}));
encode({shutdown}) ->
    terminate_line(loom_json:encode(#{type => shutdown}));
encode({cancel, Id}) ->
    terminate_line(loom_json:encode(#{type => cancel, id => Id}));
encode({generate, Id, Prompt, Params}) ->
    terminate_line(loom_json:encode(#{
        type => generate,
        id => Id,
        prompt => Prompt,
        params => Params
    })).

%% --- Internal helpers ---

-spec terminate_line(binary()) -> binary().
terminate_line(JsonBin) ->
    <<JsonBin/binary, $\n>>.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/loom_protocol.erl test/loom_protocol_tests.erl
git commit -m "feat(protocol): implement encode/1 for all outbound message types (P0-04)"
```

---

## Task 4: Decode — JSON parsing and type dispatch

**Files:**
- Modify: `src/loom_protocol.erl` (replace `decode/1` stub with parse + dispatch skeleton)
- Modify: `test/loom_protocol_tests.erl` (add error-path tests)

- [ ] **Step 1: Write failing decode error tests**

```erlang
%% --- Decode error tests ---

decode_invalid_json_test() ->
    ?assertMatch({error, {invalid_json, _}}, loom_protocol:decode(<<"not json">>)).

decode_empty_input_test() ->
    ?assertMatch({error, {invalid_json, _}}, loom_protocol:decode(<<>>)).

decode_missing_type_test() ->
    Json = loom_json:encode(#{foo => bar}),
    ?assertEqual({error, missing_type}, loom_protocol:decode(Json)).

decode_unknown_type_test() ->
    Json = loom_json:encode(#{type => <<"bogus">>}),
    ?assertEqual({error, {unknown_type, <<"bogus">>}}, loom_protocol:decode(Json)).

decode_not_object_test() ->
    ?assertEqual({error, missing_type}, loom_protocol:decode(<<"42">>)).

decode_array_not_object_test() ->
    ?assertEqual({error, missing_type}, loom_protocol:decode(<<"[1,2,3]">>)).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: Decode tests fail with `not_implemented`.

- [ ] **Step 3: Implement decode/1 skeleton with JSON parse, type extraction, and dispatch**

Replace the `decode/1` stub:

```erlang
-spec decode(binary()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode(Bin) ->
    try loom_json:decode(Bin) of
        Map when is_map(Map) ->
            case maps:get(<<"type">>, Map, undefined) of
                undefined -> {error, missing_type};
                Type -> decode_by_type(Type, Map)
            end;
        _NotMap ->
            {error, missing_type}
    catch
        _:Reason ->
            {error, {invalid_json, Reason}}
    end.

-spec decode_by_type(binary(), map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_by_type(<<"token">>, Map) -> decode_token(Map);
decode_by_type(<<"done">>, Map) -> decode_done(Map);
decode_by_type(<<"error">>, Map) -> decode_error_msg(Map);
decode_by_type(<<"health">>, Map) -> decode_health(Map);
decode_by_type(<<"memory">>, Map) -> decode_memory(Map);
decode_by_type(<<"ready">>, Map) -> decode_ready(Map);
decode_by_type(Type, _Map) -> {error, {unknown_type, Type}}.

%% Stubs for per-type decoders (implemented in subsequent tasks)
-spec decode_token(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_token(_) -> erlang:error(not_implemented).
-spec decode_done(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_done(_) -> erlang:error(not_implemented).
-spec decode_error_msg(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_error_msg(_) -> erlang:error(not_implemented).
-spec decode_health(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_health(_) -> erlang:error(not_implemented).
-spec decode_memory(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_memory(_) -> erlang:error(not_implemented).
-spec decode_ready(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_ready(_) -> erlang:error(not_implemented).
```

- [ ] **Step 4: Run tests to verify error-path tests pass**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: All 6 error-path decode tests pass. Buffer and encode tests still pass. Per-type decode stubs not yet tested.

- [ ] **Step 5: Commit**

```bash
git add src/loom_protocol.erl test/loom_protocol_tests.erl
git commit -m "feat(protocol): implement decode/1 JSON parsing and type dispatch (P0-04)"
```

---

## Task 5: Decode — `token` and `done` messages

**Files:**
- Modify: `src/loom_protocol.erl` (implement `decode_token/1`, `decode_done/1`)
- Modify: `test/loom_protocol_tests.erl` (add happy-path and validation tests)

- [ ] **Step 1: Write failing tests**

```erlang
%% --- Decode token tests ---

decode_token_test() ->
    Json = loom_json:encode(#{
        type => <<"token">>, id => <<"r1">>,
        token_id => 42, text => <<"hello">>, finished => false
    }),
    ?assertEqual(
        {ok, {token, <<"r1">>, 42, <<"hello">>, false}},
        loom_protocol:decode(Json)
    ).

decode_token_finished_test() ->
    Json = loom_json:encode(#{
        type => <<"token">>, id => <<"r1">>,
        token_id => 99, text => <<"end">>, finished => true
    }),
    ?assertEqual(
        {ok, {token, <<"r1">>, 99, <<"end">>, true}},
        loom_protocol:decode(Json)
    ).

decode_token_missing_id_test() ->
    Json = loom_json:encode(#{
        type => <<"token">>, token_id => 1, text => <<"x">>, finished => false
    }),
    ?assertEqual(
        {error, {missing_field, <<"id">>, <<"token">>}},
        loom_protocol:decode(Json)
    ).

decode_token_bad_token_id_test() ->
    Json = loom_json:encode(#{
        type => <<"token">>, id => <<"r1">>,
        token_id => <<"not_int">>, text => <<"x">>, finished => false
    }),
    ?assertMatch(
        {error, {invalid_field, <<"token_id">>, integer, _}},
        loom_protocol:decode(Json)
    ).

%% --- Decode done tests ---

decode_done_test() ->
    Json = loom_json:encode(#{
        type => <<"done">>, id => <<"r1">>,
        tokens_generated => 47, time_ms => 1820
    }),
    ?assertEqual(
        {ok, {done, <<"r1">>, 47, 1820}},
        loom_protocol:decode(Json)
    ).

decode_done_missing_field_test() ->
    Json = loom_json:encode(#{
        type => <<"done">>, id => <<"r1">>, tokens_generated => 10
    }),
    ?assertEqual(
        {error, {missing_field, <<"time_ms">>, <<"done">>}},
        loom_protocol:decode(Json)
    ).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: New decode tests fail with `not_implemented`.

- [ ] **Step 3: Implement `decode_token/1` and `decode_done/1`**

Add validation helpers and per-type decoders in `src/loom_protocol.erl`. Replace the stubs:

```erlang
%% --- Validation helpers ---

-spec require(binary(), binary(), map()) -> {ok, term()} | {error, decode_error()}.
require(Field, Type, Map) ->
    case maps:get(Field, Map, undefined) of
        undefined -> {error, {missing_field, Field, Type}};
        Value -> {ok, Value}
    end.

-spec require_type(binary(), atom(), term(), fun((term()) -> boolean())) ->
    {ok, term()} | {error, decode_error()}.
require_type(Field, Expected, Value, Check) ->
    case Check(Value) of
        true -> {ok, Value};
        false -> {error, {invalid_field, Field, Expected, Value}}
    end.

-spec is_non_neg_integer(term()) -> boolean().
is_non_neg_integer(V) -> is_integer(V) andalso V >= 0.

%% --- Per-type decoders ---

-spec decode_token(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_token(Map) ->
    with_fields(<<"token">>, Map, [
        {<<"id">>, binary, fun is_binary/1},
        {<<"token_id">>, integer, fun is_non_neg_integer/1},
        {<<"text">>, binary, fun is_binary/1},
        {<<"finished">>, boolean, fun is_boolean/1}
    ], fun([Id, TokenId, Text, Finished]) ->
        {ok, {token, Id, TokenId, Text, Finished}}
    end).

-spec decode_done(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_done(Map) ->
    with_fields(<<"done">>, Map, [
        {<<"id">>, binary, fun is_binary/1},
        {<<"tokens_generated">>, integer, fun is_non_neg_integer/1},
        {<<"time_ms">>, integer, fun is_non_neg_integer/1}
    ], fun([Id, TokensGenerated, TimeMs]) ->
        {ok, {done, Id, TokensGenerated, TimeMs}}
    end).

-spec to_float(number()) -> float().
to_float(V) when is_integer(V) -> float(V);
to_float(V) when is_float(V) -> V.

%% Generic field extraction + validation
-spec with_fields(binary(), map(),
    [{binary(), atom(), fun((term()) -> boolean())}],
    fun(([term()]) -> {ok, inbound_msg()})) ->
    {ok, inbound_msg()} | {error, decode_error()}.
with_fields(Type, Map, Fields, Build) ->
    with_fields_acc(Type, Map, Fields, [], Build).

-spec with_fields_acc(binary(), map(),
    [{binary(), atom(), fun((term()) -> boolean())}],
    [term()],
    fun(([term()]) -> {ok, inbound_msg()})) ->
    {ok, inbound_msg()} | {error, decode_error()}.
with_fields_acc(_Type, _Map, [], Acc, Build) ->
    Build(lists:reverse(Acc));
with_fields_acc(Type, Map, [{Field, Expected, Check} | Rest], Acc, Build) ->
    case require(Field, Type, Map) of
        {error, _} = Err -> Err;
        {ok, Value} ->
            case require_type(Field, Expected, Value, Check) of
                {error, _} = Err -> Err;
                {ok, Valid} -> with_fields_acc(Type, Map, Rest, [Valid | Acc], Build)
            end
    end.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/loom_protocol.erl test/loom_protocol_tests.erl
git commit -m "feat(protocol): implement decode for token and done messages (P0-04)"
```

---

## Task 6: Decode — `error` message (with optional `id`)

**Files:**
- Modify: `src/loom_protocol.erl` (implement `decode_error_msg/1`)
- Modify: `test/loom_protocol_tests.erl`

- [ ] **Step 1: Write failing tests**

```erlang
%% --- Decode error tests ---

decode_error_with_id_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>, id => <<"r1">>,
        code => <<"engine_crashed">>, message => <<"vLLM died">>
    }),
    ?assertEqual(
        {ok, {error, <<"r1">>, <<"engine_crashed">>, <<"vLLM died">>}},
        loom_protocol:decode(Json)
    ).

decode_error_no_id_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>,
        code => <<"parse_error">>, message => <<"bad input">>
    }),
    ?assertEqual(
        {ok, {error, undefined, <<"parse_error">>, <<"bad input">>}},
        loom_protocol:decode(Json)
    ).

decode_error_null_id_test() ->
    %% JSON null maps to Erlang null atom via loom_json
    Json = <<"{\"type\":\"error\",\"id\":null,\"code\":\"x\",\"message\":\"y\"}">>,
    ?assertEqual(
        {ok, {error, undefined, <<"x">>, <<"y">>}},
        loom_protocol:decode(Json)
    ).

decode_error_missing_code_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>, message => <<"oops">>
    }),
    ?assertEqual(
        {error, {missing_field, <<"code">>, <<"error">>}},
        loom_protocol:decode(Json)
    ).

decode_error_missing_message_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>, code => <<"x">>
    }),
    ?assertEqual(
        {error, {missing_field, <<"message">>, <<"error">>}},
        loom_protocol:decode(Json)
    ).

decode_error_invalid_id_type_test() ->
    Json = loom_json:encode(#{
        type => <<"error">>, id => 42,
        code => <<"x">>, message => <<"y">>
    }),
    ?assertMatch(
        {error, {invalid_field, <<"id">>, binary, _}},
        loom_protocol:decode(Json)
    ).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: New error decode tests fail.

- [ ] **Step 3: Implement `decode_error_msg/1`**

Replace the stub in `src/loom_protocol.erl`:

```erlang
-spec decode_error_msg(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_error_msg(Map) ->
    %% id is optional: absent or null → undefined
    Id = case maps:get(<<"id">>, Map, undefined) of
        null -> undefined;
        undefined -> undefined;
        V when is_binary(V) -> V;
        Other -> Other  %% will fail type check below if not binary
    end,
    case {Id, require(<<"code">>, <<"error">>, Map), require(<<"message">>, <<"error">>, Map)} of
        {_, {error, _} = Err, _} -> Err;
        {_, _, {error, _} = Err} -> Err;
        {Id2, {ok, Code}, {ok, Msg}} ->
            case {is_binary(Id2) orelse Id2 =:= undefined, is_binary(Code), is_binary(Msg)} of
                {true, true, true} -> {ok, {error, Id2, Code, Msg}};
                {false, _, _} -> {error, {invalid_field, <<"id">>, binary, Id2}};
                {_, false, _} -> {error, {invalid_field, <<"code">>, binary, Code}};
                {_, _, false} -> {error, {invalid_field, <<"message">>, binary, Msg}}
            end
    end.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/loom_protocol.erl test/loom_protocol_tests.erl
git commit -m "feat(protocol): implement decode for error messages with optional id (P0-04)"
```

---

## Task 7: Decode — `health_response`, `memory_response`, `ready`

**Files:**
- Modify: `src/loom_protocol.erl` (implement remaining decoders)
- Modify: `test/loom_protocol_tests.erl`

- [ ] **Step 1: Write failing tests**

```erlang
%% --- Decode health_response tests ---

decode_health_response_test() ->
    Json = loom_json:encode(#{
        type => <<"health">>, status => <<"ok">>,
        gpu_util => 0.73, mem_used_gb => 62.4, mem_total_gb => 80.0
    }),
    ?assertEqual(
        {ok, {health_response, <<"ok">>, 0.73, 62.4, 80.0}},
        loom_protocol:decode(Json)
    ).

decode_health_response_missing_field_test() ->
    Json = loom_json:encode(#{
        type => <<"health">>, status => <<"ok">>,
        gpu_util => 0.5, mem_used_gb => 10.0
    }),
    ?assertEqual(
        {error, {missing_field, <<"mem_total_gb">>, <<"health">>}},
        loom_protocol:decode(Json)
    ).

decode_health_response_integer_coercion_test() ->
    %% JSON integers (e.g., 0 instead of 0.0) should be coerced to floats
    Json = loom_json:encode(#{
        type => <<"health">>, status => <<"ok">>,
        gpu_util => 0, mem_used_gb => 0, mem_total_gb => 80
    }),
    ?assertEqual(
        {ok, {health_response, <<"ok">>, 0.0, 0.0, 80.0}},
        loom_protocol:decode(Json)
    ).

decode_health_response_bad_type_test() ->
    Json = loom_json:encode(#{
        type => <<"health">>, status => <<"ok">>,
        gpu_util => <<"not_number">>, mem_used_gb => 0.0, mem_total_gb => 80.0
    }),
    ?assertMatch(
        {error, {invalid_field, <<"gpu_util">>, number, _}},
        loom_protocol:decode(Json)
    ).

%% --- Decode memory_response tests ---

decode_memory_response_test() ->
    Json = loom_json:encode(#{
        type => <<"memory">>,
        total_gb => 80.0, used_gb => 62.4, available_gb => 17.6
    }),
    {ok, {memory_response, Info}} = loom_protocol:decode(Json),
    ?assertEqual(80.0, maps:get(<<"total_gb">>, Info)),
    ?assertEqual(62.4, maps:get(<<"used_gb">>, Info)),
    ?assertEqual(17.6, maps:get(<<"available_gb">>, Info)).

decode_memory_response_extra_keys_test() ->
    Json = loom_json:encode(#{
        type => <<"memory">>,
        total_gb => 80.0, used_gb => 40.0, available_gb => 40.0,
        kv_cache_gb => 25.0
    }),
    {ok, {memory_response, Info}} = loom_protocol:decode(Json),
    ?assertEqual(25.0, maps:get(<<"kv_cache_gb">>, Info)).

decode_memory_response_missing_field_test() ->
    Json = loom_json:encode(#{
        type => <<"memory">>,
        total_gb => 80.0, used_gb => 40.0
    }),
    ?assertEqual(
        {error, {missing_field, <<"available_gb">>, <<"memory">>}},
        loom_protocol:decode(Json)
    ).

%% --- Decode ready tests ---

decode_ready_test() ->
    Json = loom_json:encode(#{
        type => <<"ready">>,
        model => <<"meta-llama/Llama-3-8B">>,
        backend => <<"vllm">>
    }),
    ?assertEqual(
        {ok, {ready, <<"meta-llama/Llama-3-8B">>, <<"vllm">>}},
        loom_protocol:decode(Json)
    ).

decode_ready_missing_model_test() ->
    Json = loom_json:encode(#{type => <<"ready">>, backend => <<"vllm">>}),
    ?assertEqual(
        {error, {missing_field, <<"model">>, <<"ready">>}},
        loom_protocol:decode(Json)
    ).

decode_ready_missing_backend_test() ->
    Json = loom_json:encode(#{type => <<"ready">>, model => <<"m">>}),
    ?assertEqual(
        {error, {missing_field, <<"backend">>, <<"ready">>}},
        loom_protocol:decode(Json)
    ).

decode_ready_bad_type_test() ->
    Json = loom_json:encode(#{type => <<"ready">>, model => 42, backend => <<"vllm">>}),
    ?assertMatch(
        {error, {invalid_field, <<"model">>, binary, _}},
        loom_protocol:decode(Json)
    ).

decode_done_bad_type_test() ->
    Json = loom_json:encode(#{
        type => <<"done">>, id => <<"r1">>,
        tokens_generated => <<"not_int">>, time_ms => 100
    }),
    ?assertMatch(
        {error, {invalid_field, <<"tokens_generated">>, integer, _}},
        loom_protocol:decode(Json)
    ).

decode_memory_bad_type_test() ->
    Json = loom_json:encode(#{
        type => <<"memory">>,
        total_gb => <<"not_number">>, used_gb => 0.0, available_gb => 0.0
    }),
    ?assertMatch(
        {error, {invalid_field, <<"total_gb">>, number, _}},
        loom_protocol:decode(Json)
    ).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: New tests fail.

- [ ] **Step 3: Implement `decode_health/1`, `decode_memory/1`, `decode_ready/1`**

Replace stubs in `src/loom_protocol.erl`:

```erlang
-spec decode_health(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_health(Map) ->
    with_fields(<<"health">>, Map, [
        {<<"status">>, binary, fun is_binary/1},
        {<<"gpu_util">>, number, fun is_number/1},
        {<<"mem_used_gb">>, number, fun is_number/1},
        {<<"mem_total_gb">>, number, fun is_number/1}
    ], fun([Status, GpuUtil, MemUsedGb, MemTotalGb]) ->
        {ok, {health_response, Status,
              to_float(GpuUtil), to_float(MemUsedGb), to_float(MemTotalGb)}}
    end).

-spec decode_memory(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_memory(Map) ->
    Type = <<"memory">>,
    %% Validate required keys exist and are numbers
    Required = [<<"total_gb">>, <<"used_gb">>, <<"available_gb">>],
    case validate_required_numbers(Type, Map, Required) of
        {error, _} = Err -> Err;
        ok ->
            %% Strip the "type" key, keep everything else
            Info = maps:remove(<<"type">>, Map),
            {ok, {memory_response, Info}}
    end.

-spec validate_required_numbers(binary(), map(), [binary()]) ->
    ok | {error, decode_error()}.
validate_required_numbers(_Type, _Map, []) ->
    ok;
validate_required_numbers(Type, Map, [Field | Rest]) ->
    case maps:get(Field, Map, undefined) of
        undefined -> {error, {missing_field, Field, Type}};
        V when is_number(V) -> validate_required_numbers(Type, Map, Rest);
        V -> {error, {invalid_field, Field, number, V}}
    end.

-spec decode_ready(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_ready(Map) ->
    with_fields(<<"ready">>, Map, [
        {<<"model">>, binary, fun is_binary/1},
        {<<"backend">>, binary, fun is_binary/1}
    ], fun([Model, Backend]) ->
        {ok, {ready, Model, Backend}}
    end).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit --module=loom_protocol_tests`
Expected: All tests pass.

- [ ] **Step 5: Run Dialyzer**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 dialyzer`
Expected: No warnings for `loom_protocol.erl`.

- [ ] **Step 6: Commit**

```bash
git add src/loom_protocol.erl test/loom_protocol_tests.erl
git commit -m "feat(protocol): implement decode for health, memory, and ready messages (P0-04)"
```

---

## Task 8: Update mock adapter for protocol compliance

**Files:**
- Modify: `priv/scripts/mock_adapter.py`
- Modify: `test/mock_adapter_test.py`

- [ ] **Step 1: Update `handle_health` to include `mem_total_gb`**

In `priv/scripts/mock_adapter.py`, change `handle_health`:

```python
def handle_health(_msg):
    return [{"type": "health", "status": "ok", "gpu_util": 0.0,
             "mem_used_gb": 0.0, "mem_total_gb": 80.0}]
```

- [ ] **Step 2: Update `handle_generate` error to include `code` and `id`**

```python
def handle_generate(msg):
    req_id = msg.get("id")
    if req_id is None:
        return [{"type": "error", "code": "missing_field",
                 "message": "generate request missing 'id' field"}]

    responses = []
    for i, token_text in enumerate(MOCK_TOKENS):
        responses.append(
            {
                "type": "token",
                "id": req_id,
                "token_id": i + 1,
                "text": token_text,
                "finished": False,
            }
        )
    responses.append(
        {
            "type": "done",
            "id": req_id,
            "tokens_generated": len(MOCK_TOKENS),
            "time_ms": 0,
        }
    )
    return responses
```

- [ ] **Step 3: Add `cancel` and `shutdown` handlers**

```python
def handle_cancel(msg):
    # Fire-and-forget: no response. In real adapter, would abort generation.
    return []


def handle_shutdown(_msg):
    print("[mock_adapter] shutdown requested, exiting", file=sys.stderr)
    sys.exit(0)
```

Update the `HANDLERS` dict:

```python
HANDLERS = {
    "health": handle_health,
    "memory": handle_memory,
    "generate": handle_generate,
    "cancel": handle_cancel,
    "shutdown": handle_shutdown,
}
```

- [ ] **Step 4: Update error responses in `process_line` to include `code`**

```python
def process_line(line):
    """Parse a JSON line and return response dicts."""
    try:
        msg = json.loads(line)
    except json.JSONDecodeError as e:
        return [{"type": "error", "code": "invalid_json",
                 "message": f"invalid JSON: {e}"}]

    msg_type = msg.get("type")
    if msg_type is None:
        return [{"type": "error", "code": "missing_type",
                 "message": "message missing 'type' field"}]

    handler = HANDLERS.get(msg_type)
    if handler is None:
        return [{"type": "error", "code": "unknown_type",
                 "message": f"unknown message type: {msg_type}"}]

    return handler(msg)
```

Also update the catch-all in `main()`:

```python
error_resp = {"type": "error", "code": "internal_error",
              "message": f"internal adapter error: {e}"}
```

- [ ] **Step 5: Update Python tests in `test/mock_adapter_test.py`**

Update existing tests that check response format to expect the new `code` field, `mem_total_gb` in health, etc. Add new tests:

```python
def test_cancel_returns_no_response(self):
    """Cancel is fire-and-forget, no response expected."""
    responses = process_line('{"type": "cancel", "id": "req-1"}')
    self.assertEqual(responses, [])

def test_health_includes_mem_total(self):
    """Health response includes mem_total_gb field."""
    responses = process_line('{"type": "health"}')
    self.assertEqual(len(responses), 1)
    self.assertIn("mem_total_gb", responses[0])
    self.assertEqual(responses[0]["mem_total_gb"], 80.0)

def test_error_includes_code_field(self):
    """All error responses include a code field."""
    responses = process_line('not json')
    self.assertEqual(len(responses), 1)
    self.assertEqual(responses[0]["type"], "error")
    self.assertIn("code", responses[0])
```

- [ ] **Step 6: Run Python tests**

Run: `cd /Users/mohansharma/Projects/loom && python3 -m pytest test/mock_adapter_test.py -v 2>/dev/null || python3 -m unittest test.mock_adapter_test -v`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add priv/scripts/mock_adapter.py test/mock_adapter_test.py
git commit -m "fix: update mock adapter for protocol compliance — add code, mem_total_gb, cancel/shutdown (P0-04)"
```

---

## Task 9: Full test suite pass and Dialyzer clean

**Files:**
- All files from prior tasks

- [ ] **Step 1: Run full EUnit suite**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 eunit`
Expected: All tests pass, including `loom_protocol_tests`.

- [ ] **Step 2: Run Dialyzer**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 dialyzer`
Expected: No warnings.

- [ ] **Step 3: Run xref**

Run: `cd /Users/mohansharma/Projects/loom && rebar3 xref`
Expected: No warnings.

- [ ] **Step 4: Run Python tests**

Run: `cd /Users/mohansharma/Projects/loom && python3 -m unittest test.mock_adapter_test -v`
Expected: All tests pass.

- [ ] **Step 5: If any failures, fix and commit. Otherwise, done.**

All checks green = Task 9 complete.
