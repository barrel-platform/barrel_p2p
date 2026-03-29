-module(mycelium_hyparview).
-behaviour(gen_server).
-include("mycelium.hrl").

%% API
-export([start_link/1, join/1, leave/0]).
-export([active_view/0, passive_view/0]).
-export([peer_connected/2, peer_disconnected/2, peer_failed/2]).
-export([initiate_shuffle/2]).

%% Protocol handlers (called by mycelium_protocol)
-export([handle_msg/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================

start_link(Config) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Config, []).

-spec join(node()) -> ok | {error, term()}.
join(ContactNode) ->
    gen_server:call(?SERVER, {join, ContactNode}).

-spec leave() -> ok.
leave() ->
    gen_server:call(?SERVER, leave).

-spec active_view() -> [node()].
active_view() ->
    gen_server:call(?SERVER, active_view).

-spec passive_view() -> [node()].
passive_view() ->
    gen_server:call(?SERVER, passive_view).

%% Called by bridge when Erlang connection established/lost
-spec peer_connected(node(), term()) -> ok.
peer_connected(Node, DHandle) ->
    gen_server:cast(?SERVER, {peer_connected, Node, DHandle}).

-spec peer_disconnected(node(), term()) -> ok.
peer_disconnected(Node, Reason) ->
    gen_server:cast(?SERVER, {peer_disconnected, Node, Reason}).

-spec peer_failed(node(), term()) -> ok.
peer_failed(Node, Reason) ->
    gen_server:cast(?SERVER, {peer_failed, Node, Reason}).

%% Called by shuffle timer
-spec initiate_shuffle(node(), pos_integer()) -> ok.
initiate_shuffle(Target, ShuffleLength) ->
    gen_server:cast(?SERVER, {initiate_shuffle, Target, ShuffleLength}).

%% Called by mycelium_protocol when HyParView message received
-spec handle_msg(hyparview_msg(), node()) -> ok.
handle_msg(Msg, From) ->
    gen_server:cast(?SERVER, {protocol_msg, Msg, From}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Config) ->
    Self = #peer{
        id = node(),
        address = get_self_address(),
        port = get_self_port(),
        connected = true,
        priority = high
    },
    State = #view_state{
        active_size = maps:get(active_size, Config, 5),
        passive_size = maps:get(passive_size, Config, 30),
        arwl = maps:get(arwl, Config, 6),
        prwl = maps:get(prwl, Config, 3),
        shuffle_length = maps:get(shuffle_length, Config, 8),
        shuffle_period = maps:get(shuffle_period, Config, 10000),
        self = Self
    },
    {ok, State}.

