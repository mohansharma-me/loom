-module(loom_config_prop_tests).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit wrappers
%%====================================================================

merge_override_wins_test() ->
    ?assert(proper:quickcheck(prop_merge_override_wins(), [
        {numtests, 200}, {to_file, user}
    ])).

validation_rejects_missing_required_test() ->
    ?assert(proper:quickcheck(prop_validation_rejects_missing_required(), [
        {numtests, 200}, {to_file, user}
    ])).

%%====================================================================
%% Properties
%%====================================================================

%% Property: When engine-level coordinator overrides are present, they
%% take precedence over hardcoded defaults after a load.
%% ASSUMPTION: loom_config uses engines as a list format with name, backend,
%% model as required fields. The coordinator section merges per-engine over
%% defaults over hardcoded defaults.
prop_merge_override_wins() ->
    ?FORALL(OverrideMaxConc, choose(100, 65535),
        begin
            Config = #{
                <<"engines">> => [
                    #{
                        <<"name">> => <<"test_engine">>,
                        <<"model">> => <<"test-model">>,
                        <<"backend">> => <<"mock">>,
                        <<"coordinator">> => #{
                            <<"max_concurrent">> => OverrideMaxConc
                        }
                    }
                ]
            },
            {ok, Path} = loom_test_helpers:write_temp_config(Config),
            cleanup_ets(),
            try
                ok = loom_config:load(Path),
                {ok, Engine} = loom_config:get_engine(<<"test_engine">>),
                Coord = maps:get(coordinator, Engine, #{}),
                MaxConc = maps:get(max_concurrent, Coord, undefined),
                MaxConc =:= OverrideMaxConc
            after
                cleanup_ets(),
                file:delete(Path)
            end
        end).

%% Property: A config missing any required engine field is rejected.
%% ASSUMPTION: Required engine fields are name, backend, and model.
%% The config uses list-of-engines format. Missing any field triggers
%% a validation error from loom_config:load/1.
prop_validation_rejects_missing_required() ->
    ?FORALL(MissingField, oneof([<<"name">>, <<"backend">>, <<"model">>]),
        begin
            FullEngine = #{
                <<"name">> => <<"bad_engine">>,
                <<"model">> => <<"test-model">>,
                <<"backend">> => <<"mock">>
            },
            BrokenEngine = maps:remove(MissingField, FullEngine),
            Config = #{
                <<"engines">> => [BrokenEngine]
            },
            {ok, Path} = loom_test_helpers:write_temp_config(Config),
            cleanup_ets(),
            try
                Result = loom_config:load(Path),
                Result =/= ok
            after
                cleanup_ets(),
                file:delete(Path)
            end
        end).

%%====================================================================
%% Internal
%%====================================================================

cleanup_ets() ->
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end.
