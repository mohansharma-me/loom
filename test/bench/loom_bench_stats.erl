%%%-------------------------------------------------------------------
%%% @doc Statistics calculation, threshold checking, and reporting
%%% for the Loom benchmark suite.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_bench_stats).

-export([
    calculate/1
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

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

%% @doc Get the value at a given percentile from a sorted list.
%% Uses ceiling-rank method: index = ceil(N * P).
percentile(Sorted, N, P) ->
    Index = erlang:ceil(N * P),
    lists:nth(Index, Sorted).
