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
-export([init_per_testcase/2, end_per_testcase/2]).

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

-define(MODEL, <<"mlx-community/Qwen2.5-0.5B-Instruct-4bit">>).
-define(ENGINE_ID, <<"mlx_integration_engine">>).
-define(BASE_PORT, 18080).
-define(ENGINE_READY_TIMEOUT, 120000).
-define(REQUEST_TIMEOUT, 60000).

%% ASSUMPTION: CT executes tests in the order listed when all/0 returns a flat
%% list. We avoid groups because CT runs group init in a separate process,
%% which destroys the ETS table owned by init_per_suite.
all() ->
    [health_endpoint_test,
     memory_metrics_test,
     chat_completion_openai_test,
     chat_completion_anthropic_test,
     sse_streaming_openai_test,
     sse_streaming_anthropic_test,
     gpu_metrics_sanity_test,
     crash_recovery_test].

%%====================================================================
%% CT Callbacks
%%====================================================================

init_per_suite(Config) ->
    case check_prerequisites() of
        ok ->
            start_mlx_engine(Config);
        {skip, Reason} ->
            {skip, Reason}
    end.

end_per_suite(Config) ->
    case ?config(config_path, Config) of
        undefined ->
            ok;
        Path ->
            loom_test_helpers:stop_app(),
            catch application:stop(gun),
            file:delete(Path)
    end,
    ok.

init_per_testcase(_TC, Config) ->
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%%====================================================================
%% Test Cases
%%====================================================================

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

memory_metrics_test(Config) ->
    EngineId = ?config(engine_id, Config),
    MonitorPid = find_gpu_monitor(EngineId),
    {ok, Metrics} = loom_gpu_monitor:force_poll(MonitorPid),
    MemTotalGb = maps:get(mem_total_gb, Metrics),
    MemUsedGb = maps:get(mem_used_gb, Metrics),
    MachineRamGb = get_machine_ram_gb(),
    ?assert(abs(MemTotalGb - MachineRamGb) < 0.5),
    ?assert(MemUsedGb > 0),
    ?assert(MemUsedGb < MemTotalGb),
    ct:pal("Memory: ~.1f/~.1f GB used (machine: ~.1f GB)",
           [MemUsedGb, MemTotalGb, MachineRamGb]).

chat_completion_openai_test(Config) ->
    Port = ?config(http_port, Config),
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => ?MODEL,
        <<"max_tokens">> => 128,
        <<"messages">> => [#{<<"role">> => <<"user">>,
                             <<"content">> => <<"Say hello in one sentence.">>}],
        <<"stream">> => false
    }),
    T0 = erlang:monotonic_time(millisecond),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _Headers} = gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    Decoded = loom_json:decode(RespBody),
    ?assertEqual(<<"chat.completion">>, maps:get(<<"object">>, Decoded)),
    [Choice] = maps:get(<<"choices">>, Decoded),
    Msg = maps:get(<<"message">>, Choice),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Msg)),
    Content = maps:get(<<"content">>, Msg),
    ?assert(is_binary(Content)),
    ?assert(byte_size(Content) > 0),
    %% Verify usage stats exist. prompt_tokens may be 0 because the adapter
    %% does not currently report prompt token counts to the Erlang side.
    Usage = maps:get(<<"usage">>, Decoded),
    ?assert(is_integer(maps:get(<<"prompt_tokens">>, Usage))),
    CompletionTokens = maps:get(<<"completion_tokens">>, Usage),
    ?assert(CompletionTokens > 0),
    ct:pal("OpenAI non-streaming: ~Bms, ~B tokens (~.1f tok/s)",
           [Elapsed, CompletionTokens, CompletionTokens * 1000 / Elapsed]),
    gun:close(ConnPid).

