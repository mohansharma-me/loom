-module(loom_mock_coordinator).
-behaviour(gen_statem).

-export([
    start_link/1,
    stop/1,
    set_behavior/2
]).

-export([init/1, callback_mode/0, ready/3, terminate/3]).

-record(data, {
    engine_id :: binary(),
    meta_table :: atom(),
    behavior :: map()
}).

%% behavior map:
%% #{tokens => [binary()], token_delay => non_neg_integer(),
%%   error => {binary(), binary()} | undefined,
%%   generate_response => {ok, binary()} | {error, atom()}}

-spec start_link(map()) -> {ok, pid()}.
start_link(Config) ->
    gen_statem:start(?MODULE, Config, []).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:stop(Pid).

-spec set_behavior(pid(), map()) -> ok.
set_behavior(Pid, Behavior) ->
    gen_statem:call(Pid, {set_behavior, Behavior}).

callback_mode() -> state_functions.

init(Config) ->
    EngineId = maps:get(engine_id, Config, <<"test_engine">>),
    MetaTable = loom_engine_coordinator:meta_table_name(EngineId),
    ets:new(MetaTable, [named_table, set, public, {read_concurrency, true}]),
    ets:insert(MetaTable, {meta, ready, EngineId, <<"mock">>, <<"mock">>, self(),
                           erlang:system_time(millisecond)}),
    ets:insert(MetaTable, {coordinator_pid, self()}),
    Behavior = maps:get(behavior, Config, default_behavior()),
    Data = #data{
        engine_id = EngineId,
        meta_table = MetaTable,
        behavior = Behavior
    },
    {ok, ready, Data}.

ready({call, From}, {generate, _Prompt, _Params}, #data{behavior = Beh} = Data) ->
    case maps:get(generate_response, Beh, default) of
        {error, Reason} ->
            {keep_state, Data, [{reply, From, {error, Reason}}]};
        _ ->
            RequestId = <<"req-mock-",
                (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
            CallerPid = element(1, From),
            {keep_state, Data,
             [{reply, From, {ok, RequestId}},
              {next_event, internal, {stream_tokens, CallerPid, RequestId}}]}
    end;

ready({call, From}, {set_behavior, NewBehavior}, Data) ->
    {keep_state, Data#data{behavior = NewBehavior}, [{reply, From, ok}]};

ready(internal, {stream_tokens, CallerPid, RequestId}, #data{behavior = Beh} = Data) ->
    Tokens = maps:get(tokens, Beh, [<<"Hello">>, <<"from">>, <<"Loom">>]),
    Delay = maps:get(token_delay, Beh, 0),
    Error = maps:get(error, Beh, undefined),
    spawn(fun() ->
        stream_tokens(CallerPid, RequestId, Tokens, Delay, Error)
    end),
    {keep_state, Data};

ready(info, _Msg, Data) ->
    {keep_state, Data}.

terminate(_Reason, _State, #data{meta_table = MetaTable}) ->
    catch ets:delete(MetaTable),
    ok.

%%% Internal

stream_tokens(CallerPid, RequestId, Tokens, Delay, Error) ->
    lists:foreach(fun(Token) ->
        case Delay > 0 of
            true -> timer:sleep(Delay);
            false -> ok
        end,
        CallerPid ! {loom_token, RequestId, Token, false}
    end, Tokens),
    case Error of
        {Code, Message} ->
            CallerPid ! {loom_error, RequestId, Code, Message};
        undefined ->
            CallerPid ! {loom_done, RequestId,
                         #{tokens => length(Tokens), time_ms => 0}}
    end.

default_behavior() ->
    #{tokens => [<<"Hello">>, <<"from">>, <<"Loom">>],
      token_delay => 0,
      error => undefined}.
