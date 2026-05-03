%%% -*- erlang -*-
%%%
%%% EUnit tests for mycelium_router:find_path/1,2.
%%%
%%% End-to-end probe-broadcast across multiple nodes is exercised by
%%% mycelium_circuit_multinode_SUITE (`auto_routed_roundtrip` case).
%%% Here we cover the synchronous decision points: target =:= self,
%%% target in the local active view, and the no-active-peers degenerate
%%% case.

-module(mycelium_router_path_tests).

-include_lib("eunit/include/eunit.hrl").

-define(PATH_CACHE, mycelium_path_cache).

setup() ->
    %% find_path/2 reads ?PATH_CACHE on the cache-miss branch; create
    %% it standalone so we don't need the router gen_server running.
    catch ets:delete(?PATH_CACHE),
    ?PATH_CACHE = ets:new(?PATH_CACHE, [named_table, public, set]),
    meck:new(mycelium, [non_strict, passthrough]),
    meck:new(mycelium_path_stats, [non_strict]),
    ok.

teardown(_) ->
    meck:unload(mycelium_path_stats),
    meck:unload(mycelium),
    catch ets:delete(?PATH_CACHE),
    ok.

with(Test) -> {setup, fun setup/0, fun teardown/1, Test}.

%% Target =:= node(): trivial loopback, no probing.
self_target_returns_zero_test_() ->
    with(fun () ->
        ?assertEqual({ok, [], 0},
                     mycelium_router:find_path(node()))
    end).

%% Target in the local active view: single-hop, EstRtt comes from
%% mycelium_path_stats:srtt/1.
direct_peer_uses_srtt_test_() ->
    with(fun () ->
        Peer = 'peer@h',
        meck:expect(mycelium, active_view, fun() -> [Peer] end),
        meck:expect(mycelium_path_stats, srtt,
                    fun(P) when P =:= Peer -> {ok, 1234} end),
        ?assertEqual({ok, [], 1234},
                     mycelium_router:find_path(Peer))
    end).

%% srtt/1 failure should not crash find_path; EstRtt falls back to 0.
direct_peer_srtt_unavailable_falls_back_to_zero_test_() ->
    with(fun () ->
        Peer = 'peer@h',
        meck:expect(mycelium, active_view, fun() -> [Peer] end),
        meck:expect(mycelium_path_stats, srtt,
                    fun(_) -> {error, not_connected} end),
        ?assertEqual({ok, [], 0},
                     mycelium_router:find_path(Peer))
    end).

%% No active peers and not in cache: do_probe returns no_route within
%% the configured timeout instead of blocking.
empty_active_view_returns_no_route_test_() ->
    with(fun () ->
        meck:expect(mycelium, active_view, fun() -> [] end),
        ?assertEqual(no_route,
                     mycelium_router:find_path('unreachable@h',
                                               #{timeout => 50}))
    end).
