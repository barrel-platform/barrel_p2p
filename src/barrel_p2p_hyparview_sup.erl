%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(barrel_p2p_hyparview_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => rest_for_one,
        intensity => 10,
        period => 10
    },

    Config = get_config(),

    Events = #{
        id => barrel_p2p_hyparview_events,
        start => {barrel_p2p_hyparview_events, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_hyparview_events]
    },

    HyParView = #{
        id => barrel_p2p_hyparview,
        start => {barrel_p2p_hyparview, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_hyparview]
    },

    Shuffle = #{
        id => barrel_p2p_hyparview_shuffle,
        start => {barrel_p2p_hyparview_shuffle, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_hyparview_shuffle]
    },

    Cleanup = #{
        id => barrel_p2p_hyparview_cleanup,
        start => {barrel_p2p_hyparview_cleanup, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [barrel_p2p_hyparview_cleanup]
    },

    ChildSpecs = [Events, HyParView, Shuffle, Cleanup],
    {ok, {SupFlags, ChildSpecs}}.

get_config() ->
    #{
        %% HyParView parameters
        active_size => application:get_env(barrel_p2p, active_size, 5),
        passive_size => application:get_env(barrel_p2p, passive_size, 30),
        arwl => application:get_env(barrel_p2p, arwl, 6),
        prwl => application:get_env(barrel_p2p, prwl, 3),
        shuffle_length => application:get_env(barrel_p2p, shuffle_length, 8),
        shuffle_period => application:get_env(barrel_p2p, shuffle_period, 10000),

        %% Churn handling parameters
        max_fail_count => application:get_env(barrel_p2p, max_fail_count, 5),
        base_backoff_ms => application:get_env(barrel_p2p, base_backoff_ms, 1000),
        passive_max_age_ms => application:get_env(barrel_p2p, passive_max_age_ms, 300000),
        passive_cleanup_period => application:get_env(barrel_p2p, passive_cleanup_period, 60000),
        churn_window_ms => application:get_env(barrel_p2p, churn_window_ms, 30000)
    }.
