-module(loom_http).

-export([start/0, stop/0]).

-include_lib("kernel/include/logger.hrl").

%% NOTE: loom_http is started manually for now. Integration into loom_sup
%% supervision tree is part of P0-11 (#12) — wiring all components together.

-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    Config = loom_http_util:get_config(),
    Port = maps:get(port, Config),
    Ip = maps:get(ip, Config),
    MaxConns = maps:get(max_connections, Config),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/v1/chat/completions", loom_handler_chat, []},
            {"/v1/messages", loom_handler_messages, []},
            {"/health", loom_handler_health, []},
            {"/v1/models", loom_handler_models, []}
        ]}
    ]),
    TransOpts = #{
        socket_opts => [{port, Port}, {ip, Ip}],
        max_connections => MaxConns
    },
    ProtoOpts = #{
        env => #{dispatch => Dispatch},
        middlewares => [cowboy_router, loom_http_middleware, cowboy_handler]
    },
    ?LOG_INFO(#{msg => starting_http, port => Port, ip => Ip}),
    cowboy:start_clear(loom_http_listener, TransOpts, ProtoOpts).

-spec stop() -> ok.
stop() ->
    cowboy:stop_listener(loom_http_listener).
