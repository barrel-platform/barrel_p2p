%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Single-node logic coverage for leader election. Remote candidacies
%%% and membership loss are simulated by driving the internal
%%% merge_remote/1, merge_fence/2 and remove_node/1 entry points, so the
%%% election, fencing and transition logic is exercised without spinning
%%% real peers. Live multi-node behaviour is proven in
%%% barrel_p2p_leader_e2e_SUITE.
-module(barrel_p2p_leader_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).

-export([
    sole_candidate_becomes_leader/1,
    resign_clears_leadership/1,
    candidate_death_removes_candidacy/1,
    duplicate_local_candidacy_rejected/1,
    lower_remote_atom_revokes_then_reelects/1,
    priority_beats_lower_atom/1,
    fence_monotonic_across_relead/1,
    merge_fence_forces_higher_mint/1,
    malformed_gossip_does_not_crash/1
]).

all() ->
    [
        sole_candidate_becomes_leader,
        resign_clears_leadership,
        candidate_death_removes_candidacy,
        duplicate_local_candidacy_rejected,
        lower_remote_atom_revokes_then_reelects,
        priority_beats_lower_atom,
        fence_monotonic_across_relead,
        merge_fence_forces_higher_mint,
        malformed_gossip_does_not_crash
    ].

init_per_testcase(_Case, Config) ->
    {ok, _} = application:ensure_all_started(barrel_p2p),
    Config.

end_per_testcase(_Case, _Config) ->
    application:stop(barrel_p2p),
    ok.

%%====================================================================
%% Test cases
%%====================================================================

%% Malformed peer gossip (candidate deltas, fence custom broadcasts, and
%% full-sync payloads) must never crash the leader or the shared HLC server;
%% bad entries are dropped and a well-formed election still works.
malformed_gossip_does_not_crash(_Config) ->
    H = barrel_p2p_hlc:now(),
    GoodDots = #{{'peer@h', H} => true},
    GoodCand = {self(), 0},
    Bad = [
        not_a_map,
        #{{a, n} => {value, GoodCand, not_a_map}},
        #{{b, n} => {value, GoodCand, #{}}},
        #{{c, n} => {value, GoodCand, #{bad => true}}},
        #{{d, n} => {tombstone, not_a_timestamp}},
        #{{e, n} => garbage},
        %% wrapper ok, leaf is not a {Pid, Priority}
        #{{f, n} => {value, not_a_candidate, GoodDots}}
    ],
    [barrel_p2p_leader:replica_merge_delta(barrel_p2p_leader_replica, B) || B <- Bad],
    %% Fence custom broadcasts: a non-timestamp fence and a non-tuple payload.
    barrel_p2p_leader:replica_merge_custom(barrel_p2p_leader_replica, {job, not_a_timestamp}),
    barrel_p2p_leader:replica_merge_custom(barrel_p2p_leader_replica, garbage),
    %% Full-sync: bad candidate map and bad fence map.
    barrel_p2p_leader:replica_apply_full_sync(barrel_p2p_leader_replica, {not_a_map, not_a_map}),
    barrel_p2p_leader:replica_apply_full_sync(
        barrel_p2p_leader_replica,
        {#{{g, n} => {value, not_a_candidate, GoodDots}}, #{job => not_a_timestamp}}
    ),
    _ = sys:get_state(barrel_p2p_leader),
    ?assert(is_process_alive(whereis(barrel_p2p_leader))),
    ?assert(is_process_alive(whereis(barrel_p2p_hlc))),
    %% A well-formed election still works.
    ?assertMatch({ok, {leader, _}}, barrel_p2p_leader:lead(goodjob)).

sole_candidate_becomes_leader(_Config) ->
    {ok, {leader, F}} = barrel_p2p_leader:lead(job1),
    ?assert(is_integer(F)),
    ?assert(barrel_p2p_leader:is_leader(job1)),
    ?assertEqual({ok, node(), self()}, barrel_p2p_leader:leader(job1)),
    ?assertEqual({ok, F}, barrel_p2p_leader:fence(job1)),
    ?assertEqual([node()], barrel_p2p_leader:candidates(job1)),
    ok.

resign_clears_leadership(_Config) ->
    {ok, {leader, _F}} = barrel_p2p_leader:lead(job2),
    ok = barrel_p2p_leader:resign(job2),
    ?assertEqual({error, no_leader}, barrel_p2p_leader:leader(job2)),
    ?assertEqual(false, barrel_p2p_leader:is_leader(job2)),
    ?assertEqual({error, not_leader}, barrel_p2p_leader:fence(job2)),
    ok.

candidate_death_removes_candidacy(_Config) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, _} = barrel_p2p_leader:lead(job3),
        Parent ! ready,
        receive
            stop -> ok
        end
    end),
    receive
        ready -> ok
    after 5000 -> ct:fail(candidate_never_started)
    end,
    ?assertEqual({ok, node(), Pid}, barrel_p2p_leader:leader(job3)),
    Pid ! stop,
    wait_until(
        fun() ->
            barrel_p2p_leader:leader(job3) =:= {error, no_leader}
        end,
        2000
    ),
    ok.

