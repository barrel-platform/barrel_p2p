%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(mycelium_bridge).
-behaviour(gen_server).

-export([start_link/0]).
-export([request_connect/1, request_disconnect/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {
    pending = #{} :: #{node() => connecting | disconnecting}
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec request_connect(node()) -> ok.
request_connect(Node) ->
    gen_server:cast(?SERVER, {request_connect, Node}).

-spec request_disconnect(node()) -> ok.
request_disconnect(Node) ->
    gen_server:cast(?SERVER, {request_disconnect, Node}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    net_kernel:monitor_nodes(true, [{node_type, visible}]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({request_connect, Node}, State) ->
    case maps:is_key(Node, State#state.pending) of
        true ->
            {noreply, State};
        false ->
            %% Spawn a process to attempt connection
            Self = self(),
            spawn_link(fun() ->
                case net_kernel:connect_node(Node) of
                    true ->
                        ok; %% nodeup will be received
                    false ->
                        Self ! {connect_failed, Node};
                    ignored ->
                        ok
                end
            end),
            Pending = maps:put(Node, connecting, State#state.pending),
            {noreply, State#state{pending = Pending}}
    end;

handle_cast({request_disconnect, Node}, State) ->
    erlang:disconnect_node(Node),
    Pending = maps:remove(Node, State#state.pending),
    {noreply, State#state{pending = Pending}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodeup, Node, _Info}, State) ->
    Pending = maps:remove(Node, State#state.pending),
    mycelium_hyparview:peer_connected(Node, undefined),
    {noreply, State#state{pending = Pending}};

handle_info({nodedown, Node, _Info}, State) ->
    Pending = maps:remove(Node, State#state.pending),
    mycelium_hyparview:peer_failed(Node, nodedown),
    {noreply, State#state{pending = Pending}};

handle_info({connect_failed, Node}, State) ->
    case maps:is_key(Node, State#state.pending) of
        true ->
            Pending = maps:remove(Node, State#state.pending),
            mycelium_hyparview:peer_failed(Node, connect_failed),
            {noreply, State#state{pending = Pending}};
        false ->
            {noreply, State}
    end;

%% Handle HyParView protocol messages
handle_info({'$mycelium_hyparview', From, Msg}, State) ->
    mycelium_protocol:handle_message({'$mycelium_hyparview', From, Msg}, self()),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
