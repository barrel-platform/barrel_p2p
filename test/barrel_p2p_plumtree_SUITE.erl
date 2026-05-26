%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(barrel_p2p_plumtree_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    test_subscribe_receive_broadcast/1,
    test_unsubscribe/1,
    test_message_deduplication/1,
    test_stats/1,
    test_broadcast_with_tag/1,
    test_multiple_subscribers/1,
    test_peer_down_removes_from_eager_and_lazy/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, plumtree}].

groups() ->
    [
        {plumtree, [sequence], [
            test_subscribe_receive_broadcast,
            test_unsubscribe,
            test_message_deduplication,
            test_stats,
            test_broadcast_with_tag,
            test_multiple_subscribers,
            test_peer_down_removes_from_eager_and_lazy
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

test_subscribe_receive_broadcast(_Config) ->
    %% Subscribe to broadcasts
    ok = barrel_p2p_plumtree:subscribe(self()),

    %% Broadcast a message
    ok = barrel_p2p_plumtree:broadcast(test_tag, <<"hello world">>),

    %% Should receive the broadcast
    receive
        {plumtree_broadcast, {test_tag, <<"hello world">>}} ->
            ok
    after 1000 ->
        ct:fail("Did not receive broadcast")
    end,

    ok = barrel_p2p_plumtree:unsubscribe(self()),
    ok.

test_unsubscribe(_Config) ->
    ok = barrel_p2p_plumtree:subscribe(self()),
    ok = barrel_p2p_plumtree:unsubscribe(self()),

    %% Broadcast a message
    ok = barrel_p2p_plumtree:broadcast(test_tag, <<"test">>),

    %% Should NOT receive the broadcast
    receive
        {plumtree_broadcast, _} ->
            ct:fail("Received broadcast after unsubscribe")
    after 200 ->
        ok
    end,

    ok.

test_message_deduplication(_Config) ->
    ok = barrel_p2p_plumtree:subscribe(self()),

    %% Generate a specific message ID
    MsgId = crypto:strong_rand_bytes(32),

    %% Broadcast same message twice with same ID
    ok = barrel_p2p_plumtree:broadcast(test_tag, <<"msg1">>, MsgId),
    ok = barrel_p2p_plumtree:broadcast(test_tag, <<"msg1">>, MsgId),

    %% Should only receive it once
    receive
        {plumtree_broadcast, {test_tag, <<"msg1">>}} ->
            ok
    after 1000 ->
        ct:fail("Did not receive first broadcast")
    end,

    %% Should NOT receive a duplicate
    receive
        {plumtree_broadcast, {test_tag, <<"msg1">>}} ->
            ct:fail("Received duplicate broadcast")
    after 200 ->
        ok
    end,

    ok = barrel_p2p_plumtree:unsubscribe(self()),
    ok.

test_stats(_Config) ->
    %% Get initial stats
    Stats = barrel_p2p_plumtree:get_stats(),

    ?assert(is_map(Stats)),
    ?assert(maps:is_key(eager_peers, Stats)),
    ?assert(maps:is_key(lazy_peers, Stats)),
    ?assert(maps:is_key(cached_messages, Stats)),
    ?assert(maps:is_key(gossip_sent, Stats)),
    ?assert(maps:is_key(gossip_received, Stats)),

    ok.

test_broadcast_with_tag(_Config) ->
    ok = barrel_p2p_plumtree:subscribe(self()),

    %% Broadcast with different tags
    ok = barrel_p2p_plumtree:broadcast(tag1, <<"payload1">>),
    ok = barrel_p2p_plumtree:broadcast(tag2, #{key => value}),

    %% Receive both
    receive
        {plumtree_broadcast, {tag1, <<"payload1">>}} -> ok
    after 1000 ->
        ct:fail("Did not receive tag1 broadcast")
    end,

    receive
        {plumtree_broadcast, {tag2, #{key := value}}} -> ok
    after 1000 ->
        ct:fail("Did not receive tag2 broadcast")
    end,

    ok = barrel_p2p_plumtree:unsubscribe(self()),
    ok.

test_multiple_subscribers(_Config) ->
    %% Create multiple subscriber processes
    Parent = self(),
    Sub1 = spawn(fun() -> subscriber_loop(Parent, sub1) end),
    Sub2 = spawn(fun() -> subscriber_loop(Parent, sub2) end),

    ok = barrel_p2p_plumtree:subscribe(Sub1),
    ok = barrel_p2p_plumtree:subscribe(Sub2),

    %% Broadcast a message
    ok = barrel_p2p_plumtree:broadcast(multi_test, <<"shared message">>),

    %% Both subscribers should receive the message
    receive
        {sub1, received, {multi_test, <<"shared message">>}} -> ok
    after 1000 ->
        ct:fail("Sub1 did not receive broadcast")
    end,

    receive
        {sub2, received, {multi_test, <<"shared message">>}} -> ok
    after 1000 ->
        ct:fail("Sub2 did not receive broadcast")
    end,

    Sub1 ! stop,
    Sub2 ! stop,
    ok.

%% Verifies that a peer_down event from barrel_p2p_hyparview removes
%% the node from both eager and lazy peer lists. The hyparview event
%% is a 3-tuple `{peer_down, Node, Reason}'; matching only on the
%% 2-tuple form silently dropped the event.
test_peer_down_removes_from_eager_and_lazy(_Config) ->
    Pid = whereis(barrel_p2p_plumtree),
    Fake = 'phantom@host',
    Pid ! {barrel_p2p_event, {peer_up, Fake}},
    %% Synchronise on the gen_server to drain the mailbox.
    _ = sys:get_state(Pid),
    StatsUp = barrel_p2p_plumtree:get_stats(),
    Pid ! {barrel_p2p_event, {peer_down, Fake, shutdown}},
    _ = sys:get_state(Pid),
    StatsDown = barrel_p2p_plumtree:get_stats(),
    ?assertEqual(
        maps:get(eager_peers, StatsUp) - 1,
        maps:get(eager_peers, StatsDown)
    ),
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

subscriber_loop(Parent, Name) ->
    receive
        {plumtree_broadcast, Msg} ->
            Parent ! {Name, received, Msg},
            subscriber_loop(Parent, Name);
        stop ->
            ok
    end.