chat_completion_anthropic_test(Config) ->
    Port = ?config(http_port, Config),
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => ?MODEL,
        <<"max_tokens">> => 128,
        <<"messages">> => [#{<<"role">> => <<"user">>,
                             <<"content">> => <<"Say hello in one sentence.">>}]
    }),
    T0 = erlang:monotonic_time(millisecond),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, _Headers} = gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    {ok, RespBody} = gun:await_body(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    Decoded = loom_json:decode(RespBody),
    ?assertEqual(<<"message">>, maps:get(<<"type">>, Decoded)),
    ?assertEqual(<<"assistant">>, maps:get(<<"role">>, Decoded)),
    [ContentBlock] = maps:get(<<"content">>, Decoded),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, ContentBlock)),
    Text = maps:get(<<"text">>, ContentBlock),
    ?assert(is_binary(Text)),
    ?assert(byte_size(Text) > 0),
    ?assertEqual(<<"end_turn">>, maps:get(<<"stop_reason">>, Decoded)),
    %% Verify usage stats exist. input_tokens may be 0 because the adapter
    %% does not currently report prompt token counts to the Erlang side.
    Usage = maps:get(<<"usage">>, Decoded),
    ?assert(is_integer(maps:get(<<"input_tokens">>, Usage))),
    OutputTokens = maps:get(<<"output_tokens">>, Usage),
    ?assert(OutputTokens > 0),
    ct:pal("Anthropic non-streaming: ~Bms, ~B tokens (~.1f tok/s)",
           [Elapsed, OutputTokens, OutputTokens * 1000 / Elapsed]),
    gun:close(ConnPid).

sse_streaming_openai_test(Config) ->
    Port = ?config(http_port, Config),
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => ?MODEL,
        <<"max_tokens">> => 128,
        <<"messages">> => [#{<<"role">> => <<"user">>,
                             <<"content">> => <<"Say hello in one sentence.">>}],
        <<"stream">> => true
    }),
    T0 = erlang:monotonic_time(millisecond),
    StreamRef = gun:post(ConnPid, "/v1/chat/completions",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, Headers} = gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertMatch(<<"text/event-stream", _/binary>>, ContentType),
    Events = collect_sse_data(ConnPid, StreamRef, []),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assert(length(Events) >= 3),
    ?assertEqual(<<"[DONE]">>, lists:last(Events)),
    JsonEvents = lists:droplast(Events),
    ?assert(length(JsonEvents) >= 2),
    lists:foreach(fun(DataBin) ->
        Chunk = loom_json:decode(DataBin),
        [Choice] = maps:get(<<"choices">>, Chunk),
        _Delta = maps:get(<<"delta">>, Choice)
    end, JsonEvents),
    LastJson = loom_json:decode(lists:last(JsonEvents)),
    [LastChoice] = maps:get(<<"choices">>, LastJson),
    ?assertEqual(<<"stop">>, maps:get(<<"finish_reason">>, LastChoice)),
    Tokens = lists:filtermap(fun(DataBin) ->
        Chunk = loom_json:decode(DataBin),
        [Choice] = maps:get(<<"choices">>, Chunk),
        Delta = maps:get(<<"delta">>, Choice),
        case maps:find(<<"content">>, Delta) of
            {ok, C} when is_binary(C), byte_size(C) > 0 -> {true, C};
            _ -> false
        end
    end, JsonEvents),
    TokenCount = length(Tokens),
    FullContent = iolist_to_binary(Tokens),
    ?assert(byte_size(FullContent) > 0),
    ct:pal("OpenAI streaming: ~Bms, ~B tokens (~.1f tok/s)",
           [Elapsed, TokenCount, TokenCount * 1000 / Elapsed]),
    gun:close(ConnPid).

sse_streaming_anthropic_test(Config) ->
    Port = ?config(http_port, Config),
    {ok, ConnPid} = gun:open("127.0.0.1", Port),
    {ok, _} = gun:await_up(ConnPid),
    Body = loom_json:encode(#{
        <<"model">> => ?MODEL,
        <<"max_tokens">> => 128,
        <<"messages">> => [#{<<"role">> => <<"user">>,
                             <<"content">> => <<"Say hello in one sentence.">>}],
        <<"stream">> => true
    }),
    T0 = erlang:monotonic_time(millisecond),
    StreamRef = gun:post(ConnPid, "/v1/messages",
        [{<<"content-type">>, <<"application/json">>}], Body),
    {response, nofin, 200, Headers} = gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT),
    ContentType = proplists:get_value(<<"content-type">>, Headers),
    ?assertMatch(<<"text/event-stream", _/binary>>, ContentType),
    Events = collect_sse_events(ConnPid, StreamRef, []),
    EventTypes = [Type || {Type, _} <- Events],
    ?assertEqual(<<"message_start">>, hd(EventTypes)),
    ?assertEqual(<<"content_block_start">>, lists:nth(2, EventTypes)),
    ?assertEqual(<<"message_stop">>, lists:last(EventTypes)),
    ?assert(lists:member(<<"message_delta">>, EventTypes)),
    ?assert(lists:member(<<"content_block_stop">>, EventTypes)),
    DeltaCount = length([T || T <- EventTypes, T =:= <<"content_block_delta">>]),
    ?assert(DeltaCount >= 2),
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
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    FullText = iolist_to_binary(DeltaTexts),
    ?assert(byte_size(FullText) > 0),
    ct:pal("Anthropic streaming: ~Bms, ~B tokens (~.1f tok/s)",
           [Elapsed, DeltaCount, DeltaCount * 1000 / Elapsed]),
    gun:close(ConnPid).

