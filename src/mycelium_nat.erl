-module(mycelium_nat).
-behaviour(gen_server).

%% NAT Discovery Facade
%%
%% Handles NAT type detection via STUN (RFC 5780) and port mapping
%% via UPnP/NAT-PMP using the erlang-nat library.
%%
%% On startup:
%% 1. Discovers NAT type using STUN
%% 2. Attempts UPnP/NAT-PMP port mapping
%% 3. Builds candidate list (host + srflx)
%% 4. Caches results in mycelium_nat_cache
%%
%% Periodically rediscovers (default: every 30 min) to handle
%% network changes or DHCP lease renewals.

-include("mycelium.hrl").

%% API
-export([
    start_link/0,
    discover/0,
    get_nat_type/0,
    get_external_address/0,
    add_port_mapping/2,
    delete_port_mapping/1,
    get_candidates/0,
    refresh/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(DEFAULT_DISCOVERY_INTERVAL, 1800000).  %% 30 minutes
-define(DEFAULT_MAPPING_LIFETIME, 7200).       %% 2 hours (in seconds)

-record(state, {
    nat_type       :: nat_type() | undefined,
    external_addr  :: inet:ip_address() | undefined,
    external_port  :: inet:port_number() | undefined,
    nat_ctx        :: term() | undefined,  %% erlang-nat context
    mappings       :: #{inet:port_number() => mapping()},
    candidates     :: [#candidate{}],
    discovery_timer :: reference() | undefined,
    stun_server_id :: term() | undefined   %% estun server ID
}).

-type mapping() :: #{
    internal_port := inet:port_number(),
    external_port := inet:port_number(),
    protocol := tcp | udp,
    lease_time := non_neg_integer(),
    expires_at := integer()
}.

%%====================================================================
%% API
%%====================================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Trigger NAT discovery (async)
-spec discover() -> ok.
discover() ->
    gen_server:cast(?SERVER, discover).

%% @doc Get detected NAT type
-spec get_nat_type() -> nat_type().
get_nat_type() ->
    case is_nat_enabled() of
        false -> unknown;
        true ->
            case mycelium_nat_cache:get_local_nat() of
                {ok, #nat_info{nat_type = Type}} -> Type;
                {error, _} -> unknown
            end
    end.

%% @doc Get external (STUN-discovered) address
-spec get_external_address() -> {ok, inet:ip_address(), inet:port_number()} | {error, term()}.
get_external_address() ->
    case is_nat_enabled() of
        false -> {error, nat_disabled};
        true ->
            case mycelium_nat_cache:get_local_nat() of
                {ok, #nat_info{external_addr = Addr, external_port = Port}}
                  when Addr =/= undefined ->
                    {ok, Addr, Port};
                {ok, _} ->
                    {error, no_external_address};
                {error, _} = Error ->
                    Error
            end
    end.

%% @doc Add a port mapping via UPnP/NAT-PMP
-spec add_port_mapping(inet:port_number(), tcp | udp) ->
    {ok, inet:port_number()} | {error, term()}.
add_port_mapping(InternalPort, Protocol) ->
    case is_upnp_enabled() of
        false -> {error, upnp_disabled};
        true -> gen_server:call(?SERVER, {add_mapping, InternalPort, Protocol}, 30000)
    end.

%% @doc Delete a port mapping
-spec delete_port_mapping(inet:port_number()) -> ok | {error, term()}.
delete_port_mapping(InternalPort) ->
    gen_server:call(?SERVER, {delete_mapping, InternalPort}).

%% @doc Get all connection candidates
-spec get_candidates() -> [#candidate{}].
get_candidates() ->
    case is_nat_enabled() of
        false -> [];
        true ->
            case mycelium_nat_cache:get_local_nat() of
                {ok, #nat_info{candidates = Candidates}} -> Candidates;
                {error, _} -> []
            end
    end.

%% @doc Force a NAT refresh
-spec refresh() -> ok.
refresh() ->
    gen_server:cast(?SERVER, refresh).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    case is_nat_enabled() of
        false ->
            {ok, #state{mappings = #{}, candidates = []}};
        true ->
            %% Start discovery after a short delay to let transport start
            erlang:send_after(1000, self(), do_discover),
            {ok, #state{mappings = #{}, candidates = []}}
    end.

handle_call({add_mapping, InternalPort, Protocol}, _From, State) ->
    {Reply, NewState} = do_add_mapping(InternalPort, Protocol, State),
    {reply, Reply, NewState};

handle_call({delete_mapping, InternalPort}, _From, State) ->
    {Reply, NewState} = do_delete_mapping(InternalPort, State),
    {reply, Reply, NewState};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(discover, State) ->
    NewState = do_discover(State),
    {noreply, NewState};

handle_cast(refresh, State) ->
    %% Cancel existing timer and rediscover
    cancel_timer(State#state.discovery_timer),
    NewState = do_discover(State),
    {noreply, NewState};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(do_discover, State) ->
    NewState = do_discover(State),
    {noreply, NewState};

handle_info(rediscover, State) ->
    NewState = do_discover(State),
    {noreply, NewState};

handle_info({mapping_expired, InternalPort}, State) ->
    %% Renew mapping before it expires
    case maps:get(InternalPort, State#state.mappings, undefined) of
        undefined ->
            {noreply, State};
        #{protocol := Protocol} ->
            {_Reply, NewState} = do_add_mapping(InternalPort, Protocol, State),
            {noreply, NewState}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% Cleanup all mappings
    maps:foreach(fun(Port, _) ->
        do_delete_mapping_internal(Port, State)
    end, State#state.mappings),
    ok.

%%====================================================================
%% Internal Functions - Discovery
%%====================================================================

do_discover(State) ->
    %% Cancel existing timer
    cancel_timer(State#state.discovery_timer),

    %% Initialize STUN server if needed
    ServerId = init_stun_server(State#state.stun_server_id),

    %% Discover NAT type and external address via estun
    {NatType, ExternalAddr, ExternalPort} = discover_nat_type(ServerId),

    %% Try to get/create NAT context for UPnP/NAT-PMP
    NatCtx = discover_nat_gateway(State#state.nat_ctx),

    %% Build candidate list
    Candidates = build_candidates(ExternalAddr, ExternalPort),

    %% Update cache
    Now = erlang:monotonic_time(millisecond),
    NatInfo = #nat_info{
        nat_type = NatType,
        external_addr = ExternalAddr,
        external_port = ExternalPort,
        candidates = Candidates,
        discovered_at = Now,
        expires_at = undefined  %% Will be set by cache
    },
    mycelium_nat_cache:set_local_nat(NatInfo),

    %% Schedule next discovery
    Interval = get_discovery_interval(),
    TimerRef = erlang:send_after(Interval, self(), rediscover),

    State#state{
        nat_type = NatType,
        external_addr = ExternalAddr,
        external_port = ExternalPort,
        nat_ctx = NatCtx,
        candidates = Candidates,
        discovery_timer = TimerRef,
        stun_server_id = ServerId
    }.

init_stun_server(undefined) ->
    %% Add STUN servers from config
    StunServers = get_stun_servers(),
    case StunServers of
        [] -> undefined;
        [{Host, Port} | _] ->
            try
                case estun:add_server(#{host => Host, port => Port}) of
                    {ok, ServerId} -> ServerId;
                    {error, _} -> undefined
                end
            catch
                _:_ -> undefined
            end
    end;
init_stun_server(ServerId) ->
    ServerId.

discover_nat_type(undefined) ->
    {unknown, undefined, undefined};
discover_nat_type(ServerId) ->
    %% Use estun for NAT discovery
    try
        %% First get external address
        case estun:discover() of
            {ok, #{address := ExtAddr, port := ExtPort}} ->
                %% Now determine NAT type
                NatType = discover_nat_behavior(ServerId, ExtAddr),
                {NatType, ExtAddr, ExtPort};
            {error, _} ->
                {unknown, undefined, undefined}
        end
    catch
        _:_ ->
            {unknown, undefined, undefined}
    end.

discover_nat_behavior(ServerId, MappedAddr) ->
    %% Check if we're behind NAT by comparing to local addresses
    LocalAddrs = get_local_addresses(),
    case lists:member(MappedAddr, LocalAddrs) of
        true ->
            public;  %% No NAT
        false ->
            %% Behind NAT, try to determine type
            try
                case estun:discover_nat(ServerId) of
                    {ok, #{mapping := Mapping, filtering := Filtering}} ->
                        classify_nat_type(Mapping, Filtering);
                    {error, _} ->
                        port_restricted  %% Default assumption
                end
            catch
                _:_ ->
                    port_restricted  %% Default assumption
            end
    end.

%% Classify NAT type based on RFC 5780 mapping and filtering behavior
classify_nat_type(endpoint_independent, endpoint_independent) ->
    full_cone;
classify_nat_type(endpoint_independent, address_dependent) ->
    restricted_cone;
classify_nat_type(endpoint_independent, address_and_port_dependent) ->
    port_restricted;
classify_nat_type(address_dependent, _) ->
    symmetric;
classify_nat_type(address_and_port_dependent, _) ->
    symmetric;
classify_nat_type(_, _) ->
    unknown.

get_local_addresses() ->
    case inet:getifaddrs() of
        {ok, Interfaces} ->
            lists:foldl(fun({_Name, Opts}, Acc) ->
                case proplists:get_value(addr, Opts) of
                    undefined -> Acc;
                    {127, _, _, _} -> Acc;  %% Skip loopback
                    Addr -> [Addr | Acc]
                end
            end, [], Interfaces);
        {error, _} ->
            []
    end.

discover_nat_gateway(undefined) ->
    %% Try to discover NAT gateway using erlang-nat
    case is_upnp_enabled() of
        false ->
            undefined;
        true ->
            try
                case nat:discover() of
                    {ok, Ctx} -> Ctx;
                    {error, _} -> undefined
                end
            catch
                _:_ -> undefined
            end
    end;
discover_nat_gateway(Ctx) ->
    %% Already have context, check if still valid
    try
        case nat:get_external_address(Ctx) of
            {ok, _} -> Ctx;
            {error, _} -> discover_nat_gateway(undefined)
        end
    catch
        _:_ -> discover_nat_gateway(undefined)
    end.

build_candidates(ExternalAddr, ExternalPort) ->
    LocalCandidates = build_local_candidates(),
    SrflxCandidates = case ExternalAddr of
        undefined -> [];
        _ -> [#candidate{
            type = srflx,
            address = ExternalAddr,
            port = ExternalPort,
            priority = 100  %% Medium priority
        }]
    end,
    LocalCandidates ++ SrflxCandidates.

build_local_candidates() ->
    case get_local_addresses() of
        [] -> [];
        Addrs ->
            %% Get our circuit listen port
            Port = try
                mycelium_circuit_transport_tcp:get_listen_port()
            catch
                _:_ -> undefined
            end,
            case Port of
                undefined -> [];
                _ ->
                    lists:map(fun(Addr) ->
                        #candidate{
                            type = host,
                            address = Addr,
                            port = Port,
                            priority = 200  %% High priority for local
                        }
                    end, Addrs)
            end
    end.

%%====================================================================
%% Internal Functions - Port Mapping
%%====================================================================

do_add_mapping(InternalPort, Protocol, State) ->
    case State#state.nat_ctx of
        undefined ->
            {{error, no_nat_gateway}, State};
        Ctx ->
            ProtoAtom = case Protocol of
                tcp -> tcp;
                udp -> udp;
                _ -> tcp
            end,
            Lifetime = get_mapping_lifetime(),
            try
                case nat:add_port_mapping(Ctx, ProtoAtom, InternalPort, InternalPort, Lifetime) of
                    {ok, _Since, _InternalPort, ExternalPort, _MappingLifetime} ->
                        %% Store mapping
                        Now = erlang:monotonic_time(millisecond),
                        Mapping = #{
                            internal_port => InternalPort,
                            external_port => ExternalPort,
                            protocol => ProtoAtom,
                            lease_time => Lifetime,
                            expires_at => Now + (Lifetime * 1000)
                        },
                        NewMappings = maps:put(InternalPort, Mapping, State#state.mappings),
                        %% Schedule renewal before expiry (90% of lifetime)
                        RenewalTime = trunc(Lifetime * 900),  %% 90% in milliseconds
                        erlang:send_after(RenewalTime, self(), {mapping_expired, InternalPort}),
                        {{ok, ExternalPort}, State#state{mappings = NewMappings}};
                    {error, Reason} ->
                        {{error, Reason}, State}
                end
            catch
                _:Error ->
                    {{error, Error}, State}
            end
    end.

do_delete_mapping(InternalPort, State) ->
    case maps:get(InternalPort, State#state.mappings, undefined) of
        undefined ->
            {ok, State};
        #{protocol := Protocol} ->
            do_delete_mapping_internal(InternalPort, Protocol, State),
            NewMappings = maps:remove(InternalPort, State#state.mappings),
            {ok, State#state{mappings = NewMappings}}
    end.

do_delete_mapping_internal(InternalPort, State) ->
    case maps:get(InternalPort, State#state.mappings, undefined) of
        undefined -> ok;
        #{protocol := Protocol} ->
            do_delete_mapping_internal(InternalPort, Protocol, State)
    end.

do_delete_mapping_internal(InternalPort, Protocol, State) ->
    case State#state.nat_ctx of
        undefined -> ok;
        Ctx ->
            try
                nat:delete_port_mapping(Ctx, Protocol, InternalPort, InternalPort)
            catch
                _:_ -> ok
            end
    end.

%%====================================================================
%% Configuration Helpers
%%====================================================================

is_nat_enabled() ->
    application:get_env(mycelium, nat_enabled, true).

is_upnp_enabled() ->
    application:get_env(mycelium, upnp_enabled, true).

get_discovery_interval() ->
    application:get_env(mycelium, nat_discovery_interval, ?DEFAULT_DISCOVERY_INTERVAL).

get_stun_servers() ->
    application:get_env(mycelium, stun_servers, [
        {"stun.l.google.com", 19302},
        {"stun1.l.google.com", 19302}
    ]).

get_mapping_lifetime() ->
    application:get_env(mycelium, upnp_mapping_lifetime, ?DEFAULT_MAPPING_LIFETIME).

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> erlang:cancel_timer(Ref).
