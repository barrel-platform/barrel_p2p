-module(mycelium_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Disable global's partition prevention - mycelium manages topology
    ok = application:set_env(kernel, prevent_overlapping_partitions, false),
    %% Disable auto-connect - HyParView controls the topology
    ok = application:set_env(kernel, dist_auto_connect, never),
    mycelium_sup:start_link().

stop(_State) ->
    ok.
