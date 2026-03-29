%%%-------------------------------------------------------------------
%%% @doc Statistics calculation, threshold checking, and reporting
%%% for the Loom benchmark suite.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_bench_stats).

-export([
    calculate/1,
    check_thresholds/2,
    to_json/2,
    format_table/1,
    format_duration/1
]).

%% @doc Calculate statistics from a list of timing samples (microseconds).
%% Returns a map with min, max, mean, p50, p80, p95, p99, samples.
-spec calculate([non_neg_integer()]) ->
    #{atom() => number()} | {error, empty_samples}.
calculate([]) ->
    {error, empty_samples};
calculate(Samples) ->
    Sorted = lists:sort(Samples),
    N = length(Sorted),
    Sum = lists:sum(Sorted),
    #{
        min => hd(Sorted),
        max => lists:last(Sorted),
        mean => Sum / N,
        p50 => percentile(Sorted, N, 0.50),
        p80 => percentile(Sorted, N, 0.80),
        p95 => percentile(Sorted, N, 0.95),
        p99 => percentile(Sorted, N, 0.99),
        samples => N
    }.

%% @doc Check benchmark results against threshold map.
%% Thresholds :: #{BenchmarkName => #{MetricName => LimitUs}}.
%% A metric fails if Actual >= LimitUs (threshold is exclusive — actual must
%% be strictly less than the limit to pass).
%% Returns [{BenchmarkName, pass | fail, [{Metric, Actual, Limit}]}].
-spec check_thresholds([{atom(), map()}], map()) ->
    [{atom(), pass | fail, [{atom(), number(), number()}]}].
check_thresholds(Results, Thresholds) ->
    ResultNames = [Name || {Name, _} <- Results],
    ThresholdNames = maps:keys(Thresholds),
    case ThresholdNames -- ResultNames of
        [] -> ok;
        Unmatched ->
            logger:warning("Thresholds defined for unknown benchmarks: ~p",
                           [Unmatched])
    end,
    lists:map(fun({Name, Stats}) ->
        case maps:get(Name, Thresholds, undefined) of
            undefined ->
                {Name, pass, []};
            BenchThresholds ->
                Violations = maps:fold(fun(Metric, Limit, Acc) ->
                    Actual = maps:get(Metric, Stats),
                    case Actual >= Limit of
                        true -> [{Metric, Actual, Limit} | Acc];
                        false -> Acc
                    end
                end, [], BenchThresholds),
                case Violations of
                    [] -> {Name, pass, []};
                    _ -> {Name, fail, Violations}
                end
        end
    end, Results).

%% @doc Generate JSON binary from benchmark results.
%% Opts :: #{strict_mode => boolean(), thresholds => map()}.
-spec to_json([{atom(), map()}], map()) -> binary().
to_json(Results, Opts) ->
    StrictMode = maps:get(strict_mode, Opts, false),
    Thresholds = maps:get(thresholds, Opts, #{}),
    ThresholdResults = check_thresholds(Results, Thresholds),
    ThresholdMap = maps:from_list([{N, S =:= pass} || {N, S, _} <- ThresholdResults]),
    BenchMap = lists:foldl(fun({Name, Stats}, Acc) ->
        ThresholdPass = maps:get(Name, ThresholdMap, true),
        Entry = #{
            min_us => maps:get(min, Stats),
            max_us => maps:get(max, Stats),
            mean_us => maps:get(mean, Stats),
            p50_us => maps:get(p50, Stats),
            p80_us => maps:get(p80, Stats),
            p95_us => maps:get(p95, Stats),
            p99_us => maps:get(p99, Stats),
            samples => maps:get(samples, Stats),
            threshold_pass => ThresholdPass
        },
        Acc#{Name => Entry}
    end, #{}, Results),
    AllPass = lists:all(fun({_, #{threshold_pass := P}}) -> P end,
                        maps:to_list(BenchMap)),
    Timestamp = list_to_binary(calendar:system_time_to_rfc3339(
        erlang:system_time(second), [{offset, "Z"}])),
    OtpVersion = list_to_binary(erlang:system_info(otp_release)),
    loom_json:encode(#{
        timestamp => Timestamp,
        otp_version => OtpVersion,
        strict_mode => StrictMode,
        benchmarks => BenchMap,
        pass => AllPass
    }).

%% @doc Format benchmark results as a console table (iolist).
-spec format_table([{atom(), map()}]) -> iolist().
format_table(Results) ->
    Header = io_lib:format(
        "~n============================================================~n"
        "  Loom Benchmark Results~n"
        "============================================================~n"
        " ~-28s ~8s ~8s ~8s ~8s ~8s ~8s~n"
        " ~s~n",
        ["Benchmark", "p50", "p80", "p95", "p99", "min", "max",
         lists:duplicate(76, $-)]),
    Rows = lists:map(fun({Name, Stats}) ->
        io_lib:format(" ~-28s ~8s ~8s ~8s ~8s ~8s ~8s~n", [
            atom_to_list(Name),
            format_duration(maps:get(p50, Stats)),
            format_duration(maps:get(p80, Stats)),
            format_duration(maps:get(p95, Stats)),
            format_duration(maps:get(p99, Stats)),
            format_duration(maps:get(min, Stats)),
            format_duration(maps:get(max, Stats))
        ])
    end, Results),
    Footer = io_lib:format(
        "============================================================~n", []),
    [Header, Rows, Footer].

%% @doc Format a duration in microseconds as a human-readable iolist.
-spec format_duration(number()) -> iolist().
format_duration(Us) when is_float(Us), Us < 1000 ->
    io_lib:format("~Bus", [round(Us)]);
format_duration(Us) when Us < 1000 ->
    io_lib:format("~Bus", [Us]);
format_duration(Us) ->
    Ms = Us / 1000,
    io_lib:format("~.1fms", [Ms]).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

%% @doc Get the value at a given percentile from a sorted list.
%% Uses ceiling-rank method: index = ceil(N * P).
percentile(Sorted, N, P) ->
    Index = erlang:ceil(N * P),
    lists:nth(Index, Sorted).

