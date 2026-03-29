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
    loom_test_helpers:stop_app(),
    catch application:stop(gun),
    case ?config(config_path, Config) of
        undefined -> ok;
        Path -> file:delete(Path)
    end,
    ok.

%%====================================================================
%% Test Cases (stubs — replaced in subsequent tasks)
%%====================================================================

health_endpoint_test(_Config) -> ok.
memory_metrics_test(_Config) -> ok.
chat_completion_openai_test(_Config) -> ok.
chat_completion_anthropic_test(_Config) -> ok.
sse_streaming_openai_test(_Config) -> ok.
sse_streaming_anthropic_test(_Config) -> ok.
gpu_metrics_sanity_test(_Config) -> ok.
crash_recovery_test(_Config) -> ok.

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
