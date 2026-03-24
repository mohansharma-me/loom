-module(loom_gpu_backend_apple_tests).
-include_lib("eunit/include/eunit.hrl").

-spec parse_sysctl_normal_test() -> any().
parse_sysctl_normal_test() ->
    Output = "hw.memsize: 17179869184\n",
    {ok, Bytes} = loom_gpu_backend_apple:parse_sysctl_memsize(Output),
    ?assertEqual(17179869184, Bytes).

-spec parse_sysctl_just_number_test() -> any().
parse_sysctl_just_number_test() ->
    Output = "17179869184\n",
    {ok, Bytes} = loom_gpu_backend_apple:parse_sysctl_memsize(Output),
    ?assertEqual(17179869184, Bytes).

-spec parse_sysctl_36gb_test() -> any().
parse_sysctl_36gb_test() ->
    Output = "38654705664\n",
    {ok, Bytes} = loom_gpu_backend_apple:parse_sysctl_memsize(Output),
    ?assertEqual(38654705664, Bytes).

-spec parse_sysctl_empty_test() -> any().
parse_sysctl_empty_test() ->
    ?assertMatch({error, _}, loom_gpu_backend_apple:parse_sysctl_memsize("")).

-spec parse_sysctl_garbage_test() -> any().
parse_sysctl_garbage_test() ->
    ?assertMatch({error, _}, loom_gpu_backend_apple:parse_sysctl_memsize("not a number")).

-spec parse_vm_stat_normal_test() -> any().
parse_vm_stat_normal_test() ->
    Output =
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
        "Pages free:                               12345.\n"
        "Pages active:                             67890.\n"
        "Pages inactive:                           11111.\n"
        "Pages speculative:                         2222.\n"
        "Pages throttled:                              0.\n"
        "Pages wired down:                         33333.\n"
        "Pages purgeable:                           4444.\n"
        "\"Translation faults\":                 55555555.\n"
        "Pages copy-on-write:                    1234567.\n"
        "Pages zero filled:                     7654321.\n"
        "Pages reactivated:                       98765.\n"
        "Pages purged:                            12345.\n"
        "File-backed pages:                       44444.\n"
        "Anonymous pages:                         55555.\n"
        "Pages stored in compressor:              66666.\n"
        "Pages occupied by compressor:            77777.\n"
        "Decompressions:                         888888.\n"
        "Compressions:                           999999.\n"
        "Pageins:                                111111.\n"
        "Pageouts:                                22222.\n"
        "Swapins:                                     0.\n"
        "Swapouts:                                    0.\n",
    TotalBytes = 17179869184,
    {ok, UsedGb, TotalGb} = loom_gpu_backend_apple:parse_vm_stat(Output, TotalBytes),
    ?assert(is_float(UsedGb)),
    ?assert(is_float(TotalGb)),
    ?assert(TotalGb > 0.0),
    ?assert(abs(TotalGb - 16.0) < 0.01).

-spec parse_vm_stat_different_page_size_test() -> any().
parse_vm_stat_different_page_size_test() ->
    Output =
        "Mach Virtual Memory Statistics: (page size of 4096 bytes)\n"
        "Pages free:                              100000.\n"
        "Pages active:                            200000.\n"
        "Pages inactive:                           50000.\n"
        "Pages speculative:                        10000.\n"
        "Pages throttled:                              0.\n"
        "Pages wired down:                        150000.\n"
        "Pages purgeable:                          20000.\n",
    TotalBytes = 8589934592,
    {ok, UsedGb, TotalGb} = loom_gpu_backend_apple:parse_vm_stat(Output, TotalBytes),
    ?assert(is_float(UsedGb)),
    ?assert(abs(TotalGb - 8.0) < 0.01).

-spec parse_vm_stat_empty_test() -> any().
parse_vm_stat_empty_test() ->
    ?assertMatch({error, _}, loom_gpu_backend_apple:parse_vm_stat("", 0)).

-spec parse_vm_stat_no_page_size_test() -> any().
parse_vm_stat_no_page_size_test() ->
    ?assertMatch({error, _}, loom_gpu_backend_apple:parse_vm_stat("random text\n", 1024)).

-spec detect_returns_boolean_test() -> any().
detect_returns_boolean_test() ->
    Result = loom_gpu_backend_apple:detect(),
    ?assert(is_boolean(Result)).

-spec metrics_shape_test() -> any().
metrics_shape_test() ->
    Metrics = loom_gpu_backend_apple:build_metrics(12.0, 16.0),
    ?assertEqual(-1.0, maps:get(gpu_util, Metrics)),
    ?assertEqual(12.0, maps:get(mem_used_gb, Metrics)),
    ?assertEqual(16.0, maps:get(mem_total_gb, Metrics)),
    ?assertEqual(-1.0, maps:get(temperature_c, Metrics)),
    ?assertEqual(-1.0, maps:get(power_w, Metrics)),
    ?assertEqual(-1, maps:get(ecc_errors, Metrics)).