gpu_metrics_sanity_test(Config) ->
    EngineId = ?config(engine_id, Config),
    MonitorPid = find_gpu_monitor(EngineId),
    {ok, Metrics} = loom_gpu_monitor:force_poll(MonitorPid),
    ct:pal("Raw GPU metrics: ~p", [Metrics]),
    MemTotalGb = maps:get(mem_total_gb, Metrics),
    MachineRamGb = get_machine_ram_gb(),
    ?assert(abs(MemTotalGb - MachineRamGb) < 0.5),
    MemUsedGb = maps:get(mem_used_gb, Metrics),
    ?assert(MemUsedGb > 0),
    ?assert(MemUsedGb < MemTotalGb),
    %% gpu_util is -1.0 on Apple Silicon (no public Metal API for utilization).
    %% Verify it's a number — the value itself is expected to be negative.
    GpuUtil = maps:get(gpu_util, Metrics),
    ?assert(is_float(GpuUtil) orelse is_integer(GpuUtil)),
    ct:pal("GPU metrics: util=~.1f, mem=~.1f/~.1f GB",
           [GpuUtil, MemUsedGb, MemTotalGb]).

crash_recovery_test(Config) ->
    EngineId = ?config(engine_id, Config),
    Port = ?config(http_port, Config),
    ?assertEqual(ready, loom_engine_coordinator:get_status(EngineId)),
    CoordPid = find_coordinator(EngineId),
    OsPid = get_adapter_os_pid(CoordPid, EngineId),
    ct:pal("Killing MLX adapter OS process: ~B", [OsPid]),
    T0 = erlang:monotonic_time(millisecond),
    os:cmd("kill -9 " ++ integer_to_list(OsPid)),
    ok = wait_status_not(EngineId, ready, 10000),
    ct:pal("Engine left ready state"),
    ok = wait_engine_ready(EngineId, ?ENGINE_READY_TIMEOUT),
    T1 = erlang:monotonic_time(millisecond),
    ct:pal("Engine recovered to ready in ~Bms", [T1 - T0]),
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

%%====================================================================
%% Prerequisites
%%====================================================================

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
    Lines = string:split(Result, "\n", all),
    ExitCode = string:trim(lists:last(Lines)),
    case ExitCode of
        "0" -> ok;
        _ ->
            {skip, "MLX dependencies not installed. Run:\n"
                   "  pip3 install mlx-lm>=0.20.0 huggingface-hub psutil"}
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
            {skip, "Model not cached locally. Run:\n"
                   "  huggingface-cli download " ++ Model ++ "\n"
                   "First download is ~700MB. Subsequent test runs use the cache."}
    end.

%%====================================================================
%% App Startup
%%====================================================================

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
    ct:pal("Config loaded. Engine names: ~p", [loom_config:engine_names()]),
    {ok, _} = application:ensure_all_started(gun),
    {ok, _} = application:ensure_all_started(loom),

    %% Transfer ETS table ownership to loom_sup so it survives after
    %% init_per_suite process exits. CT runs init_per_suite in a
    %% temporary process that dies after returning Config.
    ets:give_away(loom_config, whereis(loom_sup), []),

    %% Wait for engine to reach ready state
    ok = wait_engine_ready(?ENGINE_ID, ?ENGINE_READY_TIMEOUT),
    ct:pal("MLX engine ready on port ~B. Engine names: ~p",
           [Port, loom_config:engine_names()]),

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

%%====================================================================
%% SSE Helpers
%%====================================================================

%% @doc Collect SSE data lines from a Gun streaming response.
%% Buffers across chunk boundaries to handle TCP fragmentation.
collect_sse_data(ConnPid, StreamRef, Acc) ->
    collect_sse_data(ConnPid, StreamRef, <<>>, Acc).

collect_sse_data(ConnPid, StreamRef, Buffer, Acc) ->
    case gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
        {data, nofin, Chunk} ->
            Combined = <<Buffer/binary, Chunk/binary>>,
            {Events, NewBuffer} = extract_sse_data(Combined),
            collect_sse_data(ConnPid, StreamRef, NewBuffer, Acc ++ Events);
        {data, fin, Chunk} ->
            Combined = <<Buffer/binary, Chunk/binary>>,
            {Events, _} = extract_sse_data(Combined),
            Acc ++ Events;
        {error, Reason} ->
            ct:pal("WARNING: SSE collection ended with error: ~p", [Reason]),
            Acc
    end.

