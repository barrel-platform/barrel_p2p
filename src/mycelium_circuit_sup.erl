-module(mycelium_circuit_sup).
-behaviour(supervisor).

%% Circuit subsystem supervisor
%%
%% Manages:
%%   - mycelium_circuit_relay: single process for relay operations
%%   - dynamic circuit processes: one per active circuit endpoint

-include("mycelium.hrl").

%% API
-export([
    start_link/0,
    start_circuit/6,
    start_circuit_dest/4
]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% @doc Start a circuit as initiator
-spec start_circuit(CircuitId :: #circuit_id{}, Role :: initiator,
                    Target :: node(), Hops :: [node()],
                    TTL :: pos_integer(), Owner :: pid()) ->
    {ok, pid()} | {error, term()}.
start_circuit(CircuitId, initiator, Target, Hops, TTL, Owner) ->
    supervisor:start_child(circuit_dynamic_sup,
        [initiator, CircuitId, Target, Hops, TTL, Owner]).

%% @doc Start a circuit as destination
-spec start_circuit_dest(CircuitId :: #circuit_id{},
                         CryptoSession :: #crypto_session{},
                         TTL :: pos_integer(), Owner :: pid()) ->
    {ok, pid()} | {error, term()}.
start_circuit_dest(CircuitId, CryptoSession, TTL, Owner) ->
    supervisor:start_child(circuit_dynamic_sup,
        [destination, CircuitId, CryptoSession, TTL, Owner]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 10
    },

    %% ETS table for circuit registry
    ets:new(mycelium_circuits, [named_table, public, {read_concurrency, true}]),

    %% Transport configuration
    TransportMod = application:get_env(
        mycelium, circuit_transport, mycelium_circuit_transport_quic),
    TransportOpts = #{
        listen_port => application:get_env(mycelium, circuit_listen_port, 0),
        pool_size => application:get_env(mycelium, circuit_pool_size, 3),
        idle_timeout => application:get_env(mycelium, circuit_pool_idle_timeout, 60000),
        connect_timeout => application:get_env(mycelium, circuit_connect_timeout, 5000),
        auth_enabled => application:get_env(mycelium, auth_enabled, true)
    },

    %% Metrics collector - start first
    Metrics = #{
        id => mycelium_circuit_metrics,
        start => {mycelium_circuit_metrics, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_circuit_metrics]
    },

    %% Reachability cache for direct connection optimization
    Reachability = #{
        id => mycelium_circuit_reachability,
        start => {mycelium_circuit_reachability, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_circuit_reachability]
    },

    %% NAT cache - stores local and peer NAT info
    NatCache = #{
        id => mycelium_nat_cache,
        start => {mycelium_nat_cache, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_nat_cache]
    },

    %% NAT discovery - STUN detection and UPnP/NAT-PMP mapping
    Nat = #{
        id => mycelium_nat,
        start => {mycelium_nat, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_nat]
    },

    %% Transport - must start before relay as relay uses transport.
    %% Module is selected via the `circuit_transport' app env;
    %% defaults to QUIC streams multiplexed on quic_dist.
    Transport = #{
        id => circuit_transport,
        start => {TransportMod, start_link, [TransportOpts]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [TransportMod]
    },

    %% Relay handler - singleton
    Relay = #{
        id => mycelium_circuit_relay,
        start => {mycelium_circuit_relay, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_circuit_relay]
    },

    %% UDP hole punching for NAT traversal
    HolePunch = #{
        id => mycelium_hole_punch,
        start => {mycelium_hole_punch, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_hole_punch]
    },

    %% Dynamic supervisor for circuit processes
    CircuitDynSup = #{
        id => circuit_dynamic_sup,
        start => {supervisor, start_link, [{local, circuit_dynamic_sup}, ?MODULE, [dynamic]]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [?MODULE]
    },

    ChildSpecs = [Metrics, Reachability, NatCache, Nat, Transport, HolePunch, Relay, CircuitDynSup],
    {ok, {SupFlags, ChildSpecs}};

%% Dynamic supervisor for circuit processes
init([dynamic]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 10
    },

    %% Child spec for dynamically started circuits
    %% Args are passed via start_child/2
    CircuitChild = #{
        id => mycelium_circuit,
        start => {mycelium_circuit, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_circuit]
    },

    {ok, {SupFlags, [CircuitChild]}}.
