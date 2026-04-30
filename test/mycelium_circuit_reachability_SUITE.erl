-module(mycelium_circuit_reachability_SUITE).

%% Test suite for circuit direct connection reachability cache
%% Tests cache behavior, probing, and configuration

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Cache tests
-export([
    test_cache_miss_returns_unknown/1,
    test_cache_hit_returns_value/1,
    test_cache_expiry/1,
    test_invalidate_single/1,
    test_invalidate_all/1
]).

%% Probe tests
-export([
    test_probe_sync_reachable/1,
    test_probe_sync_unreachable/1,
    test_probe_async_caches_result/1,
    test_probe_async_deduplication/1
]).

%% Configuration tests
-export([
    test_probe_disabled/1,
    test_custom_cache_ttl/1,
    test_custom_negative_ttl/1
]).

%% Integration tests
-export([
    test_direct_connection_detection/1,
    test_fallback_to_relay/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, cache_tests},
     {group, probe_tests},
     {group, config_tests},
     {group, integration_tests}].

groups() ->
    [
        {cache_tests, [sequence], [
            test_cache_miss_returns_unknown,
            test_cache_hit_returns_value,
            test_cache_expiry,
            test_invalidate_single,
            test_invalidate_all
        ]},
        {probe_tests, [sequence], [
            test_probe_sync_reachable,
            test_probe_sync_unreachable,
            test_probe_async_caches_result,
            test_probe_async_deduplication
        ]},
        {config_tests, [sequence], [
            test_probe_disabled,
            test_custom_cache_ttl,
            test_custom_negative_ttl
        ]},
        {integration_tests, [sequence], [
            test_direct_connection_detection,
            test_fallback_to_relay
        ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    %% Start application for all tests
    application:ensure_all_started(mycelium),
    %% Clear cache before each group
    mycelium_circuit_reachability:invalidate_all(),
    Config.

end_per_group(_Group, _Config) ->
    mycelium_circuit_reachability:invalidate_all(),
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Clear cache before each test
    mycelium_circuit_reachability:invalidate_all(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    %% Reset any changed app env
    application:unset_env(mycelium, circuit_probe_direct),
    application:unset_env(mycelium, circuit_probe_timeout),
    application:unset_env(mycelium, circuit_reachability_cache_ttl),
    application:unset_env(mycelium, circuit_reachability_negative_ttl),
    ok.

%%====================================================================
%% Cache Tests
%%====================================================================

test_cache_miss_returns_unknown(_Config) ->
    %% Node not in cache should return unknown
    Node = 'unknown_node@somehost',
    Result = mycelium_circuit_reachability:is_reachable(Node),
    ?assertEqual(unknown, Result),
    ok.

test_cache_hit_returns_value(_Config) ->
    %% Manually insert into cache and verify retrieval
    Node = 'cached_node@somehost',

    %% Insert directly into ETS (simulating a completed probe)
    Now = erlang:monotonic_time(millisecond),
    Entry = {cache_entry, Node, true, Now + 300000},
    ets:insert(mycelium_reachability_cache, Entry),

    Result = mycelium_circuit_reachability:is_reachable(Node),
    ?assertEqual(true, Result),

    %% Test false value too
    Node2 = 'unreachable_node@somehost',
    Entry2 = {cache_entry, Node2, false, Now + 60000},
    ets:insert(mycelium_reachability_cache, Entry2),

    Result2 = mycelium_circuit_reachability:is_reachable(Node2),
    ?assertEqual(false, Result2),
    ok.

test_cache_expiry(_Config) ->
    %% Insert expired entry and verify it returns unknown
    Node = 'expired_node@somehost',

    %% Insert with past expiry time
    Now = erlang:monotonic_time(millisecond),
    Entry = {cache_entry, Node, true, Now - 1000}, %% Expired 1 second ago
    ets:insert(mycelium_reachability_cache, Entry),

    Result = mycelium_circuit_reachability:is_reachable(Node),
    ?assertEqual(unknown, Result),
    ok.

test_invalidate_single(_Config) ->
    %% Insert entry, invalidate it, verify gone
    Node = 'to_invalidate@somehost',

    Now = erlang:monotonic_time(millisecond),
    Entry = {cache_entry, Node, true, Now + 300000},
    ets:insert(mycelium_reachability_cache, Entry),

    %% Verify it's there
    ?assertEqual(true, mycelium_circuit_reachability:is_reachable(Node)),

    %% Invalidate
    ok = mycelium_circuit_reachability:invalidate(Node),

    %% Verify it's gone
    ?assertEqual(unknown, mycelium_circuit_reachability:is_reachable(Node)),
    ok.

test_invalidate_all(_Config) ->
    %% Insert multiple entries, invalidate all, verify all gone
    Node1 = 'node1@somehost',
    Node2 = 'node2@somehost',
    Node3 = 'node3@somehost',

    Now = erlang:monotonic_time(millisecond),
    ets:insert(mycelium_reachability_cache, {cache_entry, Node1, true, Now + 300000}),
    ets:insert(mycelium_reachability_cache, {cache_entry, Node2, false, Now + 300000}),
    ets:insert(mycelium_reachability_cache, {cache_entry, Node3, true, Now + 300000}),

    %% Verify they're there
    ?assertEqual(true, mycelium_circuit_reachability:is_reachable(Node1)),
    ?assertEqual(false, mycelium_circuit_reachability:is_reachable(Node2)),
    ?assertEqual(true, mycelium_circuit_reachability:is_reachable(Node3)),

    %% Invalidate all
    ok = mycelium_circuit_reachability:invalidate_all(),

    %% Verify all gone
    ?assertEqual(unknown, mycelium_circuit_reachability:is_reachable(Node1)),
    ?assertEqual(unknown, mycelium_circuit_reachability:is_reachable(Node2)),
    ?assertEqual(unknown, mycelium_circuit_reachability:is_reachable(Node3)),
    ok.

%%====================================================================
%% Probe Tests
%%====================================================================

test_probe_sync_reachable(_Config) ->
    Node = 'reachable_probe@somehost',
    mock_connect_node(fun(N) when N =:= Node -> true end),

    Result = mycelium_circuit_reachability:probe_sync(Node),
    ?assertEqual(true, Result),
    ?assertEqual(true, mycelium_circuit_reachability:is_reachable(Node)),

    unmock_connect_node(),
    ok.

test_probe_sync_unreachable(_Config) ->
    Node = 'unreachable_probe@somehost',
    mock_connect_node(fun(N) when N =:= Node -> false end),

    application:set_env(mycelium, circuit_probe_timeout, 100),

    Result = mycelium_circuit_reachability:probe_sync(Node),
    ?assertEqual(false, Result),
    ?assertEqual(false, mycelium_circuit_reachability:is_reachable(Node)),

    unmock_connect_node(),
    ok.

test_probe_async_caches_result(_Config) ->
    Node = 'async_probe@somehost',
    mock_connect_node(fun(N) when N =:= Node -> true end),

    ?assertEqual(unknown, mycelium_circuit_reachability:is_reachable(Node)),

    ok = mycelium_circuit_reachability:probe_async(Node),
    timer:sleep(200),

    ?assertEqual(true, mycelium_circuit_reachability:is_reachable(Node)),

    unmock_connect_node(),
    ok.

test_probe_async_deduplication(_Config) ->
    Node = 'dedup_probe@somehost',
    mock_connect_node(fun(N) when N =:= Node -> true end),

    ok = mycelium_circuit_reachability:probe_async(Node),
    ok = mycelium_circuit_reachability:probe_async(Node),
    ok = mycelium_circuit_reachability:probe_async(Node),

    timer:sleep(200),

    ?assertEqual(true, mycelium_circuit_reachability:is_reachable(Node)),

    unmock_connect_node(),
    ok.

%%====================================================================
%% Configuration Tests
%%====================================================================

test_probe_disabled(_Config) ->
    %% Disable probing
    application:set_env(mycelium, circuit_probe_direct, false),

    Node = 'disabled_probe@somehost',

    %% is_reachable should always return unknown when disabled
    ?assertEqual(unknown, mycelium_circuit_reachability:is_reachable(Node)),

    %% Insert a cache entry - should still return unknown when disabled
    Now = erlang:monotonic_time(millisecond),
    ets:insert(mycelium_reachability_cache, {cache_entry, Node, true, Now + 300000}),

    ?assertEqual(unknown, mycelium_circuit_reachability:is_reachable(Node)),

    %% probe_async should be a no-op
    ok = mycelium_circuit_reachability:probe_async(Node),

    %% probe_sync should return false
    Result = mycelium_circuit_reachability:probe_sync(Node),
    ?assertEqual(false, Result),
    ok.

test_custom_cache_ttl(_Config) ->
    application:set_env(mycelium, circuit_reachability_cache_ttl, 100),

    Node = 'shortttl@somehost',
    mock_connect_node(fun(N) when N =:= Node -> true end),

    ?assertEqual(true, mycelium_circuit_reachability:probe_sync(Node)),
    ?assertEqual(true, mycelium_circuit_reachability:is_reachable(Node)),

    timer:sleep(150),
    ?assertEqual(unknown, mycelium_circuit_reachability:is_reachable(Node)),

    unmock_connect_node(),
    ok.

test_custom_negative_ttl(_Config) ->
    application:set_env(mycelium, circuit_reachability_negative_ttl, 100),
    application:set_env(mycelium, circuit_probe_timeout, 50),

    Node = 'shortnegttl@somehost',
    mock_connect_node(fun(N) when N =:= Node -> false end),

    ?assertEqual(false, mycelium_circuit_reachability:probe_sync(Node)),
    ?assertEqual(false, mycelium_circuit_reachability:is_reachable(Node)),

    timer:sleep(150),
    ?assertEqual(unknown, mycelium_circuit_reachability:is_reachable(Node)),

    unmock_connect_node(),
    ok.

%%====================================================================
%% Integration Tests
%%====================================================================

test_direct_connection_detection(_Config) ->
    meck:new(mycelium_hyparview, [passthrough]),
    meck:expect(mycelium_hyparview, active_view, fun() -> [] end),
    meck:expect(mycelium_hyparview, passive_view, fun() -> ['relay@host'] end),

    Target = 'direct_target@somehost',

    Now = erlang:monotonic_time(millisecond),
    ets:insert(mycelium_reachability_cache, {cache_entry, Target, true, Now + 300000}),

    ?assertEqual(true, mycelium_circuit_reachability:is_reachable(Target)),

    meck:unload(mycelium_hyparview),
    ok.

test_fallback_to_relay(_Config) ->
    meck:new(mycelium_hyparview, [passthrough]),
    meck:expect(mycelium_hyparview, active_view, fun() -> [] end),
    meck:expect(mycelium_hyparview, passive_view, fun() -> ['relay@host'] end),

    Target = 'unreachable_target@somehost',

    Now = erlang:monotonic_time(millisecond),
    ets:insert(mycelium_reachability_cache, {cache_entry, Target, false, Now + 60000}),

    ?assertEqual(false, mycelium_circuit_reachability:is_reachable(Target)),

    meck:unload(mycelium_hyparview),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

mock_connect_node(Fun) ->
    meck:new(net_kernel, [unstick, passthrough]),
    meck:expect(net_kernel, connect_node, Fun).

unmock_connect_node() ->
    catch meck:unload(net_kernel),
    ok.
