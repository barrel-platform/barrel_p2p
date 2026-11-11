%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Every replicated service must gossip a local write exactly as it stored
%%% it (same dots, same tombstone time), and must ship tombstone-only maps
%%% in full sync. Either gap lets a heal repair a peer with stale state:
%%% see spec/tla/ReplicaORMap.tla and
%%% barrel_p2p_replica_convergence_prop_tests.
-module(barrel_p2p_replica_write_path_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([map_write_path/1, registry_write_path/1, leader_write_path/1, reminder_write_path/1]).

all() ->
    [map_write_path, registry_write_path, leader_write_path, reminder_write_path].

init_per_testcase(_Case, Config) ->
    Dir = filename:join(?config(priv_dir, Config), "maps"),
    application:set_env(barrel_p2p, barrel_p2p_map_data_dir, Dir),
    %% Capture every broadcast; mocked before the app starts so the
    %% plumtree process runs the passthrough module from the beginning.
    Self = self(),
    ok = meck:new(barrel_p2p_plumtree, [passthrough, no_link]),
    ok = meck:expect(barrel_p2p_plumtree, broadcast, fun(Tag, Payload) ->
        Self ! {gossip, Tag, Payload},
        meck:passthrough([Tag, Payload])
    end),
    {ok, _} = application:ensure_all_started(barrel_p2p),
    Config.

end_per_testcase(_Case, _Config) ->
    application:stop(barrel_p2p),
    meck:unload(barrel_p2p_plumtree),
    ok.

%%====================================================================
%% Cases
%%====================================================================

map_write_path(_Config) ->
    {ok, _} = barrel_p2p:new_map(m),
    Replica = barrel_p2p_map:replica_name(m),
    Snapshot = fun() -> sync(barrel_p2p_map:replica_full_sync_snapshot(Replica)) end,
    ok = barrel_p2p:map_put(m, k, v),
    assert_gossiped(Replica, k, Snapshot()),
    ok = barrel_p2p:map_remove(m, k),
    assert_gossiped(Replica, k, Snapshot()),
    %% Tombstone-only map is still shipped.
    ?assertMatch(#{k := {tombstone, _}}, Snapshot()).

registry_write_path(_Config) ->
    Replica = barrel_p2p_registry_replica,
    Key = {svc, node()},
    Snapshot = fun() -> sync(barrel_p2p_registry:replica_full_sync_snapshot(Replica)) end,
    ok = barrel_p2p:register_service(svc),
    assert_gossiped(Replica, Key, Snapshot()),
    ok = barrel_p2p:unregister_service(svc),
    assert_gossiped(Replica, Key, Snapshot()),
    ?assertMatch(#{Key := {tombstone, _}}, Snapshot()).

leader_write_path(_Config) ->
    Replica = barrel_p2p_leader_replica,
    Key = {elect, node()},
    Snapshot = fun() ->
        {Cands, _Fences} = sync(barrel_p2p_leader:replica_full_sync_snapshot(Replica)),
        Cands
    end,
    _ = barrel_p2p:lead(elect),
    assert_gossiped(Replica, Key, Snapshot()),
    ok = barrel_p2p:resign(elect),
    assert_gossiped(Replica, Key, Snapshot()),
    ?assertMatch(#{Key := {tombstone, _}}, Snapshot()).

reminder_write_path(_Config) ->
    Replica = barrel_p2p_reminder_replica,
    Snapshot = fun() -> sync(barrel_p2p_reminder:replica_full_sync_snapshot(Replica)) end,
    ok = barrel_p2p:remind_after(r, 60000, payload),
    assert_gossiped(Replica, r, Snapshot()),
    ok = barrel_p2p:cancel_reminder(r),
    assert_gossiped(Replica, r, Snapshot()),
    ?assertMatch(#{r := {tombstone, _}}, Snapshot()).

%%====================================================================
%% Helpers
%%====================================================================

sync({sync, Snap}) -> Snap;
sync(empty) -> ct:fail(empty_snapshot).

%% The next delta gossiped for Key must be the entry the owner stores.
assert_gossiped(Replica, Key, Stored) ->
    ?assertEqual(#{Key => maps:get(Key, Stored)}, next_delta(Replica, Key)).

next_delta(Replica, Key) ->
    receive
        {gossip, Replica, {delta, _From, #{Key := _} = Delta}} -> Delta
    after 2000 -> ct:fail({no_gossip, Replica, Key})
    end.
