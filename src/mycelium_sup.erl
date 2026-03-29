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

    %% HLC must start first - other components depend on it
    HLC = #{
        id => mycelium_hlc,
        start => {mycelium_hlc, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_hlc]
    },

    %% Distribution keys manager - handles Ed25519 authentication keys
    DistKeys = #{
        id => mycelium_dist_keys,
        start => {mycelium_dist_keys, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_dist_keys]
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

    CircuitSup = #{
        id => mycelium_circuit_sup,
        start => {mycelium_circuit_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [mycelium_circuit_sup]
    },

    ChildSpecs = [HLC, DistKeys, HyparviewSup, PlumtreeSup, RegistrySup, CircuitSup, Bridge],
    {ok, {SupFlags, ChildSpecs}}.
