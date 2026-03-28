-module(loom_config_prop_tests).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% EUnit wrappers
%%====================================================================

merge_override_wins_test() ->
    assert_property(prop_merge_override_wins(), 200).

validation_rejects_missing_required_test() ->
    assert_property(prop_validation_rejects_missing_required(), 200).

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
            loom_test_helpers:with_config(Config, fun() ->
                {ok, Engine} = loom_config:get_engine(<<"test_engine">>),
                Coord = maps:get(coordinator, Engine, #{}),
                MaxConc = maps:get(max_concurrent, Coord, undefined),
                MaxConc =:= OverrideMaxConc
            end)
        end).

%% Property: A config missing any required engine field is rejected with
%% a specific validation error.
%% ASSUMPTION: Required engine fields are name, backend, and model.
%% loom_config:load/1 returns {error, {validation, {missing_field, engine, Field}}}
%% when a required field is absent.
prop_validation_rejects_missing_required() ->
    ?FORALL({MissingField, ExtraFields},
            {oneof([<<"name">>, <<"backend">>, <<"model">>]),
             gen_extra_engine_fields()},
        begin
            FullEngine = maps:merge(#{
                <<"name">> => <<"bad_engine">>,
                <<"model">> => <<"test-model">>,
                <<"backend">> => <<"mock">>
            }, ExtraFields),
            BrokenEngine = maps:remove(MissingField, FullEngine),
            Config = #{<<"engines">> => [BrokenEngine]},
            {ok, Path} = loom_test_helpers:write_temp_config(Config),
            loom_test_helpers:cleanup_ets(),
            try
                Result = loom_config:load(Path),
                case Result of
                    {error, {validation, {missing_field, engine, _}}} -> true;
                    ok -> false;
                    Other -> error({unexpected_result, Other,
                                    {expected_missing_field, MissingField}})
                end
            after
                loom_test_helpers:cleanup_ets(),
                file:delete(Path)
            end
        end).

%%====================================================================
%% Generators
%%====================================================================

gen_extra_engine_fields() ->
    oneof([
        #{},
        #{<<"coordinator">> => #{<<"max_concurrent">> => 10}},
        #{<<"gpu_monitor">> => #{<<"poll_interval_ms">> => 5000}}
    ]).

%%====================================================================
%% Internal
%%====================================================================

assert_property(Prop, NumTests) ->
    Result = proper:quickcheck(Prop, [{numtests, NumTests}, {to_file, user}]),
    case Result of
        true -> ok;
        false ->
            CEx = proper:counterexample(),
            ?assertEqual({property_passed, no_counterexample},
                         {property_failed, CEx})
    end.
