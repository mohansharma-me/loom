-module(loom_http_server).
-behaviour(gen_server).

%% ASSUMPTION: This gen_server is a lifecycle wrapper only. It does NOT sit in
%% the HTTP request path. Cowboy manages its own process tree under ranch_sup.
%% This module exists so loom_sup can start/stop Cowboy as a supervised child.
%% On terminate, it calls loom_http:stop() to remove the Cowboy listener from ranch_sup.

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("kernel/include/logger.hrl").

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init([]) -> {ok, map()} | {stop, term()}.
init([]) ->
    case loom_http:start() of
        {ok, _Pid} ->
            ?LOG_INFO(#{msg => http_server_started}),
            {ok, #{}};
        {error, Reason} ->
            ?LOG_ERROR(#{msg => http_server_start_failed, reason => Reason}),
            {stop, Reason}
    end.

-spec handle_call(term(), gen_server:from(), map()) ->
    {reply, {error, not_implemented}, map()}.
handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(Info, State) ->
    ?LOG_WARNING(#{msg => unexpected_message, info => Info}),
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(Reason, _State) ->
    ?LOG_INFO(#{msg => http_server_terminating, reason => Reason}),
    loom_http:stop().