handle_call({join, ContactNode}, _From, State) ->
    case ContactNode =:= node() of
        true ->
            {reply, {error, cannot_join_self}, State};
        false ->
            Ref = make_ref(),
            Pending = maps:put(ContactNode, {join, Ref}, State#view_state.pending),
            mycelium_bridge:request_connect(ContactNode),
            {reply, ok, State#view_state{pending = Pending}}
    end;

handle_call(leave, _From, State) ->
    Self = State#view_state.self,
    maps:foreach(fun(Node, _Peer) ->
        mycelium_protocol:send(Node, {disconnect, Self}),
        mycelium_bridge:request_disconnect(Node)
    end, State#view_state.active_view),
    mycelium_hyparview_events:notify(left),
    {reply, ok, State#view_state{active_view = #{}, passive_view = #{}}};

handle_call(active_view, _From, State) ->
    {reply, maps:keys(State#view_state.active_view), State};

handle_call(passive_view, _From, State) ->
    {reply, maps:keys(State#view_state.passive_view), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({peer_connected, Node, _DHandle}, State) ->
    case maps:take(Node, State#view_state.pending) of
        {{join, _Ref}, NewPending} ->
            %% Initial join - send JOIN message
            Peer = make_peer(Node),
            Active = maps:put(Node, Peer, State#view_state.active_view),
            mycelium_protocol:send(Node, {join, State#view_state.self}),
            mycelium_hyparview_events:notify({peer_up, Node}),
            mycelium_registry_sync:handle_peer_up(Node),
            {noreply, State#view_state{active_view = Active, pending = NewPending}};
        {{connect, _Ref}, NewPending} ->
            %% Regular connect from passive promotion
            Peer = make_peer(Node),
            State1 = add_to_active_view(Peer, State#view_state{pending = NewPending}),
            mycelium_hyparview_events:notify({peer_up, Node}),
            mycelium_registry_sync:handle_peer_up(Node),
            {noreply, State1};
        error ->
            %% Incoming connection or unknown
            case maps:is_key(Node, State#view_state.active_view) of
                true ->
                    %% Already in active view
                    {noreply, State};
                false ->
                    Peer = make_peer(Node),
                    State1 = add_to_active_view(Peer, State),
                    mycelium_hyparview_events:notify({peer_up, Node}),
                    mycelium_registry_sync:handle_peer_up(Node),
                    {noreply, State1}
            end
    end;

handle_cast({peer_disconnected, Node, Reason}, State) ->
    handle_peer_removal(Node, Reason, graceful, State);

handle_cast({peer_failed, Node, Reason}, State) ->
    handle_peer_removal(Node, Reason, failed, State);

handle_cast({initiate_shuffle, Target, ShuffleLength}, State) ->
    case maps:is_key(Target, State#view_state.active_view) of
        true ->
            Peers = random_peers(State, ShuffleLength),
            TTL = State#view_state.prwl,
            Self = State#view_state.self,
            mycelium_protocol:send(Target, {shuffle, TTL, Peers, Self}),
            {noreply, State};
        false ->
            {noreply, State}
    end;

handle_cast({protocol_msg, {join, Sender}, _From}, State) ->
    State1 = handle_join(Sender, State),
    {noreply, State1};

handle_cast({protocol_msg, {forward_join, NewPeer, TTL, Sender}, _From}, State) ->
    State1 = handle_forward_join(NewPeer, TTL, Sender, State),
    {noreply, State1};

handle_cast({protocol_msg, {disconnect, Sender}, _From}, State) ->
    State1 = handle_disconnect(Sender, State),
    {noreply, State1};

handle_cast({protocol_msg, {neighbor, Priority, Sender}, _From}, State) ->
    State1 = handle_neighbor(Priority, Sender, State),
    {noreply, State1};

handle_cast({protocol_msg, {neighbor_reply, Accept, Sender}, _From}, State) ->
    State1 = handle_neighbor_reply(Accept, Sender, State),
    {noreply, State1};

handle_cast({protocol_msg, {shuffle, TTL, Peers, Sender}, _From}, State) ->
    State1 = handle_shuffle(TTL, Peers, Sender, State),
    {noreply, State1};

handle_cast({protocol_msg, {shuffle_reply, Peers, _Sender}, _From}, State) ->
    State1 = handle_shuffle_reply(Peers, State),
    {noreply, State1};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% HyParView Protocol Handlers
%%====================================================================

handle_join(Sender, State) ->
    %% Add sender to active view
    State1 = add_to_active_view(Sender, State),

    %% Forward join to all active peers (except sender)
    TTL = State1#view_state.arwl,
    Self = State1#view_state.self,
    maps:foreach(fun(Node, _P) when Node =/= Sender#peer.id ->
        mycelium_protocol:send(Node, {forward_join, Sender, TTL, Self});
        (_, _) -> ok
    end, State1#view_state.active_view),

    State1.

handle_forward_join(NewPeer, 0, _Sender, State) ->
    %% TTL expired - add to passive view if not self
    case NewPeer#peer.id =:= node() of
        true ->
            State;
        false ->
            Passive = add_to_passive(NewPeer, State#view_state.passive_view,
                                     State#view_state.passive_size),
            State#view_state{passive_view = Passive}
    end;

handle_forward_join(NewPeer, _TTL, _Sender, State) when NewPeer#peer.id =:= node() ->
    %% Ignore forward_join for self
    State;

handle_forward_join(NewPeer, TTL, Sender, State) ->
    ActiveSize = maps:size(State#view_state.active_view),
    PRWL = State#view_state.prwl,

    %% If TTL = PRWL, add to passive view
    State1 = case TTL =:= PRWL of
        true ->
            Passive = add_to_passive(NewPeer, State#view_state.passive_view,
                                     State#view_state.passive_size),
            State#view_state{passive_view = Passive};
        false ->
            State
    end,

    case ActiveSize < State1#view_state.active_size of
        true ->
            %% Room in active view - connect to new peer
            Ref = make_ref(),
            Pending = maps:put(NewPeer#peer.id, {connect, Ref}, State1#view_state.pending),
            mycelium_bridge:request_connect(NewPeer#peer.id),
            State1#view_state{pending = Pending};
        false ->
            %% Forward to random active peer
            Exclude = [Sender#peer.id, NewPeer#peer.id],
            case random_active_peer(State1#view_state.active_view, Exclude) of
                {ok, Target} ->
                    Self = State1#view_state.self,
                    mycelium_protocol:send(Target, {forward_join, NewPeer, TTL - 1, Self});
                none ->
                    ok
            end,
            State1
    end.

handle_disconnect(Sender, State) ->
    case maps:is_key(Sender#peer.id, State#view_state.active_view) of
        true ->
            Active = maps:remove(Sender#peer.id, State#view_state.active_view),
            Passive = add_to_passive(Sender, State#view_state.passive_view,
                                     State#view_state.passive_size),
            mycelium_hyparview_events:notify({peer_down, Sender#peer.id, graceful}),
            mycelium_registry_sync:handle_peer_down(Sender#peer.id),
            State1 = State#view_state{active_view = Active, passive_view = Passive},
            maybe_promote_passive(State1);
        false ->
            State
    end.

handle_neighbor(Priority, Sender, State) ->
    ActiveSize = maps:size(State#view_state.active_view),
    Accept = case Priority of
        high -> true;
        low -> ActiveSize < State#view_state.active_size
    end,
    mycelium_protocol:send(Sender#peer.id, {neighbor_reply, Accept, State#view_state.self}),
    case Accept of
        true ->
            add_to_active_view(Sender, State);
        false ->
            State
    end.

handle_neighbor_reply(true, Sender, State) ->
    add_to_active_view(Sender, State);
handle_neighbor_reply(false, _Sender, State) ->
    %% Rejected - try another passive peer
    maybe_promote_passive(State).

handle_shuffle(TTL, Peers, Sender, State) ->
    %% Filter out self from received peers
    FilteredPeers = [P || P <- Peers, P#peer.id =/= node()],

    %% Add received peers to passive view
    Passive = lists:foldl(fun(P, Acc) ->
        case maps:is_key(P#peer.id, State#view_state.active_view) of
            true -> Acc;
            false -> add_to_passive(P, Acc, State#view_state.passive_size)
        end
    end, State#view_state.passive_view, FilteredPeers),

    %% Send reply with our random peers
    ReplyPeers = random_peers(State, length(FilteredPeers)),
    mycelium_protocol:send(Sender#peer.id, {shuffle_reply, ReplyPeers, State#view_state.self}),

    case TTL > 0 of
        true ->
            %% Forward to random active peer
            Exclude = [Sender#peer.id],
            case random_active_peer(State#view_state.active_view, Exclude) of
                {ok, Target} ->
                    Self = State#view_state.self,
                    mycelium_protocol:send(Target, {shuffle, TTL - 1, FilteredPeers, Self});
                none ->
                    ok
            end;
        false ->
            ok
    end,

    State#view_state{passive_view = Passive}.

handle_shuffle_reply(Peers, State) ->
    %% Filter out self and nodes already in active view
    FilteredPeers = [P || P <- Peers,
                     P#peer.id =/= node(),
                     not maps:is_key(P#peer.id, State#view_state.active_view)],
    Passive = lists:foldl(fun(P, Acc) ->
        add_to_passive(P, Acc, State#view_state.passive_size)
    end, State#view_state.passive_view, FilteredPeers),
    State#view_state{passive_view = Passive}.

%%====================================================================
%% Internal Functions
%%====================================================================

handle_peer_removal(Node, Reason, Type, State) ->
    case maps:is_key(Node, State#view_state.active_view) of
        true ->
            Active = maps:remove(Node, State#view_state.active_view),
            %% Only add to passive if graceful disconnect
            State1 = case Type of
                graceful ->
                    Peer = maps:get(Node, State#view_state.active_view),
                    Passive = add_to_passive(Peer, State#view_state.passive_view,
                                            State#view_state.passive_size),
                    State#view_state{active_view = Active, passive_view = Passive};
                failed ->
                    %% Failed nodes don't go to passive view
                    State#view_state{active_view = Active}
            end,
            mycelium_hyparview_events:notify({peer_down, Node, Reason}),
            mycelium_registry_sync:handle_peer_down(Node),
            State2 = maybe_promote_passive(State1),
            {noreply, State2};
        false ->
            %% Remove from pending if present
            Pending = maps:remove(Node, State#view_state.pending),
            {noreply, State#view_state{pending = Pending}}
    end.

make_peer(Node) ->
    #peer{
        id = Node,
        address = undefined,
        port = undefined,
        connected = true,
        priority = low,
        last_seen = erlang:monotonic_time()
    }.

add_to_active_view(Peer, State) ->
    Active = State#view_state.active_view,
    case maps:size(Active) < State#view_state.active_size of
        true ->
            maps:put(Peer#peer.id, Peer, Active),
            State#view_state{active_view = maps:put(Peer#peer.id, Peer, Active)};
        false ->
            %% Need to drop someone
            Exclude = [Peer#peer.id],
            {DroppedNode, DroppedPeer} = random_active_peer_pair(Active, Exclude),

            %% Send disconnect to dropped peer
            mycelium_protocol:send(DroppedNode, {disconnect, State#view_state.self}),
            mycelium_bridge:request_disconnect(DroppedNode),
            mycelium_hyparview_events:notify({peer_down, DroppedNode, dropped}),
            mycelium_registry_sync:handle_peer_down(DroppedNode),

            Active1 = maps:remove(DroppedNode, Active),
            Active2 = maps:put(Peer#peer.id, Peer, Active1),

            %% Move dropped to passive
            Passive = add_to_passive(DroppedPeer, State#view_state.passive_view,
                                    State#view_state.passive_size),
            State#view_state{active_view = Active2, passive_view = Passive}
    end.

add_to_passive(Peer, Passive, MaxSize) ->
    %% Don't add self to passive view
    case Peer#peer.id =:= node() of
        true ->
            Passive;
        false ->
            case maps:is_key(Peer#peer.id, Passive) of
                true ->
                    %% Update existing entry
                    maps:put(Peer#peer.id, Peer#peer{connected = false}, Passive);
                false when map_size(Passive) >= MaxSize ->
                    %% Full, need to drop random
                    {ToRemove, _} = random_active_peer_pair(Passive, [Peer#peer.id]),
                    Passive1 = maps:remove(ToRemove, Passive),
                    maps:put(Peer#peer.id, Peer#peer{connected = false}, Passive1);
                false ->
                    maps:put(Peer#peer.id, Peer#peer{connected = false}, Passive)
            end
    end.

maybe_promote_passive(State) ->
    ActiveSize = maps:size(State#view_state.active_view),
    PassiveSize = maps:size(State#view_state.passive_view),
    case ActiveSize < State#view_state.active_size andalso PassiveSize > 0 of
        true ->
            {Node, _Peer} = random_active_peer_pair(State#view_state.passive_view, []),
            Passive = maps:remove(Node, State#view_state.passive_view),

            %% Send NEIGHBOR request with priority based on active view state
            Priority = case ActiveSize of
                0 -> high;
                _ -> low
            end,

            Ref = make_ref(),
            Pending = maps:put(Node, {neighbor, Ref}, State#view_state.pending),
            mycelium_protocol:send(Node, {neighbor, Priority, State#view_state.self}),
            mycelium_bridge:request_connect(Node),
            State#view_state{passive_view = Passive, pending = Pending};
        false ->
            State
    end.

random_active_peer(Active, Exclude) ->
    Candidates = maps:keys(Active) -- Exclude,
    case Candidates of
        [] -> none;
        _ -> {ok, lists:nth(rand:uniform(length(Candidates)), Candidates)}
    end.

random_active_peer_pair(Map, Exclude) ->
    Candidates = maps:to_list(Map),
    Filtered = [{K, V} || {K, V} <- Candidates, not lists:member(K, Exclude)],
    case Filtered of
        [] -> error(no_candidates);
        _ -> lists:nth(rand:uniform(length(Filtered)), Filtered)
    end.

random_peers(State, N) ->
    Active = maps:values(State#view_state.active_view),
    Passive = maps:values(State#view_state.passive_view),
    All = [State#view_state.self | Active ++ Passive],
    %% Shuffle and take N
    Shuffled = [X || {_, X} <- lists:sort([{rand:uniform(), P} || P <- All])],
    lists:sublist(Shuffled, N).

get_self_address() ->
    case application:get_env(mycelium, address) of
        {ok, Addr} -> Addr;
        undefined -> {127, 0, 0, 1}
    end.

get_self_port() ->
    case application:get_env(mycelium, listen_port) of
        {ok, Port} -> Port;
        undefined -> 0
    end.
