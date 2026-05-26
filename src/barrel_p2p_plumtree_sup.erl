%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(barrel_p2p_plumtree_sup).
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

    Plumtree = #{
        id => barrel_p2p_plumtree,
        start => {barrel_p2p_plumtree, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_plumtree]
    },

    ChildSpecs = [Plumtree],
    {ok, {SupFlags, ChildSpecs}}.
