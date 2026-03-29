-module(mycelium_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    %% Set distribution cookie automatically
    init_dist_cookie(),
    %% Disable global's partition prevention - mycelium manages topology
    ok = application:set_env(kernel, prevent_overlapping_partitions, false),
    %% Disable auto-connect - HyParView controls the topology
    ok = application:set_env(kernel, dist_auto_connect, never),
    mycelium_sup:start_link().

%% @doc Set the distribution cookie automatically.
%% Uses the configured dist_cookie or defaults to 'mycelium'.
%% This removes the need for users to set -setcookie on the command line.
%% Only sets cookie when running as a distributed node.
init_dist_cookie() ->
    case node() of
        nonode@nohost ->
            %% Not a distributed node, skip cookie setup
            ok;
        Node ->
            Cookie = application:get_env(mycelium, dist_cookie, mycelium),
            erlang:set_cookie(Node, Cookie)
    end.

stop(_State) ->
    ok.
