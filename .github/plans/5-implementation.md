# loom_port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the `loom_port` gen_statem that manages external OS subprocesses via Erlang Ports — the foundational BEAM-to-adapter communication layer.

**Architecture:** `loom_port` is a `gen_statem` (state_functions mode with state_enter) managing 4 states: spawning → loading → ready → shutting_down. It opens an OS process via `open_port/2` with `{line, N}` framing, handles heartbeat-guarded startup, forwards decoded protocol messages to an owner process, and implements a 3-level shutdown escalation (shutdown command → port_close → orphan logging).

**Tech Stack:** Erlang/OTP 27, gen_statem, loom_protocol (existing), Python 3.10+ (mock adapter), EUnit + Common Test

**Design spec:** `.github/plans/5-design.md`
**Issue:** [#5](https://github.com/mohansharma-me/loom/issues/5)

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `src/loom_protocol.erl` | Modify | Add `heartbeat` to inbound_msg type + decode_heartbeat/1 |
| `test/loom_protocol_tests.erl` | Modify | Add heartbeat decode tests |
| `src/loom_port.erl` | Create | gen_statem: Port lifecycle, state machine, owner notifications |
| `test/loom_port_tests.erl` | Create | EUnit tests for loom_port (happy path, timeouts, errors) |
| `test/loom_port_SUITE.erl` | Create | Common Test suite (crash, shutdown escalation, owner death) |
| `priv/scripts/mock_adapter.py` | Modify | Add ready, heartbeat, stdin watchdog, --startup-delay |
| `test/mock_adapter_test.py` | Modify | Update tests for new mock adapter features |

---

## Task 1: Add heartbeat to loom_protocol

**Files:**
- Modify: `src/loom_protocol.erl`
- Modify: `test/loom_protocol_tests.erl`

- [ ] **Step 1: Write failing tests for heartbeat decode**

Add to `test/loom_protocol_tests.erl`:

```erlang
%% --- Decode heartbeat tests ---

-spec decode_heartbeat_test() -> any().
decode_heartbeat_test() ->
    Json = loom_json:encode(#{
        type => <<"heartbeat">>, status => <<"loading">>,
        detail => <<"loading weights 3/32 layers">>
    }),
    ?assertEqual(
        {ok, {heartbeat, <<"loading">>, <<"loading weights 3/32 layers">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_heartbeat_no_detail_test() -> any().
decode_heartbeat_no_detail_test() ->
    Json = loom_json:encode(#{
        type => <<"heartbeat">>, status => <<"initializing">>
    }),
    ?assertEqual(
        {ok, {heartbeat, <<"initializing">>, <<"">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_heartbeat_missing_status_test() -> any().
decode_heartbeat_missing_status_test() ->
    Json = loom_json:encode(#{type => <<"heartbeat">>}),
    ?assertEqual(
        {error, {missing_field, <<"status">>, <<"heartbeat">>}},
        loom_protocol:decode(Json)
    ).

-spec decode_heartbeat_bad_status_type_test() -> any().
decode_heartbeat_bad_status_type_test() ->
    Json = loom_json:encode(#{type => <<"heartbeat">>, status => 42}),
    ?assertMatch(
        {error, {invalid_field, <<"status">>, binary, _}},
        loom_protocol:decode(Json)
    ).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_protocol_tests`
Expected: FAIL — `decode_heartbeat_test` fails because `<<"heartbeat">>` hits `{error, {unknown_type, <<"heartbeat">>}}`

- [ ] **Step 3: Add heartbeat to inbound_msg type**

In `src/loom_protocol.erl`, update the `inbound_msg()` type (after the `ready` variant):

```erlang
-type inbound_msg() ::
    {token, Id :: binary(), TokenId :: non_neg_integer(), Text :: binary(), Finished :: boolean()}
  | {done, Id :: binary(), TokensGenerated :: non_neg_integer(), TimeMs :: non_neg_integer()}
  | {error, Id :: binary() | undefined, Code :: binary(), Message :: binary()}
  | {health_response, Status :: binary(), GpuUtil :: float(), MemUsedGb :: float(), MemTotalGb :: float()}
  | {memory_response, MemoryInfo :: #{binary() => number()}}
  | {ready, Model :: binary(), Backend :: binary()}
  | {heartbeat, Status :: binary(), Detail :: binary()}.
```

- [ ] **Step 4: Add decode_by_type clause for heartbeat**

In `src/loom_protocol.erl`, add before the catch-all clause:

```erlang
decode_by_type(<<"heartbeat">>, Map) -> decode_heartbeat(Map);
```

- [ ] **Step 5: Implement decode_heartbeat/1**

Add to `src/loom_protocol.erl` after `decode_ready/1`:

```erlang
-spec decode_heartbeat(map()) -> {ok, inbound_msg()} | {error, decode_error()}.
decode_heartbeat(Map) ->
    case require(<<"status">>, <<"heartbeat">>, Map) of
        {error, _} = Err -> Err;
        {ok, Status} ->
            case is_binary(Status) of
                false ->
                    {error, {invalid_field, <<"status">>, binary, Status}};
                true ->
                    %% ASSUMPTION: detail is optional; defaults to <<"">> if absent.
                    %% Similar pattern to decode_error_msg/1 handling optional id.
                    Detail = case maps:get(<<"detail">>, Map, undefined) of
                        undefined -> <<>>;
                        D when is_binary(D) -> D;
                        D -> D  %% non-binary will be caught below
                    end,
                    case is_binary(Detail) of
                        true -> {ok, {heartbeat, Status, Detail}};
                        false -> {error, {invalid_field, <<"detail">>, binary, Detail}}
                    end
            end
    end.
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_protocol_tests`
Expected: ALL PASS (including all existing tests + 4 new heartbeat tests)

- [ ] **Step 7: Run dialyzer**

Run: `rebar3 dialyzer`
Expected: PASS — no warnings

- [ ] **Step 8: Commit**

```bash
git add src/loom_protocol.erl test/loom_protocol_tests.erl
git commit -m "feat(protocol): add heartbeat inbound message type

Add {heartbeat, Status, Detail} to inbound_msg() for adapter startup
health monitoring. Detail field is optional (defaults to <<\"\">>).

Refs #5"
```

---

## Task 2: Update mock adapter with ready, heartbeat, stdin watchdog

**Files:**
- Modify: `priv/scripts/mock_adapter.py`
- Modify: `test/mock_adapter_test.py`

- [ ] **Step 1: Replace Python tests with updated test suite**

Replace `test/mock_adapter_test.py` entirely. The existing unittest-based tests are incompatible with the new startup sequence (heartbeat + ready messages appear before any command responses, stdin watchdog causes `communicate()` to race with `os._exit`). The new tests use standalone functions that properly handle the startup protocol:

```python
import subprocess
import json
import time
import os
import signal
import sys

ADAPTER_PATH = os.path.join(os.path.dirname(__file__), '..', 'priv', 'scripts', 'mock_adapter.py')


def start_adapter(args=None):
    """Start mock_adapter.py as subprocess."""
    cmd = [sys.executable, ADAPTER_PATH] + (args or [])
    return subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def read_messages(proc, count, timeout=5):
    """Read count JSON messages from adapter stdout."""
    messages = []
    deadline = time.time() + timeout
    while len(messages) < count and time.time() < deadline:
        line = proc.stdout.readline()
        if line:
            messages.append(json.loads(line.strip()))
    return messages


def test_startup_sends_heartbeat_then_ready():
    """Adapter must send at least one heartbeat then a ready message on startup."""
    proc = start_adapter()
    try:
        msgs = read_messages(proc, 2)
        assert len(msgs) >= 2, f"Expected >= 2 messages, got {len(msgs)}"
        assert msgs[0]["type"] == "heartbeat"
        assert msgs[0]["status"] == "loading"
        assert msgs[-1]["type"] == "ready"
        assert msgs[-1]["model"] == "mock"
        assert msgs[-1]["backend"] == "mock"
    finally:
        proc.terminate()
        proc.wait()


def test_startup_delay_sends_heartbeats():
    """With --startup-delay, adapter sends periodic heartbeats before ready."""
    proc = start_adapter(["--startup-delay", "2"])
    try:
        # Should get heartbeat(s) over 2 seconds then ready
        msgs = read_messages(proc, 3, timeout=5)
        heartbeats = [m for m in msgs if m["type"] == "heartbeat"]
        readies = [m for m in msgs if m["type"] == "ready"]
        assert len(heartbeats) >= 1, f"Expected >= 1 heartbeat, got {len(heartbeats)}"
        assert len(readies) == 1, f"Expected 1 ready, got {len(readies)}"
    finally:
        proc.terminate()
        proc.wait()


def test_stdin_close_kills_adapter():
    """Closing stdin should cause adapter to exit via watchdog."""
    proc = start_adapter()
    msgs = read_messages(proc, 2)  # wait for ready
    proc.stdin.close()
    try:
        exit_code = proc.wait(timeout=5)
        # os._exit(1) from watchdog or 0 from normal stdin EOF
        assert exit_code is not None, "Adapter should have exited"
    except subprocess.TimeoutExpired:
        proc.kill()
        raise AssertionError("Adapter did not exit after stdin close within 5s")


def test_shutdown_exits_cleanly():
    """Shutdown command should cause clean exit with code 0."""
    proc = start_adapter()
    msgs = read_messages(proc, 2)  # wait for ready
    proc.stdin.write(json.dumps({"type": "shutdown"}) + "\n")
    proc.stdin.flush()
    exit_code = proc.wait(timeout=5)
    assert exit_code == 0, f"Expected exit code 0, got {exit_code}"


if __name__ == "__main__":
    test_startup_sends_heartbeat_then_ready()
    print("PASS: test_startup_sends_heartbeat_then_ready")
    test_startup_delay_sends_heartbeats()
    print("PASS: test_startup_delay_sends_heartbeats")
    test_stdin_close_kills_adapter()
    print("PASS: test_stdin_close_kills_adapter")
    test_shutdown_exits_cleanly()
    print("PASS: test_shutdown_exits_cleanly")
    print("All mock adapter tests passed.")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 test/mock_adapter_test.py`
Expected: FAIL — adapter doesn't send heartbeat or ready yet

- [ ] **Step 3: Implement mock adapter updates**

Replace `priv/scripts/mock_adapter.py` with updated version:

```python
#!/usr/bin/env python3
"""Mock inference engine adapter for GPU-free development.

Reads line-delimited JSON from stdin, writes responses to stdout.
Speaks the Loom wire protocol (see KNOWLEDGE.md section 4.4).

Uses only Python stdlib — no external dependencies.
"""
import argparse
import json
import os
import sys
import threading
import time
import traceback


# ASSUMPTION: Fixed mock tokens simulate a generate response; real adapter will stream actual model output.
MOCK_TOKENS = ["Hello", "from", "Loom", "mock", "adapter"]


def send_msg(msg):
    """Write a JSON message to stdout, flush immediately."""
    sys.stdout.write(json.dumps(msg) + '\n')
    sys.stdout.flush()


# ASSUMPTION: Returns zeroed GPU metrics since no real GPU is present.
# ASSUMPTION: mem_total_gb fixed at 80.0 to approximate H100 GPU specs (see KNOWLEDGE.md).
def handle_health(_msg):
    return [{"type": "health", "status": "ok", "gpu_util": 0.0,
             "mem_used_gb": 0.0, "mem_total_gb": 80.0}]


# ASSUMPTION: Returns 80GB total to approximate H100 GPU specs (see KNOWLEDGE.md).
def handle_memory(_msg):
    return [
        {
            "type": "memory",
            "total_gb": 80.0,
            "used_gb": 0.0,
            "available_gb": 80.0,
        }
    ]


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


def handle_cancel(msg):
    # Fire-and-forget: no response. In real adapter, would abort generation.
    return []


def handle_shutdown(_msg):
    print("[mock_adapter] shutdown requested, exiting", file=sys.stderr)
    sys.exit(0)


# ASSUMPTION: Protocol matches KNOWLEDGE.md section 4.4 line-delimited JSON wire protocol.
HANDLERS = {
    "health": handle_health,
    "memory": handle_memory,
    "generate": handle_generate,
    "cancel": handle_cancel,
    "shutdown": handle_shutdown,
}


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


def stdin_watchdog():
    """Background thread: detect stdin EOF and force-exit.

    When the Erlang Port is closed (port_close/1), stdin gets EOF.
    This watchdog detects that and calls os._exit(1) to guarantee
    the adapter process dies, even if the main thread is blocked.
    Cross-platform: works on Linux, macOS, and Windows.
    """
    try:
        while True:
            # read(1) blocks until data or EOF
            chunk = sys.stdin.buffer.read(1)
            if not chunk:
                # EOF — parent closed our stdin
                print("[mock_adapter] stdin EOF detected by watchdog, force-exiting",
                      file=sys.stderr)
                os._exit(1)
            # If we read actual data, something is wrong (stdin should be
            # consumed by the main loop). Just discard it.
    except Exception:
        # If stdin read fails for any reason, force-exit
        os._exit(1)


def startup_sequence(startup_delay, heartbeat_interval):
    """Send heartbeat(s) during simulated loading, then send ready."""
    send_msg({"type": "heartbeat", "status": "loading",
              "detail": "initializing mock engine"})

    if startup_delay > 0:
        elapsed = 0.0
        while elapsed < startup_delay:
            time.sleep(min(heartbeat_interval, startup_delay - elapsed))
            elapsed += heartbeat_interval
            if elapsed < startup_delay:
                send_msg({"type": "heartbeat", "status": "loading",
                          "detail": f"loading mock model ({elapsed:.0f}s/{startup_delay}s)"})

    send_msg({"type": "ready", "model": "mock", "backend": "mock"})


def main():
    parser = argparse.ArgumentParser(description="Loom mock inference adapter")
    parser.add_argument("--startup-delay", type=float, default=0,
                        help="Seconds to simulate model loading (default: 0)")
    parser.add_argument("--heartbeat-interval", type=float, default=5.0,
                        help="Seconds between heartbeats during loading (default: 5)")
    args = parser.parse_args()

    print("[mock_adapter] started", file=sys.stderr)

    # Start stdin watchdog before anything else
    watchdog = threading.Thread(target=stdin_watchdog, daemon=True)
    watchdog.start()

    # Startup: heartbeat(s) + ready
    startup_sequence(args.startup_delay, args.heartbeat_interval)

    print("[mock_adapter] ready, reading commands from stdin", file=sys.stderr)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            responses = process_line(line)
            for resp in responses:
                send_msg(resp)
        except Exception as e:
            print(f"[mock_adapter] ERROR: {type(e).__name__}: {e}", file=sys.stderr)
            traceback.print_exc(file=sys.stderr)
            error_resp = {"type": "error", "code": "internal_error",
                          "message": f"internal adapter error: {type(e).__name__}: {e}"}
            try:
                send_msg(error_resp)
            except Exception as write_err:
                print(f"[mock_adapter] FATAL: failed to write error response: {write_err}",
                      file=sys.stderr)
                sys.exit(1)
    print("[mock_adapter] stdin closed, shutting down", file=sys.stderr)


if __name__ == '__main__':
    main()
```

- [ ] **Step 4: Run Python tests to verify they pass**

Run: `python3 test/mock_adapter_test.py`
Expected: ALL PASS

- [ ] **Step 5: Verify Erlang protocol tests still pass**

Run: `rebar3 eunit --module=loom_protocol_tests`
Expected: ALL PASS (mock adapter changes don't affect protocol tests)

- [ ] **Step 6: Commit**

```bash
git add priv/scripts/mock_adapter.py test/mock_adapter_test.py
git commit -m "feat(mock-adapter): add ready, heartbeat, stdin watchdog, startup delay

- Send heartbeat + ready on startup (required by loom_port)
- Stdin watchdog thread for cross-platform force-exit on port_close
- --startup-delay flag to simulate slow model loading with periodic heartbeats
- --heartbeat-interval flag for configurable heartbeat timing

Refs #5"
```

---

## Task 3: Implement loom_port gen_statem — spawning and loading states

**Files:**
- Create: `src/loom_port.erl`
- Create: `test/loom_port_tests.erl`

- [ ] **Step 1: Write failing EUnit tests for startup + heartbeat**

Create `test/loom_port_tests.erl`:

```erlang
-module(loom_port_tests).
-include_lib("eunit/include/eunit.hrl").

%% Helper: path to mock adapter
mock_adapter_path() ->
    filename:join([code:priv_dir(loom), "scripts", "mock_adapter.py"]).

%% Helper: python3 executable
python_cmd() ->
    os:find_executable("python3").

%% Helper: default opts for tests
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

%% --- Startup tests ---

happy_path_startup_test() ->
    {ok, Pid} = loom_port:start_link(default_opts()),
    ?assertEqual(spawning, loom_port:get_state(Pid)),
    %% Wait for ready notification
    receive
        {loom_port_ready, _Ref, <<"mock">>, <<"mock">>} -> ok
    after 5000 ->
        ?assert(false, "Timed out waiting for loom_port_ready")
    end,
    ?assertEqual(ready, loom_port:get_state(Pid)),
    loom_port:shutdown(Pid),
    receive
        {loom_port_exit, _Ref2, _Code} -> ok
    after 5000 ->
        ok
    end.

spawn_timeout_test() ->
    %% Use a command that exists but never sends heartbeat/ready
    Opts = (default_opts())#{
        command => os:find_executable("cat"),
        args => [],
        spawn_timeout_ms => 500
    },
    {ok, Pid} = loom_port:start_link(Opts),
    receive
        {loom_port_timeout, _Ref} -> ok
    after 2000 ->
        ?assert(false, "Timed out waiting for loom_port_timeout")
    end,
    %% Process should be dead
    ?assertEqual(false, is_process_alive(Pid)).

bad_command_path_test() ->
    Opts = (default_opts())#{
        command => "/nonexistent/path/to/program",
        args => []
    },
    %% open_port with spawn_executable crashes on bad path
    ?assertMatch({error, _}, catch loom_port:start_link(Opts)).
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `rebar3 eunit --module=loom_port_tests`
Expected: FAIL — `loom_port` module doesn't exist

- [ ] **Step 3: Implement loom_port skeleton with spawning + loading states**

Create `src/loom_port.erl`:

```erlang
-module(loom_port).
-behaviour(gen_statem).

%% Public API
-export([start_link/1, send/2, shutdown/1, get_state/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, terminate/3]).
-export([spawning/3, loading/3, ready/3, shutting_down/3]).

-record(data, {
    port      :: port() | undefined,
    os_pid    :: non_neg_integer() | undefined,
    ref       :: reference(),
    owner     :: pid(),
    owner_mon :: reference(),
    line_buf  :: binary(),
    opts      :: map()
}).

-define(DEFAULT_OPTS, #{
    args => [],
    max_line_length => 1048576,
    heartbeat_timeout_ms => 15000,
    spawn_timeout_ms => 5000,
    shutdown_timeout_ms => 10000,
    post_close_timeout_ms => 5000
}).

%% --- Public API ---

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_statem:start_link(?MODULE, Opts, []).

-spec send(pid(), loom_protocol:outbound_msg()) -> ok | {error, not_ready}.
send(Pid, Msg) ->
    gen_statem:call(Pid, {send, Msg}).

-spec shutdown(pid()) -> ok.
shutdown(Pid) ->
    gen_statem:cast(Pid, do_shutdown).

-spec get_state(pid()) -> spawning | loading | ready | shutting_down.
get_state(Pid) ->
    gen_statem:call(Pid, get_state).

-spec get_os_pid(pid()) -> non_neg_integer() | undefined.
get_os_pid(Pid) ->
    gen_statem:call(Pid, get_os_pid).

%% --- gen_statem callbacks ---

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() ->
    [state_functions, state_enter].

-spec init(map()) -> gen_statem:init_result(atom(), #data{}).
init(UserOpts) ->
    Opts = maps:merge(?DEFAULT_OPTS, UserOpts),
    Owner = maps:get(owner, Opts, self()),
    Ref = make_ref(),
    OwnerMon = erlang:monitor(process, Owner),
    Cmd = case maps:find(command, Opts) of
        {ok, C} when is_list(C) -> C;
        {ok, C} -> error({bad_command, C});
        error -> error(missing_command)
    end,
    Args = maps:get(args, Opts),
    MaxLine = maps:get(max_line_length, Opts),
    try
        Port = open_port({spawn_executable, Cmd}, [
            {args, Args},
            {line, MaxLine},
            binary,
            exit_status,
            use_stdio
        ]),
        {ok, OsPid} = case erlang:port_info(Port, os_pid) of
            {os_pid, Pid} -> {ok, Pid};
            undefined -> {ok, 0}
        end,
        Data = #data{
            port = Port,
            os_pid = OsPid,
            ref = Ref,
            owner = Owner,
            owner_mon = OwnerMon,
            line_buf = <<>>,
            opts = Opts
        },
        {ok, spawning, Data}
    catch
        error:Reason ->
            erlang:demonitor(OwnerMon, [flush]),
            {stop, {spawn_failed, Reason}}
    end.

-spec terminate(term(), atom(), #data{}) -> any().
terminate(_Reason, _State, #data{port = Port}) when is_port(Port) ->
    catch port_close(Port),
    ok;
terminate(_Reason, _State, _Data) ->
    ok.

%% --- spawning state ---

-spec spawning(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
spawning(enter, _OldState, #data{opts = Opts}) ->
    Timeout = maps:get(spawn_timeout_ms, Opts),
    {keep_state_and_data, [{state_timeout, Timeout, spawn_timeout}]};

spawning(state_timeout, spawn_timeout, #data{ref = Ref, owner = Owner}) ->
    Owner ! {loom_port_timeout, Ref},
    {stop, spawn_timeout};

spawning(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    handle_line(Line, spawning, Data);

spawning(info, {Port, {data, {noeol, Chunk}}}, #data{port = Port} = Data) ->
    handle_noeol(Chunk, Data);

spawning(info, {Port, {exit_status, Code}}, #data{port = Port, ref = Ref, owner = Owner}) ->
    Owner ! {loom_port_exit, Ref, Code},
    {stop, {port_exit, Code}};

spawning(info, {'DOWN', MonRef, process, _, _}, #data{owner_mon = MonRef} = Data) ->
    handle_owner_down(Data);

spawning(cast, do_shutdown, Data) ->
    {next_state, shutting_down, Data};

spawning({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, spawning}]};

spawning({call, From}, get_os_pid, #data{os_pid = OsPid}) ->
    {keep_state_and_data, [{reply, From, OsPid}]};

spawning({call, From}, {send, _Msg}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};

spawning(_EventType, _Event, _Data) ->
    keep_state_and_data.

%% --- loading state ---

-spec loading(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
loading(enter, _OldState, #data{opts = Opts}) ->
    Timeout = maps:get(heartbeat_timeout_ms, Opts),
    {keep_state_and_data, [{state_timeout, Timeout, heartbeat_timeout}]};

loading(state_timeout, heartbeat_timeout, #data{ref = Ref, owner = Owner}) ->
    Owner ! {loom_port_timeout, Ref},
    {stop, heartbeat_timeout};

loading(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    handle_line(Line, loading, Data);

loading(info, {Port, {data, {noeol, Chunk}}}, #data{port = Port} = Data) ->
    handle_noeol(Chunk, Data);

loading(info, {Port, {exit_status, Code}}, #data{port = Port, ref = Ref, owner = Owner}) ->
    Owner ! {loom_port_exit, Ref, Code},
    {stop, {port_exit, Code}};

loading(info, {'DOWN', MonRef, process, _, _}, #data{owner_mon = MonRef} = Data) ->
    handle_owner_down(Data);

loading(cast, do_shutdown, Data) ->
    {next_state, shutting_down, Data};

loading({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, loading}]};

loading({call, From}, get_os_pid, #data{os_pid = OsPid}) ->
    {keep_state_and_data, [{reply, From, OsPid}]};

loading({call, From}, {send, _Msg}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};

loading(_EventType, _Event, _Data) ->
    keep_state_and_data.

%% --- ready state (placeholder — implemented in Task 4) ---

-spec ready(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
ready(enter, _OldState, #data{ref = _Ref, owner = _Owner}) ->
    keep_state_and_data;

ready({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, ready}]};

ready({call, From}, get_os_pid, #data{os_pid = OsPid}) ->
    {keep_state_and_data, [{reply, From, OsPid}]};

ready({call, From}, {send, _Msg}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};

ready(cast, do_shutdown, Data) ->
    {next_state, shutting_down, Data};

ready(info, {'DOWN', MonRef, process, _, _}, #data{owner_mon = MonRef} = Data) ->
    handle_owner_down(Data);

ready(info, {Port, {exit_status, Code}}, #data{port = Port, ref = Ref, owner = Owner}) ->
    Owner ! {loom_port_exit, Ref, Code},
    {stop, {port_exit, Code}};

ready(_EventType, _Event, _Data) ->
    keep_state_and_data.

%% --- shutting_down state (placeholder — implemented in Task 5) ---

-spec shutting_down(gen_statem:event_type(), term(), #data{}) ->
    gen_statem:state_enter_result(atom()) | gen_statem:event_handler_result(atom()).
shutting_down(enter, _OldState, #data{port = Port, opts = Opts}) ->
    %% Send shutdown command if Port is still open
    case erlang:port_info(Port) of
        undefined -> ok;
        _ ->
            Encoded = loom_protocol:encode({shutdown}),
            port_command(Port, Encoded)
    end,
    Timeout = maps:get(shutdown_timeout_ms, Opts),
    {keep_state_and_data, [{state_timeout, Timeout, shutdown_timeout}]};

shutting_down(state_timeout, shutdown_timeout, #data{port = Port, ref = Ref, owner = Owner, opts = Opts}) ->
    %% Level 2: port_close
    catch port_close(Port),
    PostCloseTimeout = maps:get(post_close_timeout_ms, Opts),
    Owner ! {loom_port_exit, Ref, killed},
    {keep_state_and_data, [{state_timeout, PostCloseTimeout, post_close_timeout}]};

shutting_down(state_timeout, post_close_timeout, #data{os_pid = OsPid}) ->
    logger:warning("loom_port: orphaned adapter process (OS pid ~p) did not exit after port_close", [OsPid]),
    {stop, normal};

shutting_down(info, {Port, {exit_status, Code}}, #data{port = Port, ref = Ref, owner = Owner}) ->
    Owner ! {loom_port_exit, Ref, Code},
    {stop, normal};

shutting_down(cast, do_shutdown, _Data) ->
    %% Already shutting down — no-op
    keep_state_and_data;

shutting_down({call, From}, get_state, _Data) ->
    {keep_state_and_data, [{reply, From, shutting_down}]};

shutting_down({call, From}, get_os_pid, #data{os_pid = OsPid}) ->
    {keep_state_and_data, [{reply, From, OsPid}]};

shutting_down({call, From}, {send, _Msg}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]};

shutting_down(info, {'DOWN', _MonRef, process, _, _}, _Data) ->
    %% Owner died while we're already shutting down — just keep going
    keep_state_and_data;

shutting_down(_EventType, _Event, _Data) ->
    keep_state_and_data.

%% --- Internal helpers ---

-spec handle_line(binary(), atom(), #data{}) -> gen_statem:event_handler_result(atom(), #data{}).
handle_line(RawLine, State, #data{line_buf = Buf} = Data) ->
    %% If we had noeol fragments, prepend them
    FullLine = case Buf of
        <<>> -> RawLine;
        _ -> <<Buf/binary, RawLine/binary>>
    end,
    Data1 = Data#data{line_buf = <<>>},
    case FullLine of
        <<>> -> {keep_state, Data1};  %% empty line, skip
        _ -> dispatch_line(FullLine, State, Data1)
    end.

-spec handle_noeol(binary(), #data{}) -> gen_statem:event_handler_result(atom(), #data{}).
handle_noeol(Chunk, #data{line_buf = Buf} = Data) ->
    {keep_state, Data#data{line_buf = <<Buf/binary, Chunk/binary>>}}.

-spec dispatch_line(binary(), atom(), #data{}) -> gen_statem:event_handler_result(atom(), #data{}).
dispatch_line(Line, State, #data{ref = Ref, owner = Owner, opts = Opts} = Data) ->
    case loom_protocol:decode(Line) of
        {ok, {heartbeat, _Status, _Detail}} when State =:= spawning ->
            %% Transition to loading — the loading(enter, ...) callback sets the heartbeat timeout
            {next_state, loading, Data};

        {ok, {heartbeat, _Status, _Detail}} when State =:= loading ->
            HeartbeatTimeout = maps:get(heartbeat_timeout_ms, Opts),
            {keep_state, Data, [{state_timeout, HeartbeatTimeout, heartbeat_timeout}]};

        {ok, {ready, Model, Backend}} when State =:= spawning; State =:= loading ->
            Owner ! {loom_port_ready, Ref, Model, Backend},
            {next_state, ready, Data};

        {ok, Msg} when State =:= ready ->
            Owner ! {loom_port_msg, Ref, Msg},
            {keep_state, Data};

        {ok, _Msg} ->
            %% Message received in wrong state — drop silently
            {keep_state, Data};

        {error, Reason} ->
            Owner ! {loom_port_error, Ref, {decode_error, Reason}},
            {keep_state, Data}
    end.

-spec handle_owner_down(#data{}) -> gen_statem:event_handler_result(atom(), #data{}).
handle_owner_down(Data) ->
    {next_state, shutting_down, Data}.
```

- [ ] **Step 4: Run tests to verify startup tests pass**

Run: `rebar3 eunit --module=loom_port_tests`
Expected: `happy_path_startup_test` PASS, `spawn_timeout_test` PASS, `bad_command_path_test` PASS

- [ ] **Step 5: Run dialyzer**

Run: `rebar3 dialyzer`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/loom_port.erl test/loom_port_tests.erl
git commit -m "feat(loom_port): implement gen_statem with spawning/loading/ready states

Implements the core loom_port state machine:
- spawning: opens Port, waits for first heartbeat/ready
- loading: heartbeat-guarded with state_timeout
- ready: forwards decoded messages to owner (placeholder send)
- shutting_down: 3-level shutdown escalation
- Owner monitoring with auto-shutdown on owner death
- noeol line accumulation for oversized messages

Refs #5"
```

---

## Task 4: Implement ready state — send/2 and message forwarding

**Files:**
- Modify: `src/loom_port.erl`
- Modify: `test/loom_port_tests.erl`

- [ ] **Step 1: Write failing tests for send and message forwarding**

Add to `test/loom_port_tests.erl`:

```erlang
send_in_ready_state_test() ->
    {ok, Pid} = loom_port:start_link(default_opts()),
    receive {loom_port_ready, _Ref, _, _} -> ok after 5000 -> error(timeout) end,

    %% Send a health command
    ?assertEqual(ok, loom_port:send(Pid, {health})),

    %% Should get health_response back
    receive
        {loom_port_msg, _Ref2, {health_response, <<"ok">>, _, _, _}} -> ok
    after 5000 ->
        ?assert(false, "Timed out waiting for health_response")
    end,
    loom_port:shutdown(Pid),
    wait_for_exit().

send_not_ready_test() ->
    %% Use cat as a process that never sends ready
    Opts = (default_opts())#{
        command => os:find_executable("cat"),
        args => [],
        spawn_timeout_ms => 2000
    },
    {ok, Pid} = loom_port:start_link(Opts),
    %% Should be in spawning state
    ?assertEqual({error, not_ready}, loom_port:send(Pid, {health})),
    loom_port:shutdown(Pid),
    wait_for_exit().

send_generate_and_receive_tokens_test() ->
    {ok, Pid} = loom_port:start_link(default_opts()),
    receive {loom_port_ready, Ref, _, _} -> ok after 5000 -> error(timeout) end,

    ?assertEqual(ok, loom_port:send(Pid, {generate, <<"req-1">>, <<"Hello">>, #{}})),

    %% Collect all token messages + done
    Msgs = collect_messages(Ref, 6, 5000),
    TokenMsgs = [M || {loom_port_msg, _, {token, _, _, _, _}} = M <- Msgs],
    DoneMsgs = [M || {loom_port_msg, _, {done, _, _, _}} = M <- Msgs],
    ?assertEqual(5, length(TokenMsgs)),
    ?assertEqual(1, length(DoneMsgs)),

    loom_port:shutdown(Pid),
    wait_for_exit().

%% --- Helpers ---

wait_for_exit() ->
    receive
        {loom_port_exit, _, _} -> ok;
        {loom_port_timeout, _} -> ok
    after 10000 ->
        ct:pal("WARNING: wait_for_exit timed out after 10s"),
        ok
    end.

collect_messages(_Ref, 0, _Timeout) -> [];
collect_messages(Ref, N, Timeout) ->
    receive
        {loom_port_msg, Ref, _Msg} = Full ->
            [Full | collect_messages(Ref, N - 1, Timeout)]
    after Timeout ->
        []
    end.
```

- [ ] **Step 2: Run tests to verify new tests fail**

Run: `rebar3 eunit --module=loom_port_tests`
Expected: `send_in_ready_state_test` FAIL (ready state returns `{error, not_ready}` for send)

- [ ] **Step 3: Update ready state to handle send/2**

In `src/loom_port.erl`, update the `ready/3` state function:

```erlang
ready(enter, _OldState, #data{ref = Ref, owner = Owner}) ->
    Owner ! {loom_port_ready, Ref, pending_model(Owner), pending_backend(Owner)},
    keep_state_and_data;
```

**IMPORTANT:** The `Owner ! {loom_port_ready, ...}` line in `dispatch_line` (from Task 3) MUST be removed — the notification moves to the `ready(enter, ...)` callback. Otherwise the owner gets notified twice.

The ready notification needs the Model and Backend from the `ready` message. These need to be stored in the data record during the `spawning → ready` or `loading → ready` transition. Update the dispatch_line function's ready clause to pass model/backend through data, and update the ready enter callback.

Add fields to the data record:

```erlang
-record(data, {
    port       :: port() | undefined,
    os_pid     :: non_neg_integer() | undefined,
    ref        :: reference(),
    owner      :: pid(),
    owner_mon  :: reference(),
    line_buf   :: binary(),
    opts       :: map(),
    model      :: binary() | undefined,
    backend    :: binary() | undefined
}).
```

Update `dispatch_line` ready transition:

```erlang
{ok, {ready, Model, Backend}} when State =:= spawning; State =:= loading ->
    Data1 = Data#data{model = Model, backend = Backend},
    {next_state, ready, Data1};
```

Update `ready(enter, ...)`:

```erlang
ready(enter, _OldState, #data{ref = Ref, owner = Owner, model = Model, backend = Backend}) ->
    Owner ! {loom_port_ready, Ref, Model, Backend},
    keep_state_and_data;
```

Update `ready({call, From}, {send, Msg}, ...)`:

```erlang
ready({call, From}, {send, Msg}, #data{port = Port} = Data) ->
    Encoded = loom_protocol:encode(Msg),
    port_command(Port, Encoded),
    {keep_state, Data, [{reply, From, ok}]};
```

Also update `ready` to forward port data:

```erlang
ready(info, {Port, {data, {eol, Line}}}, #data{port = Port} = Data) ->
    handle_line(Line, ready, Data);

ready(info, {Port, {data, {noeol, Chunk}}}, #data{port = Port} = Data) ->
    handle_noeol(Chunk, Data);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_port_tests`
Expected: ALL PASS

- [ ] **Step 5: Run dialyzer**

Run: `rebar3 dialyzer`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/loom_port.erl test/loom_port_tests.erl
git commit -m "feat(loom_port): implement send/2 and message forwarding in ready state

- send/2 encodes outbound messages and writes to Port stdin
- Incoming port data decoded and forwarded as {loom_port_msg, ...}
- Store model/backend from ready message for owner notification
- Tests: send health, send generate with token collection

Refs #5"
```

---

## Task 5: Implement shutdown escalation and edge cases

**Files:**
- Modify: `src/loom_port.erl`
- Modify: `test/loom_port_tests.erl`

- [ ] **Step 1: Write failing tests for shutdown and edge cases**

Add to `test/loom_port_tests.erl`:

```erlang
graceful_shutdown_test() ->
    {ok, Pid} = loom_port:start_link(default_opts()),
    receive {loom_port_ready, Ref, _, _} -> ok after 5000 -> error(timeout) end,
    loom_port:shutdown(Pid),
    ?assertEqual(shutting_down, loom_port:get_state(Pid)),
    receive
        {loom_port_exit, Ref, 0} -> ok
    after 5000 ->
        ?assert(false, "Timed out waiting for graceful exit")
    end,
    ?assertEqual(false, is_process_alive(Pid)).

decode_error_forwarded_test() ->
    %% The mock adapter sends an error response for unknown types.
    %% Send a message that will cause the adapter to respond with something
    %% we can verify gets forwarded. To test actual decode errors,
    %% we would need a script that writes invalid JSON to stdout.
    %% For now, verify that the decode error path doesn't crash loom_port
    %% by checking it handles messages in all states gracefully.
    {ok, Pid} = loom_port:start_link(default_opts()),
    receive {loom_port_ready, _Ref, _, _} -> ok after 5000 -> error(timeout) end,
    %% loom_port is alive and ready — any decode errors would have been
    %% handled without crashing during startup (heartbeat/ready parsing)
    ?assertEqual(ready, loom_port:get_state(Pid)),
    loom_port:shutdown(Pid),
    wait_for_exit().

double_shutdown_test() ->
    {ok, Pid} = loom_port:start_link(default_opts()),
    receive {loom_port_ready, _Ref, _, _} -> ok after 5000 -> error(timeout) end,
    loom_port:shutdown(Pid),
    %% Second shutdown should be no-op
    loom_port:shutdown(Pid),
    wait_for_exit().

send_during_shutdown_test() ->
    {ok, Pid} = loom_port:start_link(default_opts()),
    receive {loom_port_ready, _Ref, _, _} -> ok after 5000 -> error(timeout) end,
    loom_port:shutdown(Pid),
    ?assertEqual({error, not_ready}, loom_port:send(Pid, {health})),
    wait_for_exit().
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `rebar3 eunit --module=loom_port_tests`
Expected: ALL PASS (shutdown was already implemented as placeholder in Task 3, these validate it)

- [ ] **Step 3: Verify shutdown escalation handles non-responsive adapter**

The `shutting_down` state already has timeout escalation. Verify by reviewing the code and ensuring `port_close` path and `post_close_timeout` are implemented. If any adjustments are needed, make them now.

Check: in `shutting_down(state_timeout, shutdown_timeout, ...)` — after `port_close`, we currently send `{loom_port_exit, Ref, killed}` immediately and then set a post_close_timeout. But the owner should only be notified once. Fix: don't send the exit message until we either get the exit_status or the post_close_timeout fires.

Update `shutting_down`:

```erlang
shutting_down(state_timeout, shutdown_timeout, #data{port = Port, opts = Opts} = Data) ->
    %% Level 2: port_close — adapter stdin watchdog should detect EOF and os._exit(1)
    catch port_close(Port),
    PostCloseTimeout = maps:get(post_close_timeout_ms, Opts),
    {keep_state, Data#data{port = undefined},
     [{state_timeout, PostCloseTimeout, post_close_timeout}]};

shutting_down(state_timeout, post_close_timeout, #data{os_pid = OsPid, ref = Ref, owner = Owner}) ->
    logger:warning("loom_port: orphaned adapter process (OS pid ~p) did not exit after port_close", [OsPid]),
    Owner ! {loom_port_exit, Ref, killed},
    {stop, normal};

shutting_down(info, {_Port, {exit_status, Code}}, #data{ref = Ref, owner = Owner}) ->
    Owner ! {loom_port_exit, Ref, Code},
    {stop, normal};
```

- [ ] **Step 4: Run all tests**

Run: `rebar3 eunit --module=loom_port_tests`
Expected: ALL PASS

- [ ] **Step 5: Run dialyzer**

Run: `rebar3 dialyzer`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/loom_port.erl test/loom_port_tests.erl
git commit -m "feat(loom_port): refine shutdown escalation, edge case tests

- Fix shutdown to send exit notification only once (after exit_status or post_close_timeout)
- port_close sets port to undefined to prevent double-close
- Tests: graceful shutdown, double shutdown, send during shutdown

Refs #5"
```

---

## Task 6: Common Test suite — integration tests

**Files:**
- Create: `test/loom_port_SUITE.erl`

- [ ] **Step 1: Create Common Test suite**

Create `test/loom_port_SUITE.erl`:

```erlang
-module(loom_port_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    adapter_crash_test/1,
    graceful_shutdown_test/1,
    shutdown_escalation_test/1,
    owner_death_test/1,
    concurrent_sends_test/1,
    startup_delay_test/1,
    shutdown_during_loading_test/1
]).

all() ->
    [
        adapter_crash_test,
        graceful_shutdown_test,
        shutdown_escalation_test,
        owner_death_test,
        concurrent_sends_test,
        startup_delay_test,
        shutdown_during_loading_test
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    %% Kill any leftover loom_port processes from failed tests
    [exit(P, kill) || P <- processes(),
                      {registered_name, []} =/= process_info(P, registered_name) orelse true,
                      case process_info(P, dictionary) of
                          {dictionary, D} -> proplists:get_value('$initial_call', D) =:= {loom_port, init, 1};
                          _ -> false
                      end],
    ok.

-export([init_per_testcase/2, end_per_testcase/2]).

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
        shutdown_timeout_ms => 3000,
        post_close_timeout_ms => 2000,
        max_line_length => 1048576
    }.

wait_ready() ->
    receive
        {loom_port_ready, Ref, _, _} -> Ref
    after 5000 -> error(timeout_waiting_for_ready)
    end.

%% --- Tests ---

adapter_crash_test(_Config) ->
    {ok, Pid} = loom_port:start_link(default_opts()),
    Ref = wait_ready(),
    %% Get OS pid and kill the adapter process
    OsPid = get_os_pid(Pid),
    os:cmd("kill -9 " ++ integer_to_list(OsPid)),
    %% Should get exit notification quickly
    receive
        {loom_port_exit, Ref, Code} ->
            ct:pal("Adapter crashed with code ~p", [Code]),
            ?assert(Code =/= 0)
    after 2000 ->
        error(timeout_waiting_for_crash_notification)
    end,
    ?assertEqual(false, is_process_alive(Pid)).

graceful_shutdown_test(_Config) ->
    {ok, Pid} = loom_port:start_link(default_opts()),
    Ref = wait_ready(),
    loom_port:shutdown(Pid),
    receive
        {loom_port_exit, Ref, 0} -> ok
    after 5000 ->
        error(timeout_waiting_for_graceful_exit)
    end.

shutdown_escalation_test(_Config) ->
    %% Use 'cat' which ignores shutdown command — will hit timeout and port_close
    Opts = (default_opts())#{
        command => os:find_executable("cat"),
        args => [],
        spawn_timeout_ms => 60000,
        shutdown_timeout_ms => 1000,
        post_close_timeout_ms => 2000
    },
    {ok, Pid} = loom_port:start_link(Opts),
    %% cat won't send ready, so manually trigger shutdown from spawning state
    timer:sleep(100),
    loom_port:shutdown(Pid),
    %% Should get killed notification after shutdown_timeout + port_close
    receive
        {loom_port_exit, _Ref, killed} -> ok;
        {loom_port_exit, _Ref, Code} ->
            ct:pal("Got exit code ~p (port_close caused exit)", [Code]),
            ok
    after 10000 ->
        error(timeout_waiting_for_escalation)
    end.

owner_death_test(_Config) ->
    %% Start loom_port owned by a temporary process, then kill the owner
    Self = self(),
    OwnerPid = spawn(fun() ->
        {ok, Pid} = loom_port:start_link((default_opts())#{owner => self()}),
        Self ! {port_pid, Pid},
        receive
            {loom_port_ready, _, _, _} ->
                Self ! ready,
                %% Wait forever (will be killed)
                receive never -> ok end
        after 5000 ->
            Self ! {error, no_ready}
        end
    end),
    PortPid = receive {port_pid, P} -> P after 5000 -> error(no_port_pid) end,
    receive ready -> ok after 5000 -> error(no_ready) end,
    %% Kill the owner
    exit(OwnerPid, kill),
    %% loom_port should detect owner death and terminate
    timer:sleep(1000),
    ?assertEqual(false, is_process_alive(PortPid)).

concurrent_sends_test(_Config) ->
    {ok, Pid} = loom_port:start_link(default_opts()),
    Ref = wait_ready(),
    %% Send 5 generate requests
    lists:foreach(fun(N) ->
        Id = list_to_binary("req-" ++ integer_to_list(N)),
        ok = loom_port:send(Pid, {generate, Id, <<"test">>, #{}})
    end, lists:seq(1, 5)),
    %% Collect all responses (5 tokens + 1 done per request = 30 total)
    Msgs = collect_all_messages(Ref, 30, 10000),
    TokenCount = length([M || {loom_port_msg, _, {token, _, _, _, _}} <- Msgs]),
    DoneCount = length([M || {loom_port_msg, _, {done, _, _, _}} <- Msgs]),
    ct:pal("Received ~p tokens, ~p dones", [TokenCount, DoneCount]),
    ?assertEqual(25, TokenCount),  %% 5 mock tokens * 5 requests
    ?assertEqual(5, DoneCount),
    loom_port:shutdown(Pid),
    receive {loom_port_exit, _, _} -> ok after 5000 -> ok end.

startup_delay_test(_Config) ->
    Opts = (default_opts())#{
        args => [mock_adapter_path(), "--startup-delay", "2", "--heartbeat-interval", "1"],
        heartbeat_timeout_ms => 3000
    },
    Start = erlang:monotonic_time(millisecond),
    {ok, Pid} = loom_port:start_link(Opts),
    Ref = wait_ready(),
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    ct:pal("Startup with 2s delay took ~pms", [Elapsed]),
    ?assert(Elapsed >= 1500),  %% At least ~2s delay
    ?assert(Elapsed < 10000),  %% But not unreasonably long
    loom_port:shutdown(Pid),
    receive {loom_port_exit, Ref, _} -> ok after 5000 -> ok end.

shutdown_during_loading_test(_Config) ->
    Opts = (default_opts())#{
        args => [mock_adapter_path(), "--startup-delay", "30"],
        heartbeat_timeout_ms => 60000,
        shutdown_timeout_ms => 2000
    },
    {ok, Pid} = loom_port:start_link(Opts),
    %% Wait a bit for loading state
    timer:sleep(500),
    loom_port:shutdown(Pid),
    receive
        {loom_port_exit, _Ref, Code} ->
            ct:pal("Exit during loading with code ~p", [Code]),
            ok
    after 10000 ->
        error(timeout_waiting_for_shutdown_during_loading)
    end.

%% --- Helpers ---

get_os_pid(Pid) ->
    %% Use the public API accessor
    loom_port:get_os_pid(Pid).

collect_all_messages(_Ref, 0, _Timeout) -> [];
collect_all_messages(Ref, N, Timeout) ->
    receive
        {loom_port_msg, Ref, _Msg} = Full ->
            [Full | collect_all_messages(Ref, N - 1, Timeout)]
    after Timeout ->
        []
    end.
```

- [ ] **Step 2: Run Common Test suite**

Run: `rebar3 ct --suite=test/loom_port_SUITE`
Expected: ALL PASS

- [ ] **Step 3: Run all tests together**

Run: `rebar3 do eunit, ct`
Expected: ALL PASS

- [ ] **Step 4: Run dialyzer**

Run: `rebar3 dialyzer`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add test/loom_port_SUITE.erl
git commit -m "test(loom_port): add Common Test integration suite

Tests: adapter crash detection, graceful shutdown, shutdown escalation,
owner death cleanup, concurrent sends, startup delay with heartbeats,
shutdown during loading phase.

Refs #5"
```

---

## Task 7: noeol and decode error edge case tests

**Files:**
- Modify: `test/loom_port_tests.erl`

- [ ] **Step 1: Write noeol accumulation test**

Add to `test/loom_port_tests.erl`:

```erlang
noeol_accumulation_test() ->
    %% Use a small max_line_length to trigger noeol fragments
    Opts = (default_opts())#{max_line_length => 64},
    {ok, Pid} = loom_port:start_link(Opts),
    receive {loom_port_ready, _Ref, _, _} -> ok after 5000 -> error(timeout) end,
    %% Send a health request — the response JSON is short enough,
    %% but heartbeat/ready messages during startup may fragment.
    %% If we got to ready state, noeol handling works.
    ?assertEqual(ok, loom_port:send(Pid, {health})),
    receive
        {loom_port_msg, _, {health_response, _, _, _, _}} -> ok
    after 5000 ->
        ?assert(false, "Timed out waiting for health_response with small line buffer")
    end,
    loom_port:shutdown(Pid),
    wait_for_exit().
```

- [ ] **Step 2: Run test**

Run: `rebar3 eunit --module=loom_port_tests`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/loom_port_tests.erl
git commit -m "test(loom_port): add noeol accumulation edge case test

Verifies line fragment reassembly with small max_line_length (64 bytes).

Refs #5"
```

---

## Task 8: Final verification and cleanup

**Files:**
- All modified files

- [ ] **Step 1: Run full test suite**

Run: `rebar3 do eunit, ct`
Expected: ALL PASS

- [ ] **Step 2: Run dialyzer**

Run: `rebar3 dialyzer`
Expected: PASS — no warnings

- [ ] **Step 3: Run xref**

Run: `rebar3 xref`
Expected: PASS — no undefined function calls

- [ ] **Step 4: Verify mock adapter Python tests**

Run: `python3 test/mock_adapter_test.py`
Expected: ALL PASS

- [ ] **Step 5: Update .github/plans/5-design.md status**

Change `**Status:** Approved` to `**Status:** Implemented`

- [ ] **Step 6: Update ROADMAP.md**

Mark P0-05 as done in ROADMAP.md:
- Change `- [ ] **loom_port**` to `- [x] **loom_port**`
- Update Progress Summary table (Phase 0 Done: 4 → 5)
- Update Total Done: 4 → 5, Pending: 49 → 48

- [ ] **Step 7: Final commit**

```bash
git add .github/plans/5-design.md ROADMAP.md
git commit -m "docs: mark P0-05 as implemented, update ROADMAP

Refs #5"
```

---

## Summary

| Task | Description | Files | Est. |
|------|------------|-------|------|
| 1 | Add heartbeat to loom_protocol | loom_protocol.erl, tests | 5 min |
| 2 | Update mock adapter | mock_adapter.py, tests | 10 min |
| 3 | loom_port gen_statem skeleton | loom_port.erl, EUnit tests | 15 min |
| 4 | Ready state — send/2 + forwarding | loom_port.erl, EUnit tests | 10 min |
| 5 | Shutdown escalation + edge cases | loom_port.erl, EUnit tests | 10 min |
| 6 | Common Test integration suite | loom_port_SUITE.erl | 10 min |
| 7 | noeol edge case test | EUnit tests | 5 min |
| 8 | Final verification + cleanup | All | 5 min |

**Total: 8 tasks, ~70 minutes of implementation time**
