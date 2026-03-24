%%%-------------------------------------------------------------------
%%% @doc Common Test integration suite for loom_gpu_monitor.
%%%
%%% All tests use the mock backend so they run on any platform
%%% including CI without GPU hardware.
%%%
%%% ASSUMPTION: Tests use short poll intervals (100ms) to keep
%%% test execution fast. force_poll/1 is used for deterministic
%%% tests that need an immediate reading.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_gpu_monitor_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

%% CT callbacks
-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    start_stop_test/1,
    get_status_before_poll_test/1,
    get_status_after_poll_test/1,
    force_poll_test/1,
    auto_poll_cycle_test/1,
    threshold_breach_alert_test/1,
    threshold_clear_alert_test/1,
    no_coordinator_warning_test/1,
    consecutive_error_alert_test/1,
    error_recovery_test/1,
    auto_detect_test/1,
    explicit_backend_test/1,
    no_mock_allowed_test/1,
    poll_timeout_validation_test/1,
    custom_thresholds_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        start_stop_test,
        get_status_before_poll_test,
        get_status_after_poll_test,
        force_poll_test,
        auto_poll_cycle_test,
        threshold_breach_alert_test,
        threshold_clear_alert_test,
        no_coordinator_warning_test,
        consecutive_error_alert_test,
        error_recovery_test,
        auto_detect_test,
        explicit_backend_test,
        no_mock_allowed_test,
        poll_timeout_validation_test,
        custom_thresholds_test
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(loom),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_TestCase, _Config) ->
    flush_mailbox(),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

