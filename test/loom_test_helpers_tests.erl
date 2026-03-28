-module(loom_test_helpers_tests).
-include_lib("eunit/include/eunit.hrl").

fixture_path_test() ->
    Path = loom_test_helpers:fixture_path("minimal.json"),
    ?assertEqual("test/fixtures/minimal.json", Path).

flush_mailbox_test() ->
    self() ! hello,
    self() ! world,
    loom_test_helpers:flush_mailbox(),
    receive _ -> ?assert(false)
    after 0 -> ok
    end.

write_temp_config_test() ->
    Config = #{<<"engines">> => []},
    {ok, Path} = loom_test_helpers:write_temp_config(Config),
    ?assert(filelib:is_file(Path)),
    {ok, Bin} = file:read_file(Path),
    ?assertMatch(#{<<"engines">> := _}, loom_json:decode(Bin)),
    file:delete(Path).

wait_for_status_immediate_test() ->
    ok = loom_test_helpers:wait_for_status(fun() -> ready end, ready, 1000).

wait_for_status_timeout_test() ->
    {error, timeout} = loom_test_helpers:wait_for_status(
        fun() -> starting end, ready, 100, 25).
