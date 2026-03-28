-module(loom_mock_coordinator_tests).
-include_lib("eunit/include/eunit.hrl").

fail_after_test() ->
    {ok, Pid} = loom_mock_coordinator:start_link(#{
        engine_id => <<"fail_test">>,
        behavior => #{
            tokens => [<<"a">>, <<"b">>, <<"c">>, <<"d">>],
            fail_after => 2,
            token_delay => 0
        }
    }),
    {ok, ReqId} = gen_statem:call(Pid, {generate, <<"test">>, #{}}),
    %% Should receive 2 tokens then an error
    receive {loom_token, ReqId, <<"a">>, false} -> ok after 1000 -> ?assert(false) end,
    receive {loom_token, ReqId, <<"b">>, false} -> ok after 1000 -> ?assert(false) end,
    receive {loom_error, ReqId, <<"fail_after">>, _} -> ok after 1000 -> ?assert(false) end,
    loom_mock_coordinator:stop(Pid).

delay_ms_test() ->
    {ok, Pid} = loom_mock_coordinator:start_link(#{
        engine_id => <<"delay_test">>,
        behavior => #{
            tokens => [<<"x">>, <<"y">>],
            delay_ms => {50, 100},
            token_delay => 0
        }
    }),
    T0 = erlang:monotonic_time(millisecond),
    {ok, ReqId} = gen_statem:call(Pid, {generate, <<"test">>, #{}}),
    receive {loom_token, ReqId, <<"x">>, false} -> ok after 2000 -> ?assert(false) end,
    receive {loom_token, ReqId, <<"y">>, false} -> ok after 2000 -> ?assert(false) end,
    receive {loom_done, ReqId, _} -> ok after 2000 -> ?assert(false) end,
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    %% At least 100ms total (2 tokens * 50ms minimum delay)
    ?assert(Elapsed >= 100),
    loom_mock_coordinator:stop(Pid).

memory_pressure_test() ->
    {ok, Pid} = loom_mock_coordinator:start_link(#{
        engine_id => <<"pressure_test">>,
        behavior => #{
            tokens => [<<"hi">>],
            memory_pressure => true
        }
    }),
    %% Memory pressure is visible via the meta table
    MetaTable = loom_engine_coordinator:meta_table_name(<<"pressure_test">>),
    [{memory_pressure, true}] = ets:lookup(MetaTable, memory_pressure),
    loom_mock_coordinator:stop(Pid).
