-module(loom_app_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    http_config_reads_from_ets_test/1
]).

all() ->
    [
        http_config_reads_from_ets_test
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Clean up any leftover ETS table from previous tests
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    Config.

end_per_testcase(_TestCase, _Config) ->
    case ets:info(loom_config) of
        undefined -> ok;
        _ -> ets:delete(loom_config)
    end,
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% @doc get_config/0 returns server config from loom_config ETS
%% plus handler defaults and engine_id from first engine.
http_config_reads_from_ets_test(_Config) ->
    %% Load a test config
    TestConfig = test_config_path(),
    ok = loom_config:load(TestConfig),

    HttpConfig = loom_http_util:get_config(),

    %% Server settings from loom.json
    ?assertEqual(9999, maps:get(port, HttpConfig)),

    %% Handler defaults still present
    ?assert(maps:is_key(max_body_size, HttpConfig)),
    ?assert(maps:is_key(inactivity_timeout, HttpConfig)),
    ?assert(maps:is_key(generate_timeout, HttpConfig)),

    %% engine_id defaults to first engine name
    ?assertEqual(<<"test_engine">>, maps:get(engine_id, HttpConfig)).

%%====================================================================
%% Helpers
%%====================================================================

test_config_path() ->
    %% ASSUMPTION: The test data dir is relative to the project root,
    %% and we can locate it via the source file's compiled path.
    DataDir = filename:join([
        filename:dirname(filename:dirname(code:which(?MODULE))),
        "test", "loom_app_SUITE_data", "loom.json"
    ]),
    case filelib:is_regular(DataDir) of
        true -> DataDir;
        false ->
            %% Fallback: try relative to current working directory
            filename:join(["test", "loom_app_SUITE_data", "loom.json"])
    end.
