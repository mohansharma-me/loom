-module(loom_telemetry_tests).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Tests verifying telemetry events fire correctly.
%%
%% ASSUMPTION: telemetry application must be started before attaching
%% handlers; we ensure_all_started in each test to be self-contained.
%%====================================================================

http_request_start_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Ref = make_ref(),
    Handler = fun(_Event, Measurements, Metadata, {Pid, Tag}) ->
        Pid ! {Tag, Measurements, Metadata}
    end,
    telemetry:attach(<<"test-http-start">>, [loom, http, request_start], Handler, {Self, Ref}),
    try
        loom_http_middleware:emit_request_start(<<"GET">>, <<"/health">>, <<"req-123">>),
        receive {Ref, M, Meta} ->
            ?assert(maps:is_key(system_time, M)),
            ?assertEqual(<<"GET">>, maps:get(method, Meta)),
            ?assertEqual(<<"/health">>, maps:get(path, Meta)),
            ?assertEqual(<<"req-123">>, maps:get(request_id, Meta))
        after 1000 -> ?assert(false)
        end
    after
        telemetry:detach(<<"test-http-start">>)
    end.

http_request_stop_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Ref = make_ref(),
    Handler = fun(_Event, Measurements, Metadata, {Pid, Tag}) ->
        Pid ! {Tag, Measurements, Metadata}
    end,
    telemetry:attach(<<"test-http-stop">>, [loom, http, request_stop], Handler, {Self, Ref}),
    try
        loom_http_middleware:emit_request_stop(42, <<"POST">>, <<"/v1/chat">>, <<"req-456">>, 200),
        receive {Ref, M, Meta} ->
            ?assertEqual(42, maps:get(duration, M)),
            ?assertEqual(<<"POST">>, maps:get(method, Meta)),
            ?assertEqual(<<"/v1/chat">>, maps:get(path, Meta)),
            ?assertEqual(<<"req-456">>, maps:get(request_id, Meta)),
            ?assertEqual(200, maps:get(status, Meta))
        after 1000 -> ?assert(false)
        end
    after
        telemetry:detach(<<"test-http-stop">>)
    end.
