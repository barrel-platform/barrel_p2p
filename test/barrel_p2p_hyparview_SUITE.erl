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
    test_pending_timeout_drops_stale_connect/1
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
            test_pending_timeout_drops_stale_connect
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
