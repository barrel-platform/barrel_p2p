-module(mycelium_circuit_transport).

%% Circuit transport abstraction
%%
%% Provides a behaviour for circuit transports and a generic API that
%% delegates to the configured transport module. Supports TCP now and
%% can be extended for QUIC streams later.
%%
%% One connection per peer design:
%% - First circuit to peer -> establish connection
%% - Connection stays open while any circuit exists to that peer
%% - All circuits to peer closed -> close connection
%% - Connection breaks -> notify all circuits (transport_down message)

-include("mycelium.hrl").

%% Behaviour callbacks
-callback start_link(Opts :: map()) -> {ok, pid()} | {error, term()}.
-callback connect(Node :: node(), Opts :: map()) -> {ok, conn_ref()} | {error, term()}.
-callback send(ConnRef :: conn_ref(), CircuitId :: #circuit_id{}, Data :: binary()) ->
    ok | {error, term()}.
-callback close(ConnRef :: conn_ref()) -> ok.
-callback get_connection(Node :: node()) -> {ok, conn_ref()} | {error, term()}.
-callback release_connection(Node :: node(), ConnRef :: conn_ref()) -> ok.
-callback register_circuit(Node :: node(), CircuitId :: #circuit_id{}, CircuitPid :: pid()) -> ok.
-callback unregister_circuit(Node :: node(), CircuitId :: #circuit_id{}) -> ok.

%% Type exports
-export_type([conn_ref/0]).

%% API
-export([
    send/3,
    get_connection/1,
    release_connection/2,
    register_circuit/3,
    unregister_circuit/2,
    get_transport_module/0
]).

%% Opaque connection reference - transport-specific
%% TCP: {tcp, Socket, ConnectionPid}
%% QUIC: {quic, Connection, StreamId}
-type conn_ref() :: {atom(), term()} | {atom(), term(), term()}.

%%====================================================================
%% API
%%====================================================================

%% @doc Send data to a node through the circuit transport.
%% Gets a pooled connection and sends the message.
-spec send(Node :: node(), CircuitId :: #circuit_id{}, Data :: binary()) ->
    ok | {error, term()}.
send(Node, CircuitId, Data) ->
    Mod = get_transport_module(),
    case Mod:get_connection(Node) of
        {ok, Conn} ->
            Result = Mod:send(Conn, CircuitId, Data),
            Mod:release_connection(Node, Conn),
            Result;
        Error ->
            Error
    end.

%% @doc Get a connection to a node from the pool.
-spec get_connection(Node :: node()) -> {ok, conn_ref()} | {error, term()}.
get_connection(Node) ->
    Mod = get_transport_module(),
    Mod:get_connection(Node).

%% @doc Release a connection back to the pool.
-spec release_connection(Node :: node(), ConnRef :: conn_ref()) -> ok.
release_connection(Node, ConnRef) ->
    Mod = get_transport_module(),
    Mod:release_connection(Node, ConnRef).

%% @doc Register a circuit on a connection.
%% The transport will monitor the circuit and notify it on connection failure.
-spec register_circuit(Node :: node(), CircuitId :: #circuit_id{}, CircuitPid :: pid()) -> ok.
register_circuit(Node, CircuitId, CircuitPid) ->
    Mod = get_transport_module(),
    Mod:register_circuit(Node, CircuitId, CircuitPid).

%% @doc Unregister a circuit from a connection.
%% If this is the last circuit on the connection, the connection will be closed.
-spec unregister_circuit(Node :: node(), CircuitId :: #circuit_id{}) -> ok.
unregister_circuit(Node, CircuitId) ->
    Mod = get_transport_module(),
    Mod:unregister_circuit(Node, CircuitId).

%% @doc Get the configured transport module.
-spec get_transport_module() -> module().
get_transport_module() ->
    application:get_env(mycelium, circuit_transport, mycelium_circuit_transport_tcp).
