-module(loom_app).
-behaviour(application).

-export([start/2, stop/1]).

-include_lib("kernel/include/logger.hrl").

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    case ensure_config_loaded() of
        ok ->
            loom_sup:start_link();
        {error, Reason} ->
            ?LOG_ERROR(#{msg => config_load_failed, reason => Reason}),
            {error, {config_error, Reason}}
    end.

-spec stop(term()) -> ok.
stop(_State) ->
    ok.

%% @private If config is already loaded (e.g., by test setup), skip reload.
%% ASSUMPTION: ETS table existence is a sufficient check for config being loaded.
%% If the table exists but is empty, we still skip — the caller is responsible
%% for ensuring the table has valid data if they created it.
-spec ensure_config_loaded() -> ok | {error, term()}.
ensure_config_loaded() ->
    case ets:info(loom_config) of
        undefined ->
            ?LOG_INFO(#{msg => loading_config}),
            loom_config:load();
        _ ->
            ?LOG_INFO(#{msg => config_already_loaded, source => pre_existing_ets}),
            ok
    end.
