%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(mycelium_registry_sync).
-behaviour(gen_server).

-include("mycelium.hrl").

%% API
-export([start_link/0]).
-export([broadcast_update/1]).
-export([handle_peer_up/1, handle_peer_down/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(SYNC_TAG, '$mycelium_registry_sync').

-record(state, {
    %% Track known peers for sync
    peers = [] :: [node()]
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec broadcast_update(term()) -> ok.
broadcast_update(Update) ->
    gen_server:cast(?SERVER, {broadcast, Update}).

-spec handle_peer_up(node()) -> ok.
handle_peer_up(Node) ->
    gen_server:cast(?SERVER, {peer_up, Node}).

-spec handle_peer_down(node()) -> ok.
handle_peer_down(Node) ->
    gen_server:cast(?SERVER, {peer_down, Node}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Subscribe to Plumtree broadcasts
    ok = mycelium_plumtree:subscribe(self()),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({broadcast, {add, Key, Entry}}, State) ->
    Dot = {node(), mycelium_hlc:now()},
    Delta = #{Key => {value, Entry, #{Dot => true}}},
    mycelium_plumtree:broadcast(registry_sync, {delta, node(), Delta}),
    {noreply, State};

handle_cast({broadcast, {remove, Key}}, State) ->
    %% Tombstone-as-delta. The receiver's OR-Map merge resolves
    %% against any in-flight value entry by HLC, so a delayed add
    %% cannot resurrect the removed key.
    Delta = #{Key => {tombstone, mycelium_hlc:now()}},
    mycelium_plumtree:broadcast(registry_sync, {delta, node(), Delta}),
    {noreply, State};

handle_cast({peer_up, Node}, State) ->
    case lists:member(Node, State#state.peers) of
        true ->
            {noreply, State};
        false ->
            %% Schedule async full sync
            self() ! {do_full_sync, Node},
            {noreply, State#state{peers = [Node | State#state.peers]}}
    end;

handle_cast({peer_down, Node}, State) ->
    %% Remove entries from disconnected peer
    mycelium_registry:remove_node_entries(Node),
    %% Invalidate routes through this node
    mycelium_router:invalidate_route(Node),
    Peers = lists:delete(Node, State#state.peers),
    {noreply, State#state{peers = Peers}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({do_full_sync, Node}, State) ->
    %% Non-blocking full sync with OR-Map
    case lists:member(Node, State#state.peers) of
        true ->
            LocalORMap = mycelium_registry:get_local_ormap(),
            case mycelium_ormap:is_empty(LocalORMap) of
                true -> ok;
                false -> send_to_peer(Node, {full_sync, node(), LocalORMap})
            end;
        false ->
            ok
    end,
    {noreply, State};

handle_info({?SYNC_TAG, {full_sync, _FromNode, RemoteORMap}}, State) ->
    %% Apply full sync from peer - merge their OR-Map
    mycelium_registry:merge_remote(RemoteORMap),
    {noreply, State};

handle_info({plumtree_broadcast, {registry_sync, {delta, FromNode, DeltaMap}}}, State) ->
    %% Merge first so the registry's view reflects the delta before
    %% subscribers receive the event.
    mycelium_registry:merge_remote(DeltaMap),
    maps:foreach(
        fun({Name, _Node}, {value, _Entry, _Dots}) ->
                mycelium_service_events:notify(
                    {service_registered, Name, FromNode});
           ({Name, _Node}, {tombstone, _HLC}) ->
                mycelium_router:invalidate_route(Name),
                mycelium_service_events:notify(
                    {service_unregistered, Name, FromNode})
        end,
        DeltaMap
    ),
    {noreply, State};

%% Legacy point-to-point remove broadcast. Kept as a no-op fallback so
%% an old peer sending the obsolete shape does not raise a function
%% clause; the registry's tombstone path covers correctness.
handle_info({plumtree_broadcast, {registry_sync, {remove, FromNode, {Name, _Node}}}}, State) ->
    mycelium_router:invalidate_route(Name),
    mycelium_service_events:notify({service_unregistered, Name, FromNode}),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

send_to_peer(Node, Msg) ->
    erlang:send({?SERVER, Node}, {?SYNC_TAG, Msg}, [noconnect]).
