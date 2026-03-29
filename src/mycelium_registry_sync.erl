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

handle_cast({broadcast, Update}, State) ->
    %% Use Plumtree for efficient epidemic broadcast
    mycelium_plumtree:broadcast(registry_sync, {delta, node(), [Update]}),
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
    %% Non-blocking full sync
    case lists:member(Node, State#state.peers) of
        true ->
            LocalEntries = mycelium_registry:get_all_local(),
            case LocalEntries of
                [] -> ok;
                _ -> send_to_peer(Node, {full_sync, node(), LocalEntries})
            end;
        false ->
            ok
    end,
    {noreply, State};

handle_info({?SYNC_TAG, {delta, FromNode, Updates}}, State) ->
    %% Apply delta updates (from direct peer-to-peer)
    lists:foreach(fun(Update) ->
        apply_update(FromNode, Update)
    end, Updates),
    {noreply, State};

handle_info({plumtree_broadcast, {registry_sync, {delta, FromNode, Updates}}}, State) ->
    %% Apply delta updates (from Plumtree broadcast)
    lists:foreach(fun(Update) ->
        apply_update(FromNode, Update)
    end, Updates),
    {noreply, State};

handle_info({?SYNC_TAG, {full_sync, FromNode, Entries}}, State) ->
    %% Apply full sync from peer
    mycelium_registry:merge_remote(FromNode, Entries),
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

apply_update(FromNode, {add, Entry}) ->
    mycelium_registry:merge_remote(FromNode, [Entry]),
    %% Emit remote service registered event
    mycelium_service_events:notify({service_registered, Entry#service_entry.name, FromNode});
apply_update(_FromNode, {remove, Name, Node}) ->
    %% Remove specific entry from remote cache
    mycelium_registry:remove_entry(Name, Node),
    %% Invalidate route cache for this service
    mycelium_router:invalidate_route(Name),
    %% Emit remote service unregistered event
    mycelium_service_events:notify({service_unregistered, Name, Node}),
    ok;
apply_update(_FromNode, {service_down, Name, _Reason}) ->
    %% Service went down - invalidate all routes to it
    mycelium_router:invalidate_route(Name),
    ok.
