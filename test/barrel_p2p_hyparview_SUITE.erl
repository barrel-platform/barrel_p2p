%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(barrel_p2p_hyparview_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_p2p.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    test_initial_state/1,
    test_active_view_empty/1,
    test_passive_view_empty/1,
    test_leave_clears_views/1,
    test_event_subscription/1,
    test_shuffle_no_peers/1,
    test_pending_timeout_drops_stale_connect/1,
    test_promotion_connect_does_not_crash/1,
    test_leave_emits_peer_down/1,
    test_forward_join_link_is_symmetric/1,
    test_last_seen_is_local_milliseconds/1,
    test_failed_candidate_backs_off/1,
    test_left_node_refuses_neighbor/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, unit}].

groups() ->
    [
        {unit, [sequence], [
            test_initial_state,
            test_active_view_empty,
            test_passive_view_empty,
            test_leave_clears_views,
            test_event_subscription,
            test_shuffle_no_peers,
            test_pending_timeout_drops_stale_connect,
            test_promotion_connect_does_not_crash,
            test_leave_emits_peer_down,
            test_forward_join_link_is_symmetric,
            test_last_seen_is_local_milliseconds,
            test_failed_candidate_backs_off,
            test_left_node_refuses_neighbor
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
    {ok, _} = application:ensure_all_started(barrel_p2p),
    Config.

end_per_testcase(_TestCase, _Config) ->
    application:stop(barrel_p2p),
    ok.

%%====================================================================
%% Test Cases
%%====================================================================

test_initial_state(_Config) ->
    %% barrel_p2p_app sets dist_auto_connect to `once' so `Pid ! Msg' to
    %% any cluster node auto-connects through the discovery chain;
    %% HyParView's active view tracks gossip topology separately.
    ?assertEqual({ok, once}, application:get_env(kernel, dist_auto_connect)),
    ok.

test_active_view_empty(_Config) ->
    ?assertEqual([], barrel_p2p:active_view()),
    ok.

test_passive_view_empty(_Config) ->
    ?assertEqual([], barrel_p2p:passive_view()),
    ok.

test_leave_clears_views(_Config) ->
    barrel_p2p:leave(),
    ?assertEqual([], barrel_p2p:active_view()),
    ?assertEqual([], barrel_p2p:passive_view()),
    ok.

test_event_subscription(_Config) ->
    ok = barrel_p2p:subscribe(),
    %% No events in isolation
    receive
        {barrel_p2p_event, _Event} ->
            ct:fail(unexpected_event)
    after 100 ->
        ok
    end,
    ok = barrel_p2p:unsubscribe(self()),
    ok.

test_shuffle_no_peers(_Config) ->
    %% Should not crash with no peers
    barrel_p2p_hyparview_shuffle:trigger_shuffle(),
    timer:sleep(50),
    ok.

%% A join that never produces peer_connected or peer_failed leaves a
%% pending entry. The backstop timer drops it; before the fix the
%% entry leaked forever.
test_pending_timeout_drops_stale_connect(_Config) ->
    application:set_env(barrel_p2p, pending_timeout_ms, 100),
    %% Initiate a join to a phantom node. The bridge will try to
    %% connect_node and (silently) fail; no peer_connected fires.
    _ = barrel_p2p:join('phantom@host'),
    %% Pending starts populated.
    Pending0 = pending_map(),
    ?assert(maps:is_key('phantom@host', Pending0)),
    %% Wait past the backstop and verify the entry is gone.
    timer:sleep(400),
    Pending1 = pending_map(),
    ?assertNot(maps:is_key('phantom@host', Pending1)),
    application:unset_env(barrel_p2p, pending_timeout_ms),
    ok.

pending_map() ->
    State = sys:get_state(barrel_p2p_hyparview),
    State#view_state.pending.

%% Promoting a passive peer used to crash the server: the promotion stored a
%% `neighbor' pending entry, and peer_connected/2 (sent by the bridge, at
%% once when the dist channel is already up) matched only `join' and
%% `connect'. Losing an active peer while another dist channel was still up
%% restarted HyParView with empty views.
test_promotion_connect_does_not_crash(_Config) ->
    Pid = whereis(barrel_p2p_hyparview),
    ok = barrel_p2p_hyparview_events:subscribe(self()),
    Active = #peer{id = 'act@host', connected = true},
    Passive = #peer{id = 'pas@host', connected = false},
    _ = sys:replace_state(Pid, fun(S) ->
        S#view_state{
            active_view = #{'act@host' => Active},
            passive_view = #{'pas@host' => Passive}
        }
    end),
    %% The active peer fails: HyParView promotes the passive one (a failed
    %% peer is not kept as a candidate, so pas@host is the only one).
    ok = barrel_p2p_hyparview:peer_failed('act@host', nodedown),
    _ = barrel_p2p:active_view(),
    %% The bridge reports the dial as connected.
    ok = barrel_p2p_hyparview:peer_connected('pas@host', undefined),
    _ = barrel_p2p:active_view(),
    ?assertEqual(Pid, whereis(barrel_p2p_hyparview)),
    %% The peer accepts: it becomes active, and subscribers hear about it.
    ok = barrel_p2p_hyparview:handle_msg(
        {neighbor_reply, true, Passive#peer{connected = true}}, 'pas@host'
    ),
    ?assertEqual(['pas@host'], barrel_p2p:active_view()),
    ?assertEqual(ok, receive_event({peer_up, 'pas@host'})),
    ok.

receive_event(Event) ->
    receive
        {barrel_p2p_event, Event} -> ok;
        {barrel_p2p_event, _Other} -> receive_event(Event)
    after 1000 -> timeout
    end.

%% leave/0 used to clear the views without peer_down events, so subscribers
%% (Plumtree's eager set, the replicas) kept gossiping to peers this node had
%% left. Found by spec/tla/MC_hyparview_leave.
test_leave_emits_peer_down(_Config) ->
    Pid = whereis(barrel_p2p_hyparview),
    ok = barrel_p2p_hyparview_events:subscribe(self()),
    _ = sys:replace_state(Pid, fun(S) ->
        S#view_state{
            active_view = #{
                'a@host' => #peer{id = 'a@host', connected = true},
                'b@host' => #peer{id = 'b@host', connected = true}
            }
        }
    end),
    ok = barrel_p2p:leave(),
    ?assertEqual(ok, receive_event({peer_down, 'a@host', left})),
    ?assertEqual(ok, receive_event({peer_down, 'b@host', left})),
    ok.

%% Accepting a forward-join used to add the new peer on the dialer only: the
%% new peer's bridge does not report a channel it did not ask for, so the
%% link was one-sided. The dialer now sends it a high-priority NEIGHBOR.
%% Found by spec/tla/MC_hyparview_link.
test_forward_join_link_is_symmetric(_Config) ->
    Pid = whereis(barrel_p2p_hyparview),
    Self = self(),
    ok = meck:new(barrel_p2p_protocol, [passthrough, no_link]),
    try
        ok = meck:expect(barrel_p2p_protocol, send, fun(Node, Msg) ->
            Self ! {sent, Node, Msg},
            ok
        end),
        _ = sys:replace_state(Pid, fun(S) ->
            S#view_state{pending = #{'new@host' => {connect, make_ref(), undefined}}}
        end),
        ok = barrel_p2p_hyparview:peer_connected('new@host', undefined),
        _ = barrel_p2p:active_view(),
        ?assertEqual(['new@host'], barrel_p2p:active_view()),
        receive
            {sent, 'new@host', {neighbor, high, _}} -> ok
        after 1000 -> ct:fail(no_neighbor_sent)
        end
    after
        meck:unload(barrel_p2p_protocol)
    end,
    ok.

%% last_seen used native time units while cleanup compared it in
%% milliseconds, so passive entries never aged out; and a shuffled peer
%% record kept the sender's clock. Both now hold this node's monotonic ms.
test_last_seen_is_local_milliseconds(_Config) ->
    Now = erlang:monotonic_time(millisecond),
    Peer = barrel_p2p_hyparview:make_peer('x@host'),
    ?assert(abs(Peer#peer.last_seen - Now) < 1000),
    Foreign = #peer{id = 'y@host', last_seen = 123},
    Passive = barrel_p2p_hyparview:add_to_passive(Foreign, #{}, 5),
    #{'y@host' := Stored} = Passive,
    ?assert(abs(Stored#peer.last_seen - Now) < 1000),
    ok.

%% A promotion candidate whose dial fails used to vanish: it was taken out
%% of the passive view before the dial, and the failure was then recorded
%% against a passive entry that no longer existed. It now returns to the
%% passive view with its failure counted and a backoff set.
test_failed_candidate_backs_off(_Config) ->
    Pid = whereis(barrel_p2p_hyparview),
    Active = #peer{id = 'act@host', connected = true},
    Cand = #peer{id = 'cand@host', connected = false},
    _ = sys:replace_state(Pid, fun(S) ->
        S#view_state{active_view = #{'act@host' => Active}, passive_view = #{'cand@host' => Cand}}
    end),
    %% The active peer fails (a failed peer is not kept as a candidate), so
    %% cand@host is promoted. Its dial then fails (on this non-distributed
    %% test node the bridge never dials, so report the failure directly).
    ok = barrel_p2p_hyparview:peer_failed('act@host', nodedown),
    ok = barrel_p2p_hyparview:peer_failed('cand@host', connect_failed),
    _ = barrel_p2p:active_view(),
    #view_state{passive_view = Passive} = sys:get_state(Pid),
    ?assertMatch(#{'cand@host' := #peer{fail_count = 1}}, Passive),
    #{'cand@host' := #peer{backoff_until = Until}} = Passive,
    ?assert(is_integer(Until)),
    ok.

%% After leave/0 the node used to accept a high-priority NEIGHBOR from a
%% peer promoting it (that peer had just received our DISCONNECT and kept
%% us as a spare), so it was pulled straight back into the overlay. Found
%% by spec/tla/MC_hyparview_rejoin.
test_left_node_refuses_neighbor(_Config) ->
    Self = self(),
    ok = meck:new(barrel_p2p_protocol, [passthrough, no_link]),
    try
        ok = meck:expect(barrel_p2p_protocol, send, fun(Node, Msg) ->
            Self ! {sent, Node, Msg},
            ok
        end),
        ok = barrel_p2p:leave(),
        Peer = #peer{id = 'promoter@host', connected = true},
        ok = barrel_p2p_hyparview:handle_msg({neighbor, high, Peer}, 'promoter@host'),
        _ = barrel_p2p:active_view(),
        ?assertEqual([], barrel_p2p:active_view()),
        receive
            {sent, 'promoter@host', {neighbor_reply, false, _}} -> ok
        after 1000 -> ct:fail(no_refusal_sent)
        end
    after
        meck:unload(barrel_p2p_protocol)
    end,
    ok.
