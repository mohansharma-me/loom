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
    telemetry:attach(Ref, [loom, http, request_start], Handler, {Self, Ref}),
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
        telemetry:detach(Ref)
    end.

http_request_stop_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Ref = make_ref(),
    Handler = fun(_Event, Measurements, Metadata, {Pid, Tag}) ->
        Pid ! {Tag, Measurements, Metadata}
    end,
    telemetry:attach(Ref, [loom, http, request_stop], Handler, {Self, Ref}),
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
        telemetry:detach(Ref)
    end.

engine_state_change_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Ref = make_ref(),
    Handler = fun(_Event, Measurements, Metadata, {Pid, Tag}) ->
        Pid ! {Tag, Measurements, Metadata}
    end,
    telemetry:attach(Ref, [loom, engine, state_change], Handler, {Self, Ref}),
    try
        loom_engine_coordinator:emit_state_change(<<"test-engine">>, starting, ready),
        receive {Ref, M, Meta} ->
            ?assert(maps:is_key(system_time, M)),
            ?assertEqual(<<"test-engine">>, maps:get(engine_id, Meta)),
            ?assertEqual(starting, maps:get(old_state, Meta)),
            ?assertEqual(ready, maps:get(new_state, Meta))
        after 1000 -> ?assert(false)
        end
    after
        telemetry:detach(Ref)
    end.

engine_token_event_test() ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Ref = make_ref(),
    Handler = fun(_Event, Measurements, Metadata, {Pid, Tag}) ->
        Pid ! {Tag, Measurements, Metadata}
    end,
    telemetry:attach(Ref, [loom, engine, token], Handler, {Self, Ref}),
    try
        loom_engine_coordinator:emit_token(<<"test-engine">>, <<"req-789">>),
        receive {Ref, M, Meta} ->
            ?assertEqual(1, maps:get(count, M)),
            ?assertEqual(<<"test-engine">>, maps:get(engine_id, Meta)),
            ?assertEqual(<<"req-789">>, maps:get(request_id, Meta))
        after 1000 -> ?assert(false)
        end
    after
        telemetry:detach(Ref)
    end.
