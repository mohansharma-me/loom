-module(loom_handler_models).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), any()) -> {ok, cowboy_req:req(), any()}.
init(Req0, State) ->
    Config = loom_http_util:get_config(),
    EngineId = maps:get(engine_id, Config),
    Info = loom_engine_coordinator:get_info(EngineId),
    Models = case maps:get(model, Info, undefined) of
        undefined -> [];
        Model ->
            [#{<<"id">> => Model,
               <<"object">> => <<"model">>,
               <<"owned_by">> => <<"loom">>}]
    end,
    Body = #{<<"object">> => <<"list">>, <<"data">> => Models},
    Req = loom_http_util:json_response(200, Body, Req0),
    {ok, Req, State}.
