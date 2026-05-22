%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Generic replication driver for a gossiped OR-Map.
%%%
%%% One instance per feature (the service registry, leader election,
%%% ...). Each instance owns a Plumtree tag and a callback module. It
%%% handles the parts every replicated map needs:
%%%
%%%   - broadcast add/remove deltas as OR-Map entries,
%%%   - route incoming deltas to the owner's merge callback,
%%%   - full-sync to a peer on `peer_up',
%%%   - drop a node's entries on `peer_down'.
%%%
%%% The owner holds the actual OR-Map (so it can run its own side
%%% effects synchronously: emit events, recompute an election) and
%%% implements the `mycelium_replica' behaviour. Feature-specific
%%% gossip that is not a map delta (such as leader-election fencing
%%% tokens) rides the same tag via `broadcast_custom/2'.
%%%
%%% Instances share the Plumtree bus; each ignores payloads carrying
%%% another instance's tag.
-module(mycelium_replica).
-behaviour(gen_server).

%% API
-export([start_link/1]).
-export([broadcast_update/2, broadcast_custom/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SYNC_TAG, '$mycelium_replica').

%% Merge an incoming delta (one or more {Key, entry}) into the owner's
%% map and run its side effects.
-callback replica_merge_delta(Delta :: mycelium_ormap:ormap()) -> ok.

%% Apply a full snapshot received from a peer on connect.
-callback replica_apply_full_sync(Snapshot :: term()) -> ok.

%% Produce a snapshot to send to a newly connected peer, or `empty'
%% when there is nothing to send.
-callback replica_full_sync_snapshot() -> {sync, Snapshot :: term()} | empty.

%% Drop all entries owned by a node that left or failed.
-callback replica_remove_node(node()) -> ok.

%% Merge a feature-specific custom broadcast (optional).
-callback replica_merge_custom(Payload :: term()) -> ok.

-optional_callbacks([replica_merge_custom/1]).

-record(state, {
    name  :: atom(),
    cb    :: module(),
    peers = [] :: [node()]
}).

%% The instance `name' is both the registered process name and the
%% Plumtree tag that scopes this instance's broadcasts.
-type config() :: #{name := atom(), callback := module()}.
-export_type([config/0]).

%%====================================================================
%% API
%%====================================================================

-spec start_link(config()) -> {ok, pid()} | {error, term()}.
start_link(#{name := Name} = Config) ->
    gen_server:start_link({local, Name}, ?MODULE, Config, []).

%% Broadcast an OR-Map add/remove on this instance.
-spec broadcast_update(atom(), {add, term(), term()} | {remove, term()}) -> ok.
broadcast_update(Name, Update) ->
    gen_server:cast(Name, {broadcast, Update}).

%% Broadcast a feature-specific payload on this instance's tag,
%% delivered to the owner's `replica_merge_custom/1'.
-spec broadcast_custom(atom(), term()) -> ok.
broadcast_custom(Name, Payload) ->
    gen_server:cast(Name, {broadcast_custom, Payload}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(#{name := Name, callback := Cb}) ->
    ok = mycelium_plumtree:subscribe(self()),
    ok = mycelium_hyparview_events:subscribe(self()),
    {ok, #state{name = Name, cb = Cb}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({broadcast, {add, Key, Val}}, #state{name = Name} = State) ->
    Dot = {node(), mycelium_hlc:now()},
    Delta = #{Key => {value, Val, #{Dot => true}}},
    mycelium_plumtree:broadcast(Name, {delta, node(), Delta}),
    {noreply, State};

handle_cast({broadcast, {remove, Key}}, #state{name = Name} = State) ->
    %% Tombstone-as-delta: the receiver's OR-Map merge resolves against
    %% any in-flight value by HLC, so a delayed add cannot resurrect it.
    Delta = #{Key => {tombstone, mycelium_hlc:now()}},
    mycelium_plumtree:broadcast(Name, {delta, node(), Delta}),
    {noreply, State};

handle_cast({broadcast_custom, Payload}, #state{name = Name} = State) ->
    mycelium_plumtree:broadcast(Name, {custom, node(), Payload}),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Plumtree delivery scoped to this instance (tag =:= our name).
handle_info({plumtree_broadcast, {MsgTag, Payload}}, #state{name = Name} = State)
  when MsgTag =:= Name ->
    handle_payload(Payload, State);

%% Plumtree delivery for another instance.
handle_info({plumtree_broadcast, _Other}, State) ->
    {noreply, State};

handle_info({mycelium_event, {peer_up, Node}}, #state{peers = Peers} = State) ->
    case Node =:= node() orelse lists:member(Node, Peers) of
        true ->
            {noreply, State};
        false ->
            self() ! {do_full_sync, Node},
            {noreply, State#state{peers = [Node | Peers]}}
    end;

handle_info({mycelium_event, {peer_down, Node, _Reason}},
            #state{cb = Cb, peers = Peers} = State) ->
    Cb:replica_remove_node(Node),
    {noreply, State#state{peers = lists:delete(Node, Peers)}};

handle_info({mycelium_event, _Other}, State) ->
    {noreply, State};

handle_info({do_full_sync, Node}, #state{name = Name, cb = Cb, peers = Peers} = State) ->
    case lists:member(Node, Peers) of
        true ->
            case Cb:replica_full_sync_snapshot() of
                empty        -> ok;
                {sync, Snap} -> send_to_peer(Name, Node, {full_sync, node(), Snap})
            end;
        false ->
            ok
    end,
    {noreply, State};

handle_info({?SYNC_TAG, {full_sync, _FromNode, Snapshot}}, #state{cb = Cb} = State) ->
    Cb:replica_apply_full_sync(Snapshot),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

handle_payload({delta, _FromNode, Delta}, #state{cb = Cb} = State) ->
    Cb:replica_merge_delta(Delta),
    {noreply, State};
handle_payload({custom, _FromNode, Payload}, #state{cb = Cb} = State) ->
    case erlang:function_exported(Cb, replica_merge_custom, 1) of
        true  -> Cb:replica_merge_custom(Payload);
        false -> ok
    end,
    {noreply, State};
handle_payload(_Other, State) ->
    {noreply, State}.

send_to_peer(Name, Node, Msg) ->
    erlang:send({Name, Node}, {?SYNC_TAG, Msg}, [noconnect]).
