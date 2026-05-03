%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(mycelium_service_proxy).
-behaviour(gen_server).

%% Proxy that forwards messages to remote service through overlay
%% Registered with global for transparency: global:whereis_name returns proxy pid

-include("mycelium.hrl").

%% API
-export([start_link/2]).
-export([relay/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(CALL_TIMEOUT, 10000).
-define(RELAY_TAG, '$mycelium_relay').

-record(state, {
    name :: atom() | binary(),
    target_node :: node()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(atom() | binary(), node()) -> {ok, pid()} | {error, term()}.
start_link(Name, TargetNode) ->
    gen_server:start_link(?MODULE, [Name, TargetNode], []).

%% Relay a call through this node to the target
-spec relay(atom() | binary(), node(), term()) -> term().
relay(Name, TargetNode, Request) ->
    %% Called via RPC from another node
    case mycelium_router:find_route(TargetNode) of
        {direct, _} ->
            %% We can reach target directly
            gen_server:call({Name, TargetNode}, Request, ?CALL_TIMEOUT);
        {via, NextHop} ->
            %% Forward to next hop
            rpc:call(NextHop, ?MODULE, relay, [Name, TargetNode, Request], ?CALL_TIMEOUT);
        no_route ->
            {error, no_route}
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Name, TargetNode]) ->
    %% Subscribe to service events for cleanup
    mycelium:subscribe(self()),
    {ok, #state{name = Name, target_node = TargetNode}}.

handle_call(Request, _From, #state{name = Name, target_node = Target} = State) ->
    Result = forward_call(Name, Target, Request),
    {reply, Result, State}.

handle_cast(Request, #state{name = Name, target_node = Target} = State) ->
    forward_cast(Name, Target, Request),
    {noreply, State}.

handle_info({mycelium_event, {service_down, Name, _Reason}}, #state{name = Name} = State) ->
    %% Service died on remote node, proxy should terminate
    {stop, normal, State};

handle_info({mycelium_event, _}, State) ->
    %% Ignore other events
    {noreply, State};

handle_info({'$mycelium_registry_sync', {service_down, Name, _Reason}}, #state{name = Name} = State) ->
    %% Service died on remote node (via sync broadcast)
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{name = Name}) ->
    %% Unregister from global if registered
    catch global:unregister_name(Name),
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

forward_call(Name, Target, Request) ->
    case mycelium_router:find_route(Target) of
        {direct, _} ->
            %% Direct connection exists
            try
                gen_server:call({Name, Target}, Request, ?CALL_TIMEOUT)
            catch
                exit:{noproc, _} -> {error, service_not_found};
                exit:{{nodedown, _}, _} -> {error, node_down};
                exit:{timeout, _} -> {error, timeout}
            end;
        {via, NextHop} ->
            %% Route through overlay
            case rpc:call(NextHop, ?MODULE, relay, [Name, Target, Request], ?CALL_TIMEOUT) of
                {badrpc, Reason} -> {error, Reason};
                Result -> Result
            end;
        no_route ->
            {error, no_route}
    end.

forward_cast(Name, Target, Request) ->
    case mycelium_router:find_route(Target) of
        {direct, _} ->
            gen_server:cast({Name, Target}, Request);
        {via, NextHop} ->
            %% Fire and forget through overlay
            spawn(fun() ->
                rpc:call(NextHop, gen_server, cast, [{Name, Target}, Request])
            end);
        no_route ->
            ok
    end.
