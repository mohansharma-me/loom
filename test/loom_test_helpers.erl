-module(loom_test_helpers).

%% ASSUMPTION: This module is compiled only under the test profile.
%% It depends on loom_json and loom_config from the main application.

-export([
    start_app/0,
    start_app/1,
    stop_app/0,
    wait_for_status/3,
    wait_for_status/4,
    fixture_path/1,
    write_temp_config/1,
    flush_mailbox/0,
    with_config/2,
    capture_log/1
]).

%% Logger handler callback (for capture_log)
-export([log/2]).

-include_lib("kernel/include/logger.hrl").

%% @doc Start the loom application with a minimal test config pre-loaded.
%% Loads the given config file (or default minimal fixture) into ETS
%% before starting loom, so loom_app:start/2 skips file-based loading.
-spec start_app() -> ok.
start_app() ->
    start_app(fixture_path("minimal.json")).

-spec start_app(file:filename()) -> ok.
start_app(ConfigPath) ->
    ok = loom_config:load(ConfigPath),
    {ok, _} = application:ensure_all_started(loom),
    ok.

%% @doc Stop the loom application and clean up ETS tables.
-spec stop_app() -> ok.
stop_app() ->
    _ = application:stop(loom),
    _ = application:stop(cowboy),
    cleanup_ets(),
    ok.

%% @doc Poll a function until it returns the expected value, or timeout.
%% Fun is a zero-arity function that returns the current value.
-spec wait_for_status(fun(() -> term()), term(), pos_integer()) ->
    ok | {error, timeout}.
wait_for_status(Fun, Expected, TimeoutMs) ->
    wait_for_status(Fun, Expected, TimeoutMs, 50).

-spec wait_for_status(fun(() -> term()), term(), pos_integer(), pos_integer()) ->
    ok | {error, timeout}.
wait_for_status(Fun, Expected, TimeoutMs, IntervalMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(Fun, Expected, Deadline, IntervalMs).

%% @doc Resolve a fixture path relative to the test fixtures directory.
-spec fixture_path(string()) -> string().
fixture_path(Filename) ->
    %% ASSUMPTION: Tests are run from the project root via rebar3.
    %% The fixtures directory is at test/fixtures/.
    filename:join(["test", "fixtures", Filename]).

%% @doc Write a temporary JSON config file and return its path.
%% The file is written to /tmp with a unique name.
-spec write_temp_config(map()) -> {ok, file:filename()}.
write_temp_config(ConfigMap) ->
    TmpDir = filename:join(["/tmp", "loom_test"]),
    ok = filelib:ensure_dir(filename:join(TmpDir, ".")),
    Name = iolist_to_binary(io_lib:format("loom_test_~b.json",
        [erlang:unique_integer([positive])])),
    Path = filename:join(TmpDir, binary_to_list(Name)),
    Json = loom_json:encode(ConfigMap),
    ok = file:write_file(Path, Json),
    {ok, Path}.

%% @doc Drain all messages from the calling process mailbox.
-spec flush_mailbox() -> ok.
flush_mailbox() ->
    receive _ -> flush_mailbox()
    after 0 -> ok
    end.

%% @doc Run a fun with a temporary config loaded, then clean up.
-spec with_config(map(), fun(() -> term())) -> term().
with_config(ConfigMap, Fun) ->
    {ok, Path} = write_temp_config(ConfigMap),
    cleanup_ets(),
    try
        ok = loom_config:load(Path),
        Fun()
    after
        cleanup_ets(),
        file:delete(Path)
    end.

%% @doc Capture log events emitted during Fun execution.
%% Returns {Result, [LogEvent]} where LogEvent is the logger event map.
-spec capture_log(fun(() -> term())) -> {term(), [map()]}.
capture_log(Fun) ->
    Self = self(),
    HandlerId = list_to_atom("test_log_capture_" ++
        integer_to_list(erlang:unique_integer([positive]))),
    ok = logger:add_handler(HandlerId, ?MODULE, #{
        level => all,
        filter_default => log,
        config => #{pid => Self}
    }),
    try
        Result = Fun(),
        Events = collect_log_events(),
        {Result, Events}
    after
        logger:remove_handler(HandlerId)
    end.

%% Logger handler callback
log(#{msg := _} = Event, #{config := #{pid := Pid}}) ->
    Pid ! {captured_log, Event},
    ok;
log(_Event, _Config) ->
    ok.

%%% Internal

-spec cleanup_ets() -> ok.
cleanup_ets() ->
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    ok.

-spec wait_loop(fun(() -> term()), term(), integer(), pos_integer()) ->
    ok | {error, timeout}.
wait_loop(Fun, Expected, Deadline, IntervalMs) ->
    case Fun() of
        Expected -> ok;
        _Other ->
            Now = erlang:monotonic_time(millisecond),
            case Now >= Deadline of
                true -> {error, timeout};
                false ->
                    timer:sleep(IntervalMs),
                    wait_loop(Fun, Expected, Deadline, IntervalMs)
            end
    end.

-spec collect_log_events() -> [map()].
collect_log_events() ->
    collect_log_events([]).

collect_log_events(Acc) ->
    receive
        {captured_log, Event} -> collect_log_events([Event | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.