duplicate_local_candidacy_rejected(_Config) ->
    {ok, {leader, _F}} = barrel_p2p_leader:lead(job4),
    ?assertEqual({error, already_candidate}, barrel_p2p_leader:lead(job4)),
    ok.

lower_remote_atom_revokes_then_reelects(_Config) ->
    {ok, {leader, _F1}} = barrel_p2p_leader:lead(job5),
    Low = low_node(),
    inject_candidate(job5, Low, self(), 0),
    flush(job5),
    receive
        {barrel_p2p_leader, job5, revoked} -> ok
    after 2000 -> ct:fail(expected_revoked)
    end,
    ?assertEqual(false, barrel_p2p_leader:is_leader(job5)),
    ?assertMatch({ok, Low, _}, barrel_p2p_leader:leader(job5)),
    %% The lower node leaves the cluster: we are re-elected.
    barrel_p2p_leader:remove_node(Low),
    flush(job5),
    receive
        {barrel_p2p_leader, job5, {elected, F2}} -> ?assert(is_integer(F2))
    after 2000 -> ct:fail(expected_reelected)
    end,
    ?assert(barrel_p2p_leader:is_leader(job5)),
    ok.

priority_beats_lower_atom(_Config) ->
    {ok, {leader, _F}} = barrel_p2p_leader:lead(job6, #{priority => 1}),
    %% A candidate on a lower node atom but lower priority must not win.
    inject_candidate(job6, low_node(), self(), 0),
    flush(job6),
    ?assert(barrel_p2p_leader:is_leader(job6)),
    ?assertEqual({ok, node(), self()}, barrel_p2p_leader:leader(job6)),
    ok.

fence_monotonic_across_relead(_Config) ->
    {ok, {leader, F1}} = barrel_p2p_leader:lead(job7),
    ok = barrel_p2p_leader:resign(job7),
    {ok, {leader, F2}} = barrel_p2p_leader:lead(job7),
    ?assert(F2 > F1),
    ok.

merge_fence_forces_higher_mint(_Config) ->
    {ok, {leader, F1}} = barrel_p2p_leader:lead(job8),
    HighHLC = far_future_hlc(),
    HighPacked = pack(HighHLC),
    ?assert(HighPacked > F1),
    barrel_p2p_leader:merge_fence(job8, HighHLC),
    flush(job8),
    ok = barrel_p2p_leader:resign(job8),
    {ok, {leader, F2}} = barrel_p2p_leader:lead(job8),
    ?assert(F2 > HighPacked),
    ok.

%%====================================================================
%% Helpers
%%====================================================================

%% A node atom that sorts strictly below the local node atom.
low_node() ->
    list_to_atom("0_" ++ atom_to_list(node())).

%% Build and merge a remote candidacy delta for Name on Node.
inject_candidate(Name, Node, Pid, Prio) ->
    Dot = {Node, barrel_p2p_hlc:now()},
    Delta = #{{Name, Node} => {value, {Pid, Prio}, #{Dot => true}}},
    barrel_p2p_leader:merge_remote(Delta).

%% Synchronous call after an async cast flushes the gen_server mailbox,
%% so the cast has been fully processed before we assert.
flush(Name) ->
    _ = barrel_p2p_leader:candidates(Name),
    ok.

%% A timestamp comfortably ahead of the live clock, in the clock's own
%% unit, built without pulling in the hlc record header.
far_future_hlc() ->
    Now = barrel_p2p_hlc:now(),
    Wall = barrel_p2p_hlc:wall_time(Now) + 1000000000000,
    barrel_p2p_hlc:from_binary(<<Wall:64/big, 0:32/big>>).

%% Mirror barrel_p2p_leader's packing so tests can compare tokens.
pack(HLC) ->
    (barrel_p2p_hlc:wall_time(HLC) bsl 32) bor
        (barrel_p2p_hlc:logical(HLC) band 16#FFFFFFFF).

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
                    timer:sleep(50),
                    wait_loop(Fun, Deadline)
            end
    end.
