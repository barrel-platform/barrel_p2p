-module(mycelium_circuit_reachability).
-behaviour(gen_server).

%% Direct reachability cache and probing for circuit optimization
%%
%% Caches probe results to avoid repeated TCP connect attempts.
%% Probes are done asynchronously to avoid blocking circuit creation.
%%
%% Cache entries have TTL:
%% - Successful probes: 5 minutes (configurable)
%% - Failed probes: 1 minute (configurable)

-include("mycelium.hrl").

%% API
-export([
    start_link/0,
    is_reachable/1,
    probe_async/1,
    probe_sync/1,
    invalidate/1,
    invalidate_all/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(CACHE_TABLE, mycelium_reachability_cache).
-define(DEFAULT_PROBE_TIMEOUT, 500).       %% 500ms probe timeout
-define(DEFAULT_CACHE_TTL, 300000).        %% 5 minute cache TTL
-define(DEFAULT_NEGATIVE_CACHE_TTL, 60000). %% 1 minute for failures

-record(state, {
    probe_pids = #{} :: #{node() => pid()}
}).

-record(cache_entry, {
    node       :: node(),
    reachable  :: boolean(),
    expires_at :: integer()
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Check if a node is directly reachable.
%% Returns true, false, or unknown if not in cache.
-spec is_reachable(node()) -> true | false | unknown.
is_reachable(Node) ->
    case is_probe_enabled() of
        false ->
            %% Probing disabled, return unknown to skip optimization
            unknown;
        true ->
            Now = erlang:monotonic_time(millisecond),
            case ets:lookup(?CACHE_TABLE, Node) of
                [#cache_entry{reachable = Reachable, expires_at = ExpiresAt}]
                  when ExpiresAt > Now ->
                    Reachable;
                _ ->
                    unknown
            end
    end.

%% @doc Start a background probe for a node.
%% Result will be cached when probe completes.
-spec probe_async(node()) -> ok.
probe_async(Node) ->
    case is_probe_enabled() of
        false -> ok;
        true -> gen_server:cast(?SERVER, {probe_async, Node})
    end.

%% @doc Probe a node synchronously and return result.
%% Also caches the result.
-spec probe_sync(node()) -> boolean().
probe_sync(Node) ->
    case is_probe_enabled() of
        false -> false;
        true -> gen_server:call(?SERVER, {probe_sync, Node}, get_probe_timeout() + 1000)
    end.

%% @doc Invalidate cache entry for a node.
-spec invalidate(node()) -> ok.
invalidate(Node) ->
    ets:delete(?CACHE_TABLE, Node),
    ok.

%% @doc Clear all cache entries.
-spec invalidate_all() -> ok.
invalidate_all() ->
    ets:delete_all_objects(?CACHE_TABLE),
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Create ETS table for cache
    ets:new(?CACHE_TABLE, [
        named_table,
        public,
        {keypos, #cache_entry.node},
        {read_concurrency, true}
    ]),
    {ok, #state{}}.

handle_call({probe_sync, Node}, _From, State) ->
    Result = do_probe(Node),
    cache_result(Node, Result),
    {reply, Result, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({probe_async, Node}, State) ->
    %% Check if already probing this node
    case maps:is_key(Node, State#state.probe_pids) of
        true ->
            %% Already probing, skip
            {noreply, State};
        false ->
            %% Check cache first - maybe another probe completed
            case is_reachable(Node) of
                unknown ->
                    %% Start probe
                    Parent = self(),
                    Pid = spawn_link(fun() ->
                        Result = do_probe(Node),
                        Parent ! {probe_result, Node, Result}
                    end),
                    NewPids = maps:put(Node, Pid, State#state.probe_pids),
                    {noreply, State#state{probe_pids = NewPids}};
                _ ->
                    %% Already cached
                    {noreply, State}
            end
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({probe_result, Node, Result}, State) ->
    cache_result(Node, Result),
    NewPids = maps:remove(Node, State#state.probe_pids),
    {noreply, State#state{probe_pids = NewPids}};

handle_info({'EXIT', Pid, _Reason}, State) ->
    %% Probe process died - remove from tracking
    NewPids = maps:filter(fun(_N, P) -> P =/= Pid end, State#state.probe_pids),
    {noreply, State#state{probe_pids = NewPids}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

do_probe(Node) ->
    case get_peer_address(Node) of
        {ok, Host, Port} ->
            Timeout = get_probe_timeout(),
            case gen_tcp:connect(Host, Port, [binary], Timeout) of
                {ok, Sock} ->
                    gen_tcp:close(Sock),
                    true;
                {error, _} ->
                    false
            end;
        {error, _} ->
            false
    end.

get_peer_address(Node) ->
    %% Try to get the circuit port for the node
    case mycelium_circuit_transport_tcp:get_peer_port(Node) of
        {ok, Port} ->
            case get_node_host(Node) of
                {ok, Host} -> {ok, Host, Port};
                Error -> Error
            end;
        {error, _} ->
            %% Try HyParView peer info
            case mycelium_hyparview:get_peer(Node) of
                {ok, Peer} when Peer#peer.port =/= undefined ->
                    Offset = application:get_env(mycelium, circuit_port_offset, 1),
                    CircuitPort = Peer#peer.port + Offset,
                    case Peer#peer.address of
                        undefined ->
                            case get_node_host(Node) of
                                {ok, Host} -> {ok, Host, CircuitPort};
                                Error -> Error
                            end;
                        Address ->
                            {ok, Address, CircuitPort}
                    end;
                _ ->
                    %% Fallback: get host from node name, use default port
                    case get_node_host(Node) of
                        {ok, Host} ->
                            DefaultPort = application:get_env(mycelium, circuit_listen_port, 4370),
                            {ok, Host, DefaultPort};
                        Error ->
                            Error
                    end
            end
    end.

get_node_host(Node) ->
    NodeStr = atom_to_list(Node),
    case string:split(NodeStr, "@") of
        [_, Host] ->
            case inet:parse_address(Host) of
                {ok, Addr} -> {ok, Addr};
                {error, _} ->
                    case inet:getaddr(Host, inet) of
                        {ok, Addr} -> {ok, Addr};
                        {error, _} ->
                            case inet:getaddr(Host, inet6) of
                                {ok, Addr} -> {ok, Addr};
                                Error -> Error
                            end
                    end
            end;
        _ ->
            {error, invalid_node_name}
    end.

cache_result(Node, Reachable) ->
    Now = erlang:monotonic_time(millisecond),
    TTL = case Reachable of
        true -> get_cache_ttl();
        false -> get_negative_cache_ttl()
    end,
    Entry = #cache_entry{
        node = Node,
        reachable = Reachable,
        expires_at = Now + TTL
    },
    ets:insert(?CACHE_TABLE, Entry).

%%====================================================================
%% Configuration Helpers
%%====================================================================

is_probe_enabled() ->
    application:get_env(mycelium, circuit_probe_direct, true).

get_probe_timeout() ->
    application:get_env(mycelium, circuit_probe_timeout, ?DEFAULT_PROBE_TIMEOUT).

get_cache_ttl() ->
    application:get_env(mycelium, circuit_reachability_cache_ttl, ?DEFAULT_CACHE_TTL).

get_negative_cache_ttl() ->
    application:get_env(mycelium, circuit_reachability_negative_ttl, ?DEFAULT_NEGATIVE_CACHE_TTL).
