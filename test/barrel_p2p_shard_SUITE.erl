%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Single-node logic coverage for sharded placement. The HRW
%%% disruption properties are asserted DETERMINISTICALLY against the
%%% pure `barrel_p2p_shard:owner/2'; the integration behaviour (live
%%% member set, lease expiry, ownership events) is driven through the
%%% running app via simulated remote heartbeats. Live multi-node
%%% behaviour is proven in barrel_p2p_shard_e2e_SUITE.
-module(barrel_p2p_shard_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).

-export([
    single_node_owns_everything/1,
    place_matches_pure_owner/1,
    owner_is_order_independent/1,
    adding_a_node_moves_only_its_partitions/1,
    removing_a_node_moves_only_its_partitions/1,
    lease_expiry_drops_member/1,
    ownership_events_on_membership_change/1,
    malformed_gossip_does_not_crash/1
]).

-define(RING, 128).

all() ->
    [
        single_node_owns_everything,
        place_matches_pure_owner,
        owner_is_order_independent,
        adding_a_node_moves_only_its_partitions,
        removing_a_node_moves_only_its_partitions,
        lease_expiry_drops_member,
        ownership_events_on_membership_change,
        malformed_gossip_does_not_crash
    ].

init_per_testcase(_Case, Config) ->
    %% Short lease timings so expiry-driven cases do not crawl.
    application:set_env(barrel_p2p, member_heartbeat_ms, 100),
    application:set_env(barrel_p2p, member_ttl_ms, 300),
    application:set_env(barrel_p2p, member_skew_ms, 60000),
    {ok, _} = application:ensure_all_started(barrel_p2p),
    Config.

end_per_testcase(_Case, _Config) ->
    application:stop(barrel_p2p),
    ok.

%%====================================================================
%% Pure HRW properties (deterministic, no app/timing)
%%====================================================================

%% Malformed peer gossip (heartbeat deltas and full-sync snapshots) must
%% never crash the shard or the shared HLC server; bad entries are dropped
%% and a well-formed heartbeat still registers a member.
malformed_gossip_does_not_crash(_Config) ->
    H = barrel_p2p_hlc:now(),
    GoodDots = #{{'peer@h', H} => true},
    Now = erlang:system_time(millisecond),
    Bad = [
        not_a_map,
        #{n1 => {value, {alive, Now}, not_a_map}},
        #{n2 => {value, {alive, Now}, #{}}},
        #{n3 => {value, {alive, Now}, #{bad => true}}},
        #{n4 => {tombstone, not_a_timestamp}},
        #{n5 => garbage},
        %% wrapper ok, leaf not {alive, integer}
        #{n6 => {value, {alive, not_an_int}, GoodDots}},
        #{n7 => {value, not_alive, GoodDots}}
    ],
    [barrel_p2p_shard:replica_merge_delta(barrel_p2p_members_replica, B) || B <- Bad],
    %% Full-sync snapshots are plain lease maps; feed bad shapes.
    barrel_p2p_shard:replica_apply_full_sync(barrel_p2p_members_replica, not_a_map),
    barrel_p2p_shard:replica_apply_full_sync(barrel_p2p_members_replica, #{<<"bin">> => Now}),
    barrel_p2p_shard:replica_apply_full_sync(barrel_p2p_members_replica, #{anode => not_an_int}),
    _ = sys:get_state(barrel_p2p_shard),
    ?assert(is_process_alive(whereis(barrel_p2p_shard))),
    ?assert(is_process_alive(whereis(barrel_p2p_hlc))),
    %% A well-formed remote heartbeat still registers a member.
    Good = #{'good@127.0.0.1' => {value, {alive, Now}, GoodDots}},
    barrel_p2p_shard:replica_merge_delta(barrel_p2p_members_replica, Good),
    _ = sys:get_state(barrel_p2p_shard),
    ?assert(lists:member('good@127.0.0.1', barrel_p2p:members())).

owner_is_order_independent(_Config) ->
    Members = [a@h, b@h, c@h, d@h, e@h],
    Shuffled = [e@h, c@h, a@h, d@h, b@h],
    [
        ?assertEqual(
            barrel_p2p_shard:owner(P, Members),
            barrel_p2p_shard:owner(P, Shuffled)
        )
     || P <- lists:seq(0, ?RING - 1)
    ],
    ok.

%% Adding a node only steals partitions that now hash highest to it;
%% it never reshuffles ownership among the existing nodes.
adding_a_node_moves_only_its_partitions(_Config) ->
    M0 = [a@h, b@h, c@h],
    New = d@h,
    M1 = [New | M0],
    lists:foreach(
        fun(P) ->
            O0 = barrel_p2p_shard:owner(P, M0),
            O1 = barrel_p2p_shard:owner(P, M1),
            case O1 =:= O0 of
                true -> ok;
                false -> ?assertEqual(New, O1)
            end
        end,
        lists:seq(0, ?RING - 1)
    ),
    ok.

%% Removing a node only moves the partitions it owned; every other
%% partition keeps its owner.
removing_a_node_moves_only_its_partitions(_Config) ->
    M0 = [a@h, b@h, c@h, d@h],
    Gone = d@h,
    M1 = M0 -- [Gone],
    lists:foreach(
        fun(P) ->
            O0 = barrel_p2p_shard:owner(P, M0),
            O1 = barrel_p2p_shard:owner(P, M1),
            case O0 =:= Gone of
                true -> ?assert(lists:member(O1, M1));
                false -> ?assertEqual(O0, O1)
            end
        end,
        lists:seq(0, ?RING - 1)
    ),
    ok.

%%====================================================================
%% Integration through the running app
%%====================================================================

single_node_owns_everything(_Config) ->
    ?assertEqual([node()], barrel_p2p:members()),
    ?assert(barrel_p2p:is_owner(some_key)),
    ?assertEqual(node(), barrel_p2p:place(other_key)),
    ok.

place_matches_pure_owner(_Config) ->
    inject_member('aaa_fake@127.0.0.1'),
    inject_member('zzz_fake@127.0.0.1'),
    wait_member('aaa_fake@127.0.0.1'),
    wait_member('zzz_fake@127.0.0.1'),
    Members = barrel_p2p:members(),
    [
        ?assertEqual(
            barrel_p2p_shard:owner(barrel_p2p:partition(K), Members),
            barrel_p2p:place(K)
        )
     || K <- [k1, k2, "k3", {k, 4}, 5]
    ],
    ok.

lease_expiry_drops_member(_Config) ->
    Fake = 'transient_fake@127.0.0.1',
    inject_member(Fake),
    wait_member(Fake),
    ?assert(lists:member(Fake, barrel_p2p:members())),
    %% Stop refreshing; ttl is 300ms and heartbeat 100ms, so the next
    %% sweeps drop it.
    wait_until(fun() -> not lists:member(Fake, barrel_p2p:members()) end, 3000),
    ok.

ownership_events_on_membership_change(_Config) ->
    ok = barrel_p2p:subscribe_shard(),
    Self = node(),
    %% Add enough fake nodes that self surely loses some partitions.
    Fakes = ['f1@127.0.0.1', 'f2@127.0.0.1', 'f3@127.0.0.1', 'f4@127.0.0.1'],
    Before = owned_partitions([Self]),
    [inject_member(F) || F <- Fakes],
    [wait_member(F) || F <- Fakes],
    After = owned_partitions(barrel_p2p:members()),
    Lost = Before -- After,
    %% We should have been notified of releasing exactly the lost ones
    %% (collect briefly, then compare as sets).
    Released = collect_released(800),
    ?assertEqual(lists:sort(Lost), lists:sort(Released)),
    ?assert(length(Lost) > 0),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

%% Simulate a remote node's heartbeat by feeding the shard a delta in
%% the shape barrel_p2p_replica would deliver.
inject_member(Node) ->
    Now = erlang:system_time(millisecond),
    Dot = {Node, barrel_p2p_hlc:now()},
    Delta = #{Node => {value, {alive, Now}, #{Dot => true}}},
    barrel_p2p_shard:merge_delta(Delta).

owned_partitions(Members) ->
    Self = node(),
    [
        P
     || P <- lists:seq(0, ring_size() - 1),
        barrel_p2p_shard:owner(P, Members) =:= Self
    ].

ring_size() ->
    application:get_env(barrel_p2p, ring_size, 64).

collect_released(TimeoutMs) ->
    collect_released(TimeoutMs, []).

collect_released(TimeoutMs, Acc) ->
    receive
        {barrel_p2p_shard, {released, P}} -> collect_released(TimeoutMs, [P | Acc]);
        {barrel_p2p_shard, {acquired, _}} -> collect_released(TimeoutMs, Acc)
    after TimeoutMs ->
        Acc
    end.

wait_member(Node) ->
    wait_until(fun() -> lists:member(Node, barrel_p2p:members()) end, 2000).

wait_until(Fun, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(Fun, Deadline).

wait_loop(Fun, Deadline) ->
    case Fun() of
        true ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ?assert(false, "wait_until timed out");
                false ->
                    timer:sleep(25),
                    wait_loop(Fun, Deadline)
            end
    end.
