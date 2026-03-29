-module(mycelium_router).
-behaviour(gen_server).

-include("mycelium.hrl").
-include_lib("hlc/include/hlc.hrl").

%% API
-export([start_link/0]).
-export([find_route/1, find_service/1]).
-export([cache_route/2, invalidate_route/1, invalidate_all/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(ROUTE_CACHE, mycelium_route_cache).
-define(ROUTE_TAG, '$mycelium_route').

%% Route cache TTL (30 minutes in milliseconds)
-define(CACHE_TTL_MS, 1800000).

%% Default routing TTL (max hops)
-define(DEFAULT_TTL, 5).

%% Timeout for remote lookups (ms)
-define(LOOKUP_TIMEOUT, 5000).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Find route to a target node through the overlay
-spec find_route(node()) -> {direct, node()} | {via, node()} | no_route.
find_route(Target) when Target =:= node() ->
    {direct, Target};
find_route(Target) ->
    ActiveView = mycelium:active_view(),
    case lists:member(Target, ActiveView) of
        true ->
            {direct, Target};
        false ->
            case get_cached_route(Target) of
                {ok, ViaNode} ->
                    %% Verify cached route is still valid
                    case lists:member(ViaNode, ActiveView) of
                        true -> {via, ViaNode};
                        false ->
                            invalidate_route(Target),
                            find_next_hop(Target, ActiveView)
                    end;
                not_found ->
                    find_next_hop(Target, ActiveView)
            end
    end.

%% Find a service by name through overlay routing
-spec find_service(atom() | binary()) -> {found, node(), pid()} | {error, term()}.
find_service(ServiceName) ->
    Req = #route_req{
        service_name = ServiceName,
        ttl = ?DEFAULT_TTL,
        origin = node(),
        visited = [node()]
    },
    route_lookup(Req).

%% Cache a successful route
-spec cache_route(atom() | binary(), node()) -> ok.
cache_route(ServiceName, ViaNode) ->
    gen_server:cast(?SERVER, {cache_route, ServiceName, ViaNode}).

%% Invalidate cached route for a service
-spec invalidate_route(atom() | binary() | node()) -> ok.
invalidate_route(Key) ->
    gen_server:cast(?SERVER, {invalidate, Key}).

%% Invalidate all cached routes
-spec invalidate_all() -> ok.
invalidate_all() ->
    gen_server:cast(?SERVER, invalidate_all).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Create route cache ETS table
    ?ROUTE_CACHE = ets:new(?ROUTE_CACHE, [
        named_table,
        public,
        set,
        {read_concurrency, true}
    ]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({cache_route, ServiceName, ViaNode}, State) ->
    HLC = mycelium_hlc:now(),
    ets:insert(?ROUTE_CACHE, {ServiceName, ViaNode, HLC}),
    {noreply, State};

handle_cast({invalidate, Key}, State) ->
    ets:delete(?ROUTE_CACHE, Key),
    {noreply, State};

handle_cast(invalidate_all, State) ->
    ets:delete_all_objects(?ROUTE_CACHE),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({?ROUTE_TAG, {route_request, Req, ReplyTo}}, State) ->
    %% Handle incoming route request from another node
    spawn(fun() -> handle_route_request(Req, ReplyTo) end),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

%% Get cached route if fresh (uses HLC wall time for clock-skew-tolerant TTL)
get_cached_route(Key) ->
    case ets:lookup(?ROUTE_CACHE, Key) of
        [{_, ViaNode, CacheHLC}] ->
            CacheWall = mycelium_hlc:wall_time(CacheHLC),
            NowWall = mycelium_hlc:wall_time(mycelium_hlc:now()),
            case NowWall - CacheWall < ?CACHE_TTL_MS of
                true -> {ok, ViaNode};
                false ->
                    ets:delete(?ROUTE_CACHE, Key),
                    not_found
            end;
        [] ->
            not_found
    end.

%% Find next hop to forward to
find_next_hop(_Target, []) ->
    no_route;
find_next_hop(_Target, ActiveView) ->
    %% Random selection from active view
    NextHop = lists:nth(rand:uniform(length(ActiveView)), ActiveView),
    {via, NextHop}.

%% Route lookup through overlay
route_lookup(#route_req{ttl = 0}) ->
    {error, ttl_expired};
route_lookup(#route_req{service_name = Name, visited = Visited} = Req) ->
    %% Check local first
    case mycelium_registry:lookup_local(Name) of
        {ok, Pid} ->
            {found, node(), Pid};
        {error, not_found} ->
            %% Forward to active peers
            ActiveView = mycelium:active_view(),
            %% Exclude visited nodes and origin to prevent backtracking
            Candidates = ActiveView -- Visited,
            forward_to_peers(Req, Candidates)
    end.

%% Forward route request to peers
forward_to_peers(_Req, []) ->
    {error, not_found};
forward_to_peers(Req, Candidates) ->
    %% Try peers in random order
    Shuffled = shuffle(Candidates),
    forward_to_peers_sequential(Req, Shuffled).

forward_to_peers_sequential(_Req, []) ->
    {error, not_found};
forward_to_peers_sequential(Req, [Peer | Rest]) ->
    NewReq = Req#route_req{
        ttl = Req#route_req.ttl - 1,
        visited = [node() | Req#route_req.visited]
    },
    case send_route_request(Peer, NewReq) of
        {found, Node, Pid} ->
            %% Cache the route
            cache_route(Req#route_req.service_name, Peer),
            {found, Node, Pid};
        {error, _} ->
            forward_to_peers_sequential(Req, Rest)
    end.

%% Send route request to remote node
send_route_request(Node, Req) ->
    ReplyRef = make_ref(),
    ReplyTo = {self(), ReplyRef},
    erlang:send({?SERVER, Node}, {?ROUTE_TAG, {route_request, Req, ReplyTo}}, [noconnect]),
    receive
        {ReplyRef, Result} -> Result
    after ?LOOKUP_TIMEOUT ->
        {error, timeout}
    end.

%% Handle incoming route request (runs in spawned process)
handle_route_request(Req, {Caller, Ref}) ->
    Result = route_lookup(Req),
    %% Send reply back to caller
    erlang:send(Caller, {Ref, Result}, [noconnect]).

%% Shuffle a list randomly
shuffle([]) -> [];
shuffle(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), E} || E <- List])].
