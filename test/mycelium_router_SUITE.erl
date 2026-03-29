-module(mycelium_router_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    test_find_route_direct/1,
    test_find_route_via/1,
    test_find_route_self/1,
    test_cache_route/1,
    test_invalidate_route/1,
    test_invalidate_all/1,
    test_route_cache_expiry/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, routing}].

groups() ->
    [
        {routing, [sequence], [
            test_find_route_self,
            test_find_route_direct,
            test_find_route_via,
            test_cache_route,
            test_invalidate_route,
            test_invalidate_all,
            test_route_cache_expiry
        ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    {ok, _} = application:ensure_all_started(mycelium),
    Config.

end_per_testcase(_TestCase, _Config) ->
    application:stop(mycelium),
    ok.

%%====================================================================
%% Test Cases
%%====================================================================

test_find_route_self(_Config) ->
    %% Route to self should be direct
    ?assertEqual({direct, node()}, mycelium_router:find_route(node())),
    ok.

test_find_route_direct(_Config) ->
    %% Simulate having a node in active view by mocking
    %% In real test, we'd need distributed setup
    %% For now, test that no route returns when active view is empty
    ?assertEqual(no_route, mycelium_router:find_route('fake@node')),
    ok.

test_find_route_via(_Config) ->
    %% Test that when we have no direct connection, we try to find a via route
    %% With an empty active view, we should get no_route
    ?assertEqual(no_route, mycelium_router:find_route('remote@node')),
    ok.

test_cache_route(_Config) ->
    %% Cache a route and verify we can retrieve it
    ServiceName = test_service,
    ViaNode = 'via@node',

    %% Cache the route
    ok = mycelium_router:cache_route(ServiceName, ViaNode),
    timer:sleep(50), %% Allow async cast to complete

    %% Verify cache entry exists in ETS
    [{ServiceName, ViaNode, _Time}] = ets:lookup(mycelium_route_cache, ServiceName),
    ok.

test_invalidate_route(_Config) ->
    %% Cache a route
    ServiceName = invalidate_test,
    ok = mycelium_router:cache_route(ServiceName, 'some@node'),
    timer:sleep(50),

    %% Verify it exists
    ?assertMatch([{_, _, _}], ets:lookup(mycelium_route_cache, ServiceName)),

    %% Invalidate it
    ok = mycelium_router:invalidate_route(ServiceName),
    timer:sleep(50),

    %% Should be gone
    ?assertEqual([], ets:lookup(mycelium_route_cache, ServiceName)),
    ok.

test_invalidate_all(_Config) ->
    %% Cache multiple routes
    ok = mycelium_router:cache_route(svc_a, 'node_a@host'),
    ok = mycelium_router:cache_route(svc_b, 'node_b@host'),
    ok = mycelium_router:cache_route(svc_c, 'node_c@host'),
    timer:sleep(50),

    %% Should have entries
    ?assert(ets:info(mycelium_route_cache, size) >= 3),

    %% Invalidate all
    ok = mycelium_router:invalidate_all(),
    timer:sleep(50),

    %% Should be empty
    ?assertEqual(0, ets:info(mycelium_route_cache, size)),
    ok.

test_route_cache_expiry(_Config) ->
    %% Test that cache entries have timestamps
    ServiceName = expiry_test,
    Before = erlang:monotonic_time(millisecond),
    ok = mycelium_router:cache_route(ServiceName, 'some@node'),
    timer:sleep(50),

    %% Verify entry has timestamp
    [{ServiceName, _Node, Time}] = ets:lookup(mycelium_route_cache, ServiceName),
    ?assert(is_integer(Time)),
    %% Time should be >= the time before we cached (monotonic time can be negative)
    ?assert(Time >= Before),
    ok.
