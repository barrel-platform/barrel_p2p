-module(mycelium_router).
-behaviour(gen_server).

-include("mycelium.hrl").
-include_lib("hlc/include/hlc.hrl").

%% API
-export([start_link/0]).
-export([find_route/1, find_service/1]).
-export([cache_route/2, invalidate_route/1, invalidate_all/0]).
%% Path-selection API for circuits.
-export([find_path/1, find_path/2, invalidate_path/1, invalidate_all_paths/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(ROUTE_CACHE, mycelium_route_cache).
-define(PATH_CACHE, mycelium_path_cache).
-define(ROUTE_TAG, '$mycelium_route').

%% Route cache TTL (30 minutes in milliseconds)
-define(CACHE_TTL_MS, 1800000).

%% Path cache TTL: shorter than route cache because RTT can change.
-define(PATH_CACHE_TTL_MS, 30000).

%% Default routing TTL (max hops)
-define(DEFAULT_TTL, 5).

%% Default for circuit path probes.
-define(DEFAULT_PATH_TIMEOUT, 200).
-define(DEFAULT_PATH_MAX_HOPS, 4).

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
%% Path-selection API for circuits
%%====================================================================

-type find_path_opts() :: #{
    max_hops => pos_integer(),
    exclude  => [node()],
    timeout  => pos_integer()
}.

%% @doc Find a path from this node to `Target' using QUIC SRTT to
%% rank candidates. The path returned is the list of intermediate
%% hops (initiator and target excluded); empty when target is in
%% the local active view.
-spec find_path(node()) -> {ok, [node()], non_neg_integer()} | no_route.
find_path(Target) ->
    find_path(Target, #{}).

-spec find_path(node(), find_path_opts()) ->
    {ok, [node()], non_neg_integer()} | no_route.
find_path(Target, _Opts) when Target =:= node() ->
    {ok, [], 0};
find_path(Target, Opts) when is_atom(Target) ->
    Exclude = maps:get(exclude, Opts, []),
    case lists:member(Target, mycelium:active_view()) of
        true ->
            EstRtt = case mycelium_path_stats:srtt(Target) of
                {ok, Us} -> Us;
                _        -> 0
            end,
            {ok, [], EstRtt};
        false ->
            case lookup_cached_path(Target, Exclude) of
                {ok, Path, Rtt} ->
                    {ok, Path, Rtt};
                miss ->
                    do_probe(Target, Opts)
            end
    end.

-spec invalidate_path(node()) -> ok.
invalidate_path(Target) ->
    gen_server:cast(?SERVER, {invalidate_path, Target}).

-spec invalidate_all_paths() -> ok.
invalidate_all_paths() ->
    gen_server:cast(?SERVER, invalidate_all_paths).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Create route cache ETS table (service-name keyed; legacy).
    ?ROUTE_CACHE = ets:new(?ROUTE_CACHE, [
        named_table,
        public,
        set,
        {read_concurrency, true}
    ]),
    %% Path cache for circuit transport routing (target-node keyed).
    ?PATH_CACHE = ets:new(?PATH_CACHE, [
        named_table,
        public,
        set,
        {read_concurrency, true}
    ]),
    %% Subscribe to peer events so we can invalidate stale entries
    %% on disconnect.
    case whereis(mycelium_hyparview_events) of
        undefined -> ok;
        _Pid      -> mycelium_hyparview_events:subscribe(self())
    end,
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

handle_cast({invalidate_path, Target}, State) ->
    ets:delete(?PATH_CACHE, Target),
    {noreply, State};
handle_cast(invalidate_all_paths, State) ->
    ets:delete_all_objects(?PATH_CACHE),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({?ROUTE_TAG, {route_request, Req, ReplyTo}}, State) ->
    %% Handle incoming route request from another node
    spawn(fun() -> handle_route_request(Req, ReplyTo) end),
    {noreply, State};
handle_info({?ROUTE_TAG, {route_probe, Probe, ReplyTo}}, State) ->
    spawn(fun() -> handle_route_probe(Probe, ReplyTo) end),
    {noreply, State};

handle_info({peer_down, Node, _Reason}, State) ->
    %% Drop any cached path that mentions this node.
    invalidate_paths_through(Node),
    {noreply, State};
handle_info({peer_up, _Node}, State) ->
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

%% Shuffle a list randomly. Callers only pass non-empty lists.
shuffle(List) ->
    [X || {_, X} <- lists:sort([{rand:uniform(), E} || E <- List])].

%%====================================================================
%% Path-selection (find_path/2 internals)
%%====================================================================

%% Look up a fresh cached path. `Exclude' here means "the cached
%% path must not include any of these nodes". Stale entries are
%% deleted on miss.
lookup_cached_path(Target, Exclude) ->
    case ets:lookup(?PATH_CACHE, Target) of
        [{_, Path, EstRtt, CacheHLC}] ->
            CacheWall = mycelium_hlc:wall_time(CacheHLC),
            NowWall = mycelium_hlc:wall_time(mycelium_hlc:now()),
            Fresh = NowWall - CacheWall < ?PATH_CACHE_TTL_MS,
            Disjoint = not lists:any(fun(N) -> lists:member(N, Path) end,
                                     Exclude),
            case Fresh andalso Disjoint of
                true ->
                    {ok, Path, EstRtt};
                false ->
                    ets:delete(?PATH_CACHE, Target),
                    miss
            end;
        [] ->
            miss
    end.

cache_path(Target, Path, EstRtt) ->
    HLC = mycelium_hlc:now(),
    ets:insert(?PATH_CACHE, {Target, Path, EstRtt, HLC}),
    ok.

invalidate_paths_through(Node) ->
    Drop = ets:foldl(
        fun({Target, Path, _, _}, Acc) ->
            case lists:member(Node, Path) of
                true  -> [Target | Acc];
                false -> Acc
            end
        end, [], ?PATH_CACHE),
    [ets:delete(?PATH_CACHE, T) || T <- Drop],
    ok.

%% On-demand probe: ask each non-excluded active peer whether it can
%% reach Target. Currently a 2-hop probe (each peer answers from its
%% own active view); deeper probes are an extension.
do_probe(Target, Opts) ->
    MaxHops = maps:get(max_hops, Opts, ?DEFAULT_PATH_MAX_HOPS),
    Timeout = maps:get(timeout, Opts, ?DEFAULT_PATH_TIMEOUT),
    Exclude = maps:get(exclude, Opts, []),
    Active = mycelium:active_view() -- ([Target | Exclude]),
    case Active of
        [] ->
            no_route;
        Candidates ->
            ProbeId = make_ref(),
            Self = self(),
            ReplyTo = {Self, ProbeId},
            Probe = #{
                target => Target,
                hops => MaxHops - 1,
                visited => [node()],
                origin => node()
            },
            [erlang:send({?SERVER, Peer},
                         {?ROUTE_TAG, {route_probe, Probe, ReplyTo}},
                         [noconnect])
             || Peer <- Candidates],
            collect_probe_replies(ProbeId, Candidates, Timeout, Target)
    end.