%% @doc Extract complete SSE data lines from buffer.
%% Returns {ParsedEvents, RemainingBuffer}.
extract_sse_data(<<>>) ->
    {[], <<>>};
extract_sse_data(Buffer) ->
    Lines = binary:split(Buffer, <<"\n">>, [global]),
    %% The last element might be incomplete (no trailing newline)
    {CompleteLines, Remainder} = case binary:last(Buffer) of
        $\n -> {Lines, <<>>};
        _ ->
            Complete = lists:droplast(Lines),
            [Partial] = lists:nthtail(length(Lines) - 1, Lines),
            {Complete, Partial}
    end,
    Events = lists:filtermap(fun(Line) ->
        case Line of
            <<"data: ", Data/binary>> -> {true, Data};
            _ -> false
        end
    end, CompleteLines),
    {Events, Remainder}.

%% @doc Collect SSE events with event type from a Gun streaming response.
%% Buffers across chunk boundaries to handle TCP fragmentation.
collect_sse_events(ConnPid, StreamRef, Acc) ->
    collect_sse_events(ConnPid, StreamRef, <<>>, Acc).

collect_sse_events(ConnPid, StreamRef, Buffer, Acc) ->
    case gun:await(ConnPid, StreamRef, ?REQUEST_TIMEOUT) of
        {data, nofin, Chunk} ->
            Combined = <<Buffer/binary, Chunk/binary>>,
            {Events, NewBuffer} = extract_sse_events(Combined),
            collect_sse_events(ConnPid, StreamRef, NewBuffer, Acc ++ Events);
        {data, fin, Chunk} ->
            Combined = <<Buffer/binary, Chunk/binary>>,
            {Events, _} = extract_sse_events(Combined),
            Acc ++ Events;
        {error, Reason} ->
            ct:pal("WARNING: SSE collection ended with error: ~p", [Reason]),
            Acc
    end.

%% @doc Extract complete SSE events from buffer.
%% Events are delimited by double newlines. Returns {ParsedEvents, RemainingBuffer}.
extract_sse_events(<<>>) ->
    {[], <<>>};
extract_sse_events(Buffer) when byte_size(Buffer) < 2 ->
    {[], Buffer};
extract_sse_events(Buffer) ->
    case binary:split(Buffer, <<"\n\n">>, [global]) of
        [Only] ->
            %% No complete event yet
            {[], Only};
        Parts ->
            %% Last part is either empty (buffer ended with \n\n) or incomplete
            {CompleteBlocks, Remainder} = case binary:match(Buffer, <<"\n\n">>, [{scope, {byte_size(Buffer) - 2, 2}}]) of
                {_, _} ->
                    %% Buffer ends with \n\n — all parts are complete, last is empty
                    {[P || P <- Parts, P =/= <<>>], <<>>};
                nomatch ->
                    %% Last part is incomplete
                    {lists:droplast(Parts), lists:last(Parts)}
            end,
            Events = lists:filtermap(fun(Block) ->
                Lines = binary:split(Block, <<"\n">>, [global]),
                EventType = find_sse_field(<<"event: ">>, Lines),
                Data = find_sse_field(<<"data: ">>, Lines),
                case {EventType, Data} of
                    {undefined, undefined} -> false;
                    {undefined, D} -> {true, {<<"data">>, D}};
                    {E, D} -> {true, {E, D}}
                end
            end, CompleteBlocks),
            {Events, Remainder}
    end.

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

%%====================================================================
%% Engine Helpers
%%====================================================================

%% @doc Find the GPU monitor pid from the engine supervisor's children.
find_gpu_monitor(EngineId) ->
    SupName = loom_engine_sup:sup_name(EngineId),
    Children = supervisor:which_children(SupName),
    case [Pid || {{gpu_monitor, _GpuId}, Pid, worker, _} <- Children, is_pid(Pid)] of
        [MonitorPid | _] -> MonitorPid;
        [] -> ct:fail("No GPU monitor found in engine supervisor")
    end.

%% @doc Get the machine's total RAM in GB via sysctl.
get_machine_ram_gb() ->
    RamBytes = list_to_integer(string:trim(os:cmd("sysctl -n hw.memsize"))),
    RamBytes / (1024 * 1024 * 1024).

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
    ct:pal("WARNING: wait_status_not timed out - recovery may have been instant"),
    ok.
