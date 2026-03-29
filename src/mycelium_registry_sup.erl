-module(mycelium_registry_sup).
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

    Registry = #{
        id => mycelium_registry,
        start => {mycelium_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_registry]
    },

    Sync = #{
        id => mycelium_registry_sync,
        start => {mycelium_registry_sync, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_registry_sync]
    },

    ChildSpecs = [Registry, Sync],
    {ok, {SupFlags, ChildSpecs}}.
