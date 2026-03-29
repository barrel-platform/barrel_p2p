-module(mycelium_sup).
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

    HyparviewSup = #{
        id => mycelium_hyparview_sup,
        start => {mycelium_hyparview_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [mycelium_hyparview_sup]
    },

    RegistrySup = #{
        id => mycelium_registry_sup,
        start => {mycelium_registry_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [mycelium_registry_sup]
    },

    PlumtreeSup = #{
        id => mycelium_plumtree_sup,
        start => {mycelium_plumtree_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [mycelium_plumtree_sup]
    },

    Bridge = #{
        id => mycelium_bridge,
        start => {mycelium_bridge, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_bridge]
    },

    ChildSpecs = [HyparviewSup, PlumtreeSup, RegistrySup, Bridge],
    {ok, {SupFlags, ChildSpecs}}.
