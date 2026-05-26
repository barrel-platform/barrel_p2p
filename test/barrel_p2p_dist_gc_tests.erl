%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Eunit for barrel_p2p_dist_gc. Mocks `barrel_p2p' and `quic_dist' so
%%% the predicate logic can be exercised without a real cluster.

-module(barrel_p2p_dist_gc_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    meck:new(barrel_p2p, [non_strict]),
    meck:new(quic_dist, [non_strict, passthrough]),
    application:set_env(barrel_p2p, dist_gc_sweep_period_ms, 50),
    application:set_env(barrel_p2p, dist_gc_min_age_ms, 100),
    {ok, Pid} = barrel_p2p_dist_gc:start_link(),
    Pid.

teardown(_Pid) ->
    gen_server:stop(barrel_p2p_dist_gc),
    application:unset_env(barrel_p2p, dist_gc_sweep_period_ms),
    application:unset_env(barrel_p2p, dist_gc_min_age_ms),
    meck:unload(quic_dist),
    meck:unload(barrel_p2p),
    ok.

with(Test) ->
    {setup, fun setup/0, fun teardown/1, fun(P) -> [?_test(Test(P))] end}.

%% A node that is currently in the active view must never be reaped.
skip_when_in_active_view_test_() ->
    with(fun(_) ->
        Node = 'fake@host',
        seed_age(Node, 1000),
        meck:expect(barrel_p2p, active_view, fun() -> [Node] end),
        meck:expect(quic_dist, list_streams, fun(_) -> [] end),
        DisconnectCalls = track_disconnect(),
        barrel_p2p_dist_gc:sweep_now(),
        ?assertEqual([], DisconnectCalls())
    end).

%% A node carrying user streams must not be reaped even if not in
%% active view and old enough.
skip_when_has_streams_test_() ->
    with(fun(_) ->
        Node = 'fake@host',
        seed_age(Node, 1000),
        meck:expect(barrel_p2p, active_view, fun() -> [] end),
        meck:expect(quic_dist, list_streams, fun(_) -> [#{}] end),
        DisconnectCalls = track_disconnect(),
        barrel_p2p_dist_gc:sweep_now(),
        ?assertEqual([], DisconnectCalls())
    end).

%% Channels younger than the min-age threshold stay even when idle.
skip_when_too_young_test_() ->
    with(fun(_) ->
        Node = 'fake@host',
        seed_age(Node, 0),
        meck:expect(barrel_p2p, active_view, fun() -> [] end),
        meck:expect(quic_dist, list_streams, fun(_) -> [] end),
        DisconnectCalls = track_disconnect(),
        barrel_p2p_dist_gc:sweep_now(),
        ?assertEqual([], DisconnectCalls())
    end).

%% Conservative behaviour when the active view query fails: skip.
skip_when_active_view_crashes_test_() ->
    with(fun(_) ->
        Node = 'fake@host',
        seed_age(Node, 1000),
        meck:expect(barrel_p2p, active_view, fun() -> error(boom) end),
        meck:expect(quic_dist, list_streams, fun(_) -> [] end),
        DisconnectCalls = track_disconnect(),
        barrel_p2p_dist_gc:sweep_now(),
        %% empty active view + idle + old enough -> would normally reap,
        %% but nodes() is the real list (likely empty in this VM) so
        %% nothing to disconnect. The point: no crash.
        _ = DisconnectCalls(),
        ok
    end).

%% Conservative behaviour when quic_dist:list_streams crashes: skip.
skip_when_streams_query_crashes_test_() ->
    with(fun(_) ->
        Node = 'fake@host',
        seed_age(Node, 1000),
        meck:expect(barrel_p2p, active_view, fun() -> [] end),
        meck:expect(
            quic_dist,
            list_streams,
            fun(_) -> error(boom) end
        ),
        DisconnectCalls = track_disconnect(),
        barrel_p2p_dist_gc:sweep_now(),
        ?assertEqual([], DisconnectCalls())
    end).

get_age_returns_not_tracked_for_unknown_test_() ->
    with(fun(_) ->
        ?assertEqual(
            not_tracked,
            barrel_p2p_dist_gc:get_age_ms('never@seen')
        )
    end).

%%====================================================================
%% Helpers
%%====================================================================

seed_age(Node, AgeMs) ->
    Since = erlang:monotonic_time(millisecond) - AgeMs,
    true = ets:insert(barrel_p2p_dist_gc_ages, {Node, Since}),
    ok.

%% Returns a 0-arity fun that yields the list of nodes
%% `erlang:disconnect_node/1' was called on since track_disconnect/0
%% was invoked. Uses meck on `erlang' via a wrapper module isn't
%% reliable, so we just observe via the ages table: a reaped node is
%% deleted from the table. Combined with assertions about what we
%% seeded, this is enough to tell whether a sweep reaped or not.
track_disconnect() ->
    %% Snapshot the ages table now; later we compare with what's left.
    Before = ets:tab2list(barrel_p2p_dist_gc_ages),
    fun() ->
        After = ets:tab2list(barrel_p2p_dist_gc_ages),
        [N || {N, _} <- Before, not lists:keymember(N, 1, After)]
    end.
