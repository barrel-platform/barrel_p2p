%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Single-node logic coverage for durable reminders. As the sole
%%% member, this node owns every key, so reminders arm and fire locally.
%%% Multi-node durability (a survivor fires after the owner dies) is
%%% proven in mycelium_reminder_e2e_SUITE.
-module(mycelium_reminder_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).

-export([
    fires_as_sole_owner/1,
    remind_after_fires/1,
    delivers_stable_fence/1,
    cancel_prevents_fire/1,
    fires_exactly_once/1,
    reset_replaces_reminder/1,
    stale_add_does_not_resurrect/1
]).

all() ->
    [
        fires_as_sole_owner,
        remind_after_fires,
        delivers_stable_fence,
        cancel_prevents_fire,
        fires_exactly_once,
        reset_replaces_reminder,
        stale_add_does_not_resurrect
    ].

init_per_testcase(_Case, Config) ->
    %% Short timings so the cases run quickly.
    application:set_env(mycelium, member_heartbeat_ms, 100),
    application:set_env(mycelium, member_ttl_ms, 300),
    application:set_env(mycelium, member_skew_ms, 60000),
    application:set_env(mycelium, reminder_scan_ms, 200),
    {ok, _} = application:ensure_all_started(mycelium),
    ok = mycelium:subscribe_reminders(),
    Config.

end_per_testcase(_Case, _Config) ->
    application:stop(mycelium),
    ok.

%%====================================================================
%% Cases
%%====================================================================

fires_as_sole_owner(_Config) ->
    ?assert(mycelium:is_owner(rk)),
    ok = mycelium:remind(rk, now_ms() + 150, hello),
    receive
        {mycelium_reminder, rk, hello, Fence} ->
            ?assert(is_integer(Fence) andalso Fence >= 0)
    after 2000 ->
        ct:fail(reminder_did_not_fire)
    end.

remind_after_fires(_Config) ->
    ok = mycelium:remind_after(rk, 150, world),
    receive
        {mycelium_reminder, rk, world, _Fence} -> ok
    after 2000 ->
        ct:fail(reminder_after_did_not_fire)
    end.

delivers_stable_fence(_Config) ->
    ok = mycelium:remind(rk, now_ms() + 100, payload),
    Fence = receive
        {mycelium_reminder, rk, payload, F} -> F
    after 2000 ->
        ct:fail(no_fire)
    end,
    %% The fence is the packed version HLC: a positive, comparable id.
    ?assert(is_integer(Fence)),
    ?assert(Fence > 0).

cancel_prevents_fire(_Config) ->
    ok = mycelium:remind(rk, now_ms() + 400, nope),
    ok = mycelium:cancel_reminder(rk),
    receive
        {mycelium_reminder, rk, _, _} -> ct:fail(fired_after_cancel)
    after 900 ->
        ok
    end.

fires_exactly_once(_Config) ->
    ok = mycelium:remind(rk, now_ms() + 150, once),
    receive
        {mycelium_reminder, rk, once, _} -> ok
    after 2000 ->
        ct:fail(no_fire)
    end,
    %% No second delivery: the fire tombstones the entry, so neither the
    %% scan nor a re-merge re-arms it.
    receive
        {mycelium_reminder, rk, once, _} -> ct:fail(double_fire)
    after 800 ->
        ok
    end.

reset_replaces_reminder(_Config) ->
    %% Arm far out, then re-set the same key to fire soon with a new
    %% payload. The stale far-future timer must not fire the old payload.
    ok = mycelium:remind(rk, now_ms() + 60000, stale),
    ok = mycelium:remind(rk, now_ms() + 150, fresh),
    receive
        {mycelium_reminder, rk, fresh, _} -> ok;
        {mycelium_reminder, rk, stale, _} -> ct:fail(fired_stale_version)
    after 2000 ->
        ct:fail(no_fire)
    end,
    receive
        {mycelium_reminder, rk, _, _} -> ct:fail(unexpected_second_fire)
    after 600 ->
        ok
    end.

%% A delayed re-gossip of the original add (as mycelium_replica would
%% deliver it) must not resurrect a reminder that already fired: the
%% fire-time tombstone out-ranks the older add by HLC.
stale_add_does_not_resurrect(_Config) ->
    H = mycelium_hlc:now(),
    FireAt = now_ms() + 150,
    Val = {FireAt, boo, H},
    Delta = #{rk => {value, Val, #{{'ghost@127.0.0.1', H} => true}}},
    mycelium_reminder:replica_merge_delta(Delta),
    receive
        {mycelium_reminder, rk, boo, _} -> ok
    after 2000 ->
        ct:fail(no_fire)
    end,
    %% Replay the stale add; the tombstone written at fire time wins.
    mycelium_reminder:replica_merge_delta(Delta),
    receive
        {mycelium_reminder, rk, boo, _} -> ct:fail(resurrected)
    after 800 ->
        ok
    end.

%%====================================================================
%% Helpers
%%====================================================================

now_ms() ->
    erlang:system_time(millisecond).
