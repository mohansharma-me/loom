-module(loom_config).

%% Public API
-export([load/0, load/1]).
-export([get/2, get_engine/1, engine_names/0, get_server/0]).

%% Defaults (exported for testing)
-export([server_defaults/0, port_defaults/0, gpu_monitor_defaults/0,
         coordinator_defaults/0, engine_sup_defaults/0]).

-define(TABLE, loom_config).
-define(DEFAULT_PATH, "config/loom.json").

%%% ===================================================================
%%% Hardcoded defaults
%%% ===================================================================

-spec server_defaults() -> map().
server_defaults() ->
    #{port => 8080,
      ip => {0, 0, 0, 0},
      max_connections => 1024,
      max_body_size => 10485760,
      inactivity_timeout => 60000,
      generate_timeout => 5000}.

-spec port_defaults() -> map().
port_defaults() ->
    #{max_line_length => 1048576,
      spawn_timeout_ms => 5000,
      heartbeat_timeout_ms => 15000,
      shutdown_timeout_ms => 10000,
      post_close_timeout_ms => 5000}.

-spec gpu_monitor_defaults() -> map().
gpu_monitor_defaults() ->
    #{poll_interval_ms => 5000,
      poll_timeout_ms => 3000,
      backend => auto,
      thresholds => #{temperature_c => 85.0,
                      mem_percent => 95.0}}.

-spec coordinator_defaults() -> map().
coordinator_defaults() ->
    #{startup_timeout_ms => 120000,
      drain_timeout_ms => 30000,
      max_concurrent => 64}.

-spec engine_sup_defaults() -> map().
engine_sup_defaults() ->
    #{max_restarts => 5,
      max_period => 60}.

%%% ===================================================================
%%% Public API (stubs)
%%% ===================================================================

-spec load() -> ok | {error, term()}.
load() ->
    load(?DEFAULT_PATH).

-spec load(file:filename()) -> ok | {error, term()}.
load(_Path) ->
    {error, not_implemented}.

-spec get(list(atom()), term()) -> term().
get(_KeyPath, Default) ->
    Default.

-spec get_engine(binary()) -> {ok, map()} | {error, not_found}.
get_engine(_Name) ->
    {error, not_found}.

-spec engine_names() -> [binary()].
engine_names() ->
    [].

-spec get_server() -> map().
get_server() ->
    server_defaults().