start_stop_test(_Config) ->
    {ok, Pid} = loom_gpu_monitor:start_link(mock_opts(#{})),
    ?assert(is_process_alive(Pid)),
    ok = loom_gpu_monitor:stop(Pid),
    timer:sleep(50),
    ?assertNot(is_process_alive(Pid)).

get_status_before_poll_test(_Config) ->
    %% Use very long poll interval so no automatic poll fires
    {ok, Pid} = loom_gpu_monitor:start_link(
        mock_opts(#{poll_interval_ms => 60000})),
    %% Immediately after start, no poll has fired yet
    ?assertEqual({error, no_reading}, loom_gpu_monitor:get_status(Pid)),
    ok = loom_gpu_monitor:stop(Pid).

get_status_after_poll_test(_Config) ->
    {ok, Pid} = loom_gpu_monitor:start_link(mock_opts(#{})),
    %% force_poll to get a deterministic reading
    {ok, Metrics} = loom_gpu_monitor:force_poll(Pid),
    ?assert(is_map(Metrics)),
    ?assert(maps:is_key(gpu_util, Metrics)),
    %% get_status should now return the same metrics
    {ok, Metrics2} = loom_gpu_monitor:get_status(Pid),
    ?assertEqual(Metrics, Metrics2),
    ok = loom_gpu_monitor:stop(Pid).

force_poll_test(_Config) ->
    Custom = #{
        gpu_util => 99.0, mem_used_gb => 75.0, mem_total_gb => 80.0,
        temperature_c => 82.0, power_w => 300.0, ecc_errors => 2
    },
    {ok, Pid} = loom_gpu_monitor:start_link(
        mock_opts(#{metrics => Custom})),
    {ok, Metrics} = loom_gpu_monitor:force_poll(Pid),
    ?assertEqual(Custom, Metrics),
    ok = loom_gpu_monitor:stop(Pid).

auto_poll_cycle_test(_Config) ->
    {ok, Pid} = loom_gpu_monitor:start_link(
        mock_opts(#{poll_interval_ms => 100, poll_timeout_ms => 50})),
    %% Wait for at least 2 automatic polls
    timer:sleep(250),
    {ok, Metrics} = loom_gpu_monitor:get_status(Pid),
    ?assert(is_map(Metrics)),
    ok = loom_gpu_monitor:stop(Pid).

threshold_breach_alert_test(_Config) ->
    %% Memory at 96% should breach 95% threshold
    HighMem = #{
        gpu_util => 50.0, mem_used_gb => 76.8, mem_total_gb => 80.0,
        temperature_c => 70.0, power_w => 200.0, ecc_errors => 0
    },
    {ok, Pid} = loom_gpu_monitor:start_link(
        mock_opts(#{metrics => HighMem,
                    thresholds => #{mem_percent => 95.0},
                    coordinator => self()})),
    {ok, _} = loom_gpu_monitor:force_poll(Pid),
    receive
        {gpu_alert, _, memory, _, _} -> ok
    after 1000 ->
        ct:fail("expected memory threshold alert")
    end,
    ok = loom_gpu_monitor:stop(Pid).

threshold_clear_alert_test(_Config) ->
    %% Test that a breached threshold does not re-fire on subsequent polls
    %% (transition-only alerting). True "clearing" requires changing mock
    %% metrics which needs two separate monitors.
    HighTemp = #{
        gpu_util => 50.0, mem_used_gb => 40.0, mem_total_gb => 80.0,
        temperature_c => 90.0, power_w => 200.0, ecc_errors => 0
    },
    {ok, Pid} = loom_gpu_monitor:start_link(
        mock_opts(#{metrics => HighTemp,
                    thresholds => #{temperature_c => 85.0},
                    coordinator => self()})),
    {ok, _} = loom_gpu_monitor:force_poll(Pid),
    receive
        {gpu_alert, _, temperature, 90.0, 85.0} -> ok
    after 1000 ->
        ct:fail("expected temperature threshold alert")
    end,
    %% Second poll with same metrics should NOT re-alert (idempotent)
    {ok, _} = loom_gpu_monitor:force_poll(Pid),
    receive
        {gpu_alert, _, temperature, _, _} ->
            ct:fail("should not re-alert on same breached state")
    after 200 ->
        ok
    end,
    ok = loom_gpu_monitor:stop(Pid).

no_coordinator_warning_test(_Config) ->
    %% No coordinator configured, threshold breach should log warning not crash
    HighMem = #{
        gpu_util => 50.0, mem_used_gb => 76.8, mem_total_gb => 80.0,
        temperature_c => 70.0, power_w => 200.0, ecc_errors => 0
    },
    {ok, Pid} = loom_gpu_monitor:start_link(
        mock_opts(#{metrics => HighMem,
                    thresholds => #{mem_percent => 95.0}})),
    %% Should not crash despite no coordinator
    {ok, _} = loom_gpu_monitor:force_poll(Pid),
    ?assert(is_process_alive(Pid)),
    ok = loom_gpu_monitor:stop(Pid).

consecutive_error_alert_test(_Config) ->
    %% Use mock with fail_poll=true to simulate backend failures.
    %% After 3 consecutive poll failures, coordinator gets an alert.
    {ok, Pid} = loom_gpu_monitor:start_link(
        mock_opts(#{fail_poll => true, coordinator => self()})),
    %% force_poll 3 times — each returns error
    {error, _} = loom_gpu_monitor:force_poll(Pid),
    {error, _} = loom_gpu_monitor:force_poll(Pid),
    {error, _} = loom_gpu_monitor:force_poll(Pid),
    %% Third failure triggers poll_failure alert
    receive
        {gpu_alert, _, poll_failure, 3, 3} -> ok
    after 1000 ->
        ct:fail("expected poll_failure alert after 3 consecutive errors")
    end,
    %% Fourth failure should NOT re-alert (fires only at exactly 3)
    {error, _} = loom_gpu_monitor:force_poll(Pid),
    receive
        {gpu_alert, _, poll_failure, _, _} ->
            ct:fail("should not re-alert after 3rd failure")
    after 200 ->
        ok
    end,
    ok = loom_gpu_monitor:stop(Pid).

error_recovery_test(_Config) ->
    %% Verify the GenServer continues working after poll errors.
    %% Start with normal mock, force some polls, confirm they succeed.
    %% (Full error->recovery cycle would need mid-test mock state change;
    %% we verify the GenServer stays alive and serves metrics.)
    {ok, Pid} = loom_gpu_monitor:start_link(mock_opts(#{})),
    {ok, M1} = loom_gpu_monitor:force_poll(Pid),
    {ok, M2} = loom_gpu_monitor:force_poll(Pid),
    ?assertEqual(M1, M2),
    ?assert(is_process_alive(Pid)),
    ok = loom_gpu_monitor:stop(Pid).

auto_detect_test(_Config) ->
    %% With auto detection, selects best available backend.
    %% On Apple Silicon: apple backend. On Linux with GPU: nvidia.
    %% On CI without either: mock fallback (allow_mock_backend=true).
    Opts = #{
        gpu_id => test_auto,
        backend => auto,
        poll_interval_ms => 60000,
        allow_mock_backend => true
    },
    {ok, Pid} = loom_gpu_monitor:start_link(Opts),
    {ok, _} = loom_gpu_monitor:force_poll(Pid),
    ok = loom_gpu_monitor:stop(Pid).

explicit_backend_test(_Config) ->
    Opts = #{
        gpu_id => test_explicit,
        backend => mock,
        poll_interval_ms => 60000
    },
    {ok, Pid} = loom_gpu_monitor:start_link(Opts),
    {ok, _} = loom_gpu_monitor:force_poll(Pid),
    ok = loom_gpu_monitor:stop(Pid).

no_mock_allowed_test(_Config) ->
    %% On a dev machine without nvidia, auto detect with
    %% allow_mock_backend=false should fail to start.
    %% This test may behave differently on machines with real GPUs.
    case loom_gpu_backend_nvidia:detect() orelse
         loom_gpu_backend_apple:detect() of
        true ->
            %% Real backend available, skip this test
            {skip, real_backend_available};
        false ->
            Opts = #{
                gpu_id => test_no_mock,
                backend => auto,
                poll_interval_ms => 60000,
                allow_mock_backend => false
            },
            Result = loom_gpu_monitor:start_link(Opts),
            ?assertMatch({error, _}, Result)
    end.

poll_timeout_validation_test(_Config) ->
    %% poll_timeout_ms >= poll_interval_ms should fail
    Opts = #{
        gpu_id => test_timeout,
        backend => mock,
        poll_interval_ms => 1000,
        poll_timeout_ms => 2000
    },
    Result = loom_gpu_monitor:start_link(Opts),
    ?assertMatch({error, _}, Result).

custom_thresholds_test(_Config) ->
    %% Custom threshold of 50% memory should trigger on default mock
    %% metrics (4.0/16.0 = 25%, should NOT breach)
    {ok, Pid} = loom_gpu_monitor:start_link(
        mock_opts(#{thresholds => #{mem_percent => 50.0},
                    coordinator => self()})),
    {ok, _} = loom_gpu_monitor:force_poll(Pid),
    receive
        {gpu_alert, _, memory, _, _} ->
            ct:fail("25% memory should not breach 50% threshold")
    after 200 ->
        ok
    end,
    ok = loom_gpu_monitor:stop(Pid).

%%====================================================================
%% Helpers
%%====================================================================

-spec mock_opts(map()) -> map().
mock_opts(Overrides) ->
    Defaults = #{
        gpu_id => test_gpu,
        backend => mock,
        poll_interval_ms => 60000,
        poll_timeout_ms => 3000,
        allow_mock_backend => true
    },
    %% Extract mock-specific keys for backend init
    MockMetrics = maps:get(metrics, Overrides, undefined),
    Base = maps:merge(Defaults, maps:without([metrics], Overrides)),
    case MockMetrics of
        undefined -> Base;
        M -> Base#{metrics => M}
    end.

-spec flush_mailbox() -> ok.
flush_mailbox() ->
    receive
        _ -> flush_mailbox()
    after 0 ->
        ok
    end.
