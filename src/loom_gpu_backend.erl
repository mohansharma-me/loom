%%%-------------------------------------------------------------------
%%% @doc loom_gpu_backend - behaviour for platform-specific GPU
%%% monitoring backends.
%%%
%%% Each backend implements detect/0 (platform check), init/1
%%% (setup), poll/1 (collect metrics), and terminate/1 (cleanup).
%%% All backends return a normalized metrics() map with required
%%% keys. Unavailable values use -1.0 / -1 sentinels.
%%%
%%% ASSUMPTION: All backends must return every key in metrics().
%%% Using := (required) in the type so Dialyzer enforces this.
%%% @end
%%%-------------------------------------------------------------------
-module(loom_gpu_backend).

-export_type([metrics/0]).

-type metrics() :: #{
    gpu_util       := float(),
    mem_used_gb    := float(),
    mem_total_gb   := float(),
    temperature_c  := float(),
    power_w        := float(),
    %% integer() not non_neg_integer() because -1 is the sentinel for unavailable
    ecc_errors     := integer()
}.

-callback detect() -> boolean().
-callback init(Opts :: map()) -> {ok, State :: term()} | {error, term()}.
-callback poll(State :: term()) -> {ok, metrics(), NewState :: term()} | {error, term()}.
-callback terminate(State :: term()) -> ok.
