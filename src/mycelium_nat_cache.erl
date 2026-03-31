-module(mycelium_nat_cache).
-behaviour(gen_server).

%% NAT Info Cache
%%
%% Caches local and peer NAT information with TTL-based expiration.
%% Local NAT info is discovered once and cached long-term (30 min default).
%% Peer NAT info is received via hello protocol and cached with shorter TTL.

-include("mycelium.hrl").

%% API
-export([
    start_link/0,
    get_local_nat/0,
    set_local_nat/1,
    get_peer_nat/1,
    set_peer_nat/2,
    invalidate_peer/1,
    invalidate_all_peers/0,
    list_peers/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(PEER_TABLE, mycelium_nat_peer_cache).
-define(DEFAULT_LOCAL_TTL, 1800000).   %% 30 minutes
-define(DEFAULT_PEER_TTL, 3600000).    %% 1 hour
-define(CLEANUP_INTERVAL, 60000).      %% Cleanup expired entries every minute

-record(state, {
    local_nat  :: #nat_info{} | undefined,
    cleanup_timer :: reference() | undefined
}).

-record(peer_entry, {
    node      :: node(),
    nat_info  :: #nat_info{},
    expires_at :: integer()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Get locally detected NAT info
-spec get_local_nat() -> {ok, #nat_info{}} | {error, not_discovered}.
get_local_nat() ->
    gen_server:call(?SERVER, get_local_nat).

%% @doc Set locally detected NAT info
-spec set_local_nat(#nat_info{}) -> ok.
set_local_nat(NatInfo) ->
    gen_server:call(?SERVER, {set_local_nat, NatInfo}).

%% @doc Get cached NAT info for a peer
-spec get_peer_nat(node()) -> {ok, #nat_info{}} | {error, not_found | expired}.
get_peer_nat(Node) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?PEER_TABLE, Node) of
        [#peer_entry{nat_info = NatInfo, expires_at = ExpiresAt}]
          when ExpiresAt > Now ->
            {ok, NatInfo};
        [#peer_entry{}] ->
            %% Expired, delete it
            ets:delete(?PEER_TABLE, Node),
            {error, expired};
        [] ->
            {error, not_found}
    end.

%% @doc Store NAT info for a peer
-spec set_peer_nat(node(), #nat_info{}) -> ok.
set_peer_nat(Node, NatInfo) ->
    gen_server:cast(?SERVER, {set_peer_nat, Node, NatInfo}).

%% @doc Invalidate cached NAT info for a peer
-spec invalidate_peer(node()) -> ok.
invalidate_peer(Node) ->
    ets:delete(?PEER_TABLE, Node),
    ok.

%% @doc Invalidate all peer NAT info
-spec invalidate_all_peers() -> ok.
invalidate_all_peers() ->
    ets:delete_all_objects(?PEER_TABLE),
    ok.

%% @doc List all cached peers with their NAT info
-spec list_peers() -> [{node(), #nat_info{}}].
list_peers() ->
    Now = erlang:monotonic_time(millisecond),
    ets:foldl(fun(#peer_entry{node = Node, nat_info = Info, expires_at = Exp}, Acc) ->
        case Exp > Now of
            true -> [{Node, Info} | Acc];
            false -> Acc
        end
    end, [], ?PEER_TABLE).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Create ETS table for peer NAT cache
    ets:new(?PEER_TABLE, [
        named_table,
        public,
        {keypos, #peer_entry.node},
        {read_concurrency, true}
    ]),

    %% Start cleanup timer
    TimerRef = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup_expired),

    {ok, #state{cleanup_timer = TimerRef}}.

handle_call(get_local_nat, _From, State) ->
    Reply = case State#state.local_nat of
        undefined -> {error, not_discovered};
        NatInfo ->
            Now = erlang:monotonic_time(millisecond),
            case NatInfo#nat_info.expires_at > Now of
                true -> {ok, NatInfo};
                false -> {error, not_discovered}
            end
    end,
    {reply, Reply, State};

handle_call({set_local_nat, NatInfo}, _From, State) ->
    %% Set expiry time if not already set
    Now = erlang:monotonic_time(millisecond),
    TTL = get_local_ttl(),
    UpdatedInfo = case NatInfo#nat_info.expires_at of
        undefined -> NatInfo#nat_info{
            discovered_at = Now,
            expires_at = Now + TTL
        };
        _ -> NatInfo
    end,
    {reply, ok, State#state{local_nat = UpdatedInfo}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({set_peer_nat, Node, NatInfo}, State) ->
    Now = erlang:monotonic_time(millisecond),
    TTL = get_peer_ttl(),
    ExpiresAt = Now + TTL,
    Entry = #peer_entry{
        node = Node,
        nat_info = NatInfo#nat_info{
            discovered_at = Now,
            expires_at = ExpiresAt
        },
        expires_at = ExpiresAt
    },
    ets:insert(?PEER_TABLE, Entry),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup_expired, State) ->
    cleanup_expired_entries(),
    TimerRef = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup_expired),
    {noreply, State#state{cleanup_timer = TimerRef}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

cleanup_expired_entries() ->
    Now = erlang:monotonic_time(millisecond),
    %% Use match_delete for efficiency
    ets:select_delete(?PEER_TABLE, [
        {#peer_entry{expires_at = '$1', _ = '_'},
         [{'<', '$1', Now}],
         [true]}
    ]).

get_local_ttl() ->
    application:get_env(mycelium, nat_local_cache_ttl, ?DEFAULT_LOCAL_TTL).

get_peer_ttl() ->
    application:get_env(mycelium, nat_cache_ttl, ?DEFAULT_PEER_TTL).