collect_probe_replies(ProbeId, Candidates, Timeout, Target) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Replies = collect_loop(ProbeId, length(Candidates), Deadline, []),
    case best_reply(Replies, Target) of
        no_route ->
            no_route;
        {ok, Path, EstRtt} ->
            cache_path(Target, Path, EstRtt),
            {ok, Path, EstRtt}
    end.

collect_loop(_ProbeId, 0, _Deadline, Acc) ->
    Acc;
collect_loop(ProbeId, N, Deadline, Acc) ->
    Now = erlang:monotonic_time(millisecond),
    Wait = max(0, Deadline - Now),
    receive
        {ProbeId, Reply} ->
            collect_loop(ProbeId, N - 1, Deadline, [Reply | Acc])
    after Wait ->
        Acc
    end.

%% Pick the lowest-cumulative-RTT reply. Each reply is
%% `{Replier, Path, AccRtt}' where Path includes the replier and
%% AccRtt is the replier's local cumulative srtt to Target.
best_reply([], _Target) ->
    no_route;
best_reply(Replies, _Target) ->
    %% Add the initiator's own srtt to the replier's first hop.
    Scored = [{cum_rtt(R), Path}
              || {Replier, Path, _} = R <- Replies,
                 (cum_rtt(R) =/= undefined),
                 (Replier =/= undefined),
                 Path =/= []],
    case lists:sort(Scored) of
        [] ->
            no_route;
        [{Best, BestPath} | _] ->
            {ok, BestPath, Best}
    end.

cum_rtt({Replier, _Path, RemoteRtt}) ->
    case mycelium_path_stats:srtt(Replier) of
        {ok, LocalRtt} ->
            LocalRtt + (case RemoteRtt of N when is_integer(N) -> N; _ -> 0 end);
        _ ->
            undefined
    end.

%% Server-side probe handler (runs in a spawned process per probe).
handle_route_probe(Probe, {Caller, Ref}) ->
    Target = maps:get(target, Probe),
    case lists:member(Target, mycelium:active_view()) of
        true ->
            RemoteRtt = case mycelium_path_stats:srtt(Target) of
                {ok, Us} -> Us;
                _        -> 0
            end,
            erlang:send(Caller, {Ref, {node(), [node()], RemoteRtt}},
                        [noconnect]);
        false ->
            %% No multi-hop forwarding for now (recursion would go here).
            erlang:send(Caller, {Ref, {node(), [], no_path}},
                        [noconnect])
    end.
