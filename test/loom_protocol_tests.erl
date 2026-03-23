-module(loom_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- Buffer tests ---

-spec buffer_new_test() -> any().
buffer_new_test() ->
    ?assertEqual(<<>>, loom_protocol:new_buffer()).

-spec buffer_single_complete_line_test() -> any().
buffer_single_complete_line_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"hello\n">>, Buf0),
    ?assertEqual([<<"hello">>], Lines),
    ?assertEqual(<<>>, Buf1).

-spec buffer_multiple_lines_test() -> any().
buffer_multiple_lines_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"aaa\nbbb\nccc\n">>, Buf0),
    ?assertEqual([<<"aaa">>, <<"bbb">>, <<"ccc">>], Lines),
    ?assertEqual(<<>>, Buf1).

-spec buffer_partial_read_test() -> any().
buffer_partial_read_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines1, Buf1} = loom_protocol:feed(<<"hel">>, Buf0),
    ?assertEqual([], Lines1),
    {Lines2, Buf2} = loom_protocol:feed(<<"lo\n">>, Buf1),
    ?assertEqual([<<"hello">>], Lines2),
    ?assertEqual(<<>>, Buf2).

-spec buffer_partial_then_multiple_test() -> any().
buffer_partial_then_multiple_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {[], Buf1} = loom_protocol:feed(<<"aa">>, Buf0),
    {Lines, Buf2} = loom_protocol:feed(<<"a\nbbb\ncc">>, Buf1),
    ?assertEqual([<<"aaa">>, <<"bbb">>], Lines),
    ?assertEqual(<<"cc">>, Buf2).

-spec buffer_empty_feed_test() -> any().
buffer_empty_feed_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<>>, Buf0),
    ?assertEqual([], Lines),
    ?assertEqual(<<>>, Buf1).

-spec buffer_newline_only_test() -> any().
buffer_newline_only_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"\n">>, Buf0),
    ?assertEqual([<<>>], Lines),
    ?assertEqual(<<>>, Buf1).

-spec buffer_no_trailing_newline_test() -> any().
buffer_no_trailing_newline_test() ->
    Buf0 = loom_protocol:new_buffer(),
    {Lines, Buf1} = loom_protocol:feed(<<"no newline">>, Buf0),
    ?assertEqual([], Lines),
    ?assertEqual(<<"no newline">>, Buf1).
