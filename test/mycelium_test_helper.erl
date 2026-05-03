%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(mycelium_test_helper).

%% Helper module for integration tests
%% Provides functions that can be called via RPC to manage persistent processes

-export([
    start_service_holder/1,
    stop_service_holder/1
]).

%% Start a process that registers a service and stays alive
-spec start_service_holder(atom() | binary()) -> {ok, pid()} | {error, term()}.
start_service_holder(ServiceName) ->
    Parent = self(),
    Pid = spawn(fun() ->
        case mycelium:register_service(ServiceName, #{}) of
            ok ->
                Parent ! {self(), ok},
                holder_loop(ServiceName);
            {error, Reason} ->
                Parent ! {self(), {error, Reason}}
        end
    end),
    receive
        {Pid, ok} -> {ok, Pid};
        {Pid, {error, Reason}} -> {error, Reason}
    after 5000 ->
        exit(Pid, kill),
        {error, timeout}
    end.

%% Stop a service holder process
-spec stop_service_holder(pid()) -> ok.
stop_service_holder(Pid) ->
    Pid ! stop,
    ok.

%% Internal loop to keep the process alive
holder_loop(ServiceName) ->
    receive
        stop ->
            mycelium:unregister_service(ServiceName),
            ok;
        _ ->
            holder_loop(ServiceName)
    end.
