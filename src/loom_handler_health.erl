-module(loom_handler_health).
-behaviour(cowboy_handler).

-export([init/2]).

-spec init(cowboy_req:req(), any()) -> {ok, cowboy_req:req(), any()}.
init(Req0, State) ->
    Config = loom_http_util:get_config(),
    EngineId = maps:get(engine_id, Config),
    Status = loom_engine_coordinator:get_status(EngineId),
    Load = loom_engine_coordinator:get_load(EngineId),
    StatusBin = atom_to_binary(Status),
    HttpStatus = case Status of
        ready -> 200;
        _ -> 503
    end,
    Body = #{
        <<"status">> => StatusBin,
        <<"engine_id">> => EngineId,
        <<"load">> => Load
    },
    Req = loom_http_util:json_response(HttpStatus, Body, Req0),
    {ok, Req, State}.
