%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Per-map supervisor: starts the map owner, then its barrel_p2p_replica
%%% instance. `rest_for_one' enforces that order on every (re)start - the
%%% replica casts into the owner, so the owner must exist first; if the
%%% owner dies, the replica is restarted too (and re-attaches to the fresh
%%% owner, then full-syncs from peers).
-module(barrel_p2p_map_instance_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

start_link(Name, Opts) ->
    supervisor:start_link(?MODULE, {Name, Opts}).

init({Name, Opts}) ->
    SupFlags = #{strategy => rest_for_one, intensity => 10, period => 10},

    Owner = #{
        id => owner,
        start => {barrel_p2p_map, start_link, [Name, Opts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_map]
    },

    Replica = #{
        id => replica,
        start =>
            {barrel_p2p_replica, start_link, [
                #{
                    name => barrel_p2p_map:replica_name(Name),
                    callback => barrel_p2p_map
                }
            ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_replica]
    },

    {ok, {SupFlags, [Owner, Replica]}}.
