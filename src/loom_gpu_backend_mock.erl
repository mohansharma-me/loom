%%%-------------------------------------------------------------------
%%% @doc loom_gpu_backend_mock - mock GPU monitoring backend.
%%%
%%% Returns configurable static metrics. Used for development, CI,
%%% and testing the loom_gpu_monitor GenServer without real hardware.
%%%
%%% ASSUMPTION: This backend is gated by the allow_mock_backend
%%% feature flag in loom_gpu_monitor. It should not be used in
%%% production deployments.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_gpu_backend_mock).
-behaviour(loom_gpu_backend).

-export([detect/0, init/1, poll/1, terminate/1, default_thresholds/0]).

-spec detect() -> boolean().
detect() ->
    true.

-spec init(map()) -> {ok, map()}.
init(Opts) ->
    Metrics = maps:get(metrics, Opts, default_metrics()),
    FailPoll = maps:get(fail_poll, Opts, false),
    {ok, #{metrics => Metrics, fail_poll => FailPoll}}.

-spec poll(map()) -> {ok, loom_gpu_backend:metrics(), map()} | {error, term()}.
poll(#{fail_poll := true} = _State) ->
    {error, {simulated_failure, mock}};
poll(#{metrics := Metrics} = State) ->
    {ok, Metrics, State}.

-spec terminate(map()) -> ok.
terminate(_State) ->
    ok.

-spec default_thresholds() -> #{atom() => number()}.
default_thresholds() ->
    #{}.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

-spec default_metrics() -> loom_gpu_backend:metrics().
default_metrics() ->
    #{
        gpu_util       => 25.0,
        mem_used_gb    => 4.0,
        mem_total_gb   => 16.0,
        temperature_c  => 45.0,
        power_w        => 100.0,
        ecc_errors     => 0
    }.
