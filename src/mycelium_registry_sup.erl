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

    Router = #{
        id => mycelium_router,
        start => {mycelium_router, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_router]
    },

    ProxySup = #{
        id => mycelium_proxy_sup,
        start => {mycelium_proxy_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [mycelium_proxy_sup]
    },

    ChildSpecs = [Registry, Sync, Router, ProxySup],
    {ok, {SupFlags, ChildSpecs}}.
