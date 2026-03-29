-module(mycelium_hyparview_sup).
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
        id => mycelium_hyparview_events,
        start => {mycelium_hyparview_events, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_hyparview_events]
    },

    HyParView = #{
        id => mycelium_hyparview,
        start => {mycelium_hyparview, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_hyparview]
    },

    Shuffle = #{
        id => mycelium_hyparview_shuffle,
        start => {mycelium_hyparview_shuffle, start_link, [Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_hyparview_shuffle]
    },

    ChildSpecs = [Events, HyParView, Shuffle],
    {ok, {SupFlags, ChildSpecs}}.

get_config() ->
    #{
        active_size => application:get_env(mycelium, active_size, 5),
        passive_size => application:get_env(mycelium, passive_size, 30),
        arwl => application:get_env(mycelium, arwl, 6),
        prwl => application:get_env(mycelium, prwl, 3),
        shuffle_length => application:get_env(mycelium, shuffle_length, 8),
        shuffle_period => application:get_env(mycelium, shuffle_period, 10000)
    }.
