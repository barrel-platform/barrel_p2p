%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(barrel_p2p_registry_sup).
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

    ServiceEvents = #{
        id => barrel_p2p_service_events,
        start => {barrel_p2p_service_events, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_service_events]
    },

    Registry = #{
        id => barrel_p2p_registry,
        start => {barrel_p2p_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_registry]
    },

    Sync = #{
        id => barrel_p2p_registry_replica,
        start =>
            {barrel_p2p_replica, start_link, [
                #{
                    name => barrel_p2p_registry_replica,
                    callback => barrel_p2p_registry
                }
            ]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_replica]
    },

    Router = #{
        id => barrel_p2p_router,
        start => {barrel_p2p_router, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_router]
    },

    ProxySup = #{
        id => barrel_p2p_proxy_sup,
        start => {barrel_p2p_proxy_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [barrel_p2p_proxy_sup]
    },

    ChildSpecs = [ServiceEvents, Registry, Sync, Router, ProxySup],
    {ok, {SupFlags, ChildSpecs}}.
