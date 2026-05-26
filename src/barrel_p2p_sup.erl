%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(barrel_p2p_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },

    %% HLC must start first - other components depend on it
    HLC = #{
        id => barrel_p2p_hlc,
        start => {barrel_p2p_hlc, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_hlc]
    },

    %% Distribution keys manager - handles Ed25519 authentication keys
    DistKeys = #{
        id => barrel_p2p_dist_keys,
        start => {barrel_p2p_dist_keys, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_dist_keys]
    },

    HyparviewSup = #{
        id => barrel_p2p_hyparview_sup,
        start => {barrel_p2p_hyparview_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [barrel_p2p_hyparview_sup]
    },

    RegistrySup = #{
        id => barrel_p2p_registry_sup,
        start => {barrel_p2p_registry_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [barrel_p2p_registry_sup]
    },

    %% Leader election. Started after the registry so Plumtree and the
    %% HyParView event bus are already up (the sync worker subscribes to
    %% both in init). Leader before its sync: the sync casts into it.
    Leader = #{
        id => barrel_p2p_leader,
        start => {barrel_p2p_leader, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_leader]
    },

    LeaderSync = #{
        id => barrel_p2p_leader_replica,
        start =>
            {barrel_p2p_replica, start_link, [
                #{
                    name => barrel_p2p_leader_replica,
                    callback => barrel_p2p_leader
                }
            ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_replica]
    },

    %% Sharded placement. Started after the registry (Plumtree + event
    %% bus up). Shard before its replica instance: the replica casts into
    %% it, and the shard's first heartbeat is deferred to a timer.
    Shard = #{
        id => barrel_p2p_shard,
        start => {barrel_p2p_shard, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_shard]
    },

    ShardReplica = #{
        id => barrel_p2p_members_replica,
        start =>
            {barrel_p2p_replica, start_link, [
                #{
                    name => barrel_p2p_members_replica,
                    callback => barrel_p2p_shard
                }
            ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_replica]
    },

    %% Durable reminders. Started after the shard (it subscribes to
    %% ownership events and resolves owners via barrel_p2p_shard:place/1).
    %% Reminder before its replica instance: the replica casts into it.
    Reminder = #{
        id => barrel_p2p_reminder,
        start => {barrel_p2p_reminder, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_reminder]
    },

    ReminderReplica = #{
        id => barrel_p2p_reminder_replica,
        start =>
            {barrel_p2p_replica, start_link, [
                #{
                    name => barrel_p2p_reminder_replica,
                    callback => barrel_p2p_reminder
                }
            ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_replica]
    },

    PlumtreeSup = #{
        id => barrel_p2p_plumtree_sup,
        start => {barrel_p2p_plumtree_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [barrel_p2p_plumtree_sup]
    },

    %% Public replicated maps (barrel_p2p_map). Dynamic: starts empty and
    %% hosts whatever maps the app declares in `replicated_maps' or creates
    %% at runtime. After Plumtree + HyParView (the per-map replica
    %% subscribes to both).
    MapSup = #{
        id => barrel_p2p_map_sup,
        start => {barrel_p2p_map_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [barrel_p2p_map_sup]
    },

    Bridge = #{
        id => barrel_p2p_bridge,
        start => {barrel_p2p_bridge, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_bridge]
    },

    %% Tagged user-stream multiplex. Apps register their own tag and
    %% get a stream-shaped channel on top of quic_dist user streams.
    Streams = #{
        id => barrel_p2p_streams,
        start => {barrel_p2p_streams, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_streams]
    },

    %% Idle dist-channel GC. Reaps QUIC connections that are not in
    %% the HyParView active view and carry no live user streams.
    %% Architectural pillar of the decoupled design - not optional.
    DistGc = #{
        id => barrel_p2p_dist_gc,
        start => {barrel_p2p_dist_gc, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_dist_gc]
    },

    %% Seed bootstrap. Auto-joins the configured `contact_nodes' once the
    %% overlay (HyParView) and the bridge are up; idles on a seed (empty
    %% contact_nodes). Started last so join/active_view can reach them.
    Bootstrap = #{
        id => barrel_p2p_bootstrap,
        start => {barrel_p2p_bootstrap, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_bootstrap]
    },

    ChildSpecs = [
        HLC,
        DistKeys,
        HyparviewSup,
        PlumtreeSup,
        RegistrySup,
        Leader,
        LeaderSync,
        Shard,
        ShardReplica,
        Reminder,
        ReminderReplica,
        MapSup,
        Bridge,
        Streams,
        DistGc,
        Bootstrap
    ],
    {ok, {SupFlags, ChildSpecs}}.
