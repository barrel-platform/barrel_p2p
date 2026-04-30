-module(mycelium_circuit_transport).

%% Circuit transport facade
%%
%% Forwards every call to mycelium_circuit_transport_quic, which
%% multiplexes circuits as user streams over the per-peer mycelium_dist
%% QUIC connection.

-include("mycelium.hrl").

-export_type([conn_ref/0]).

-export([
    send/3,
    get_connection/1,
    release_connection/2,
    register_circuit/3,
    unregister_circuit/2
]).

-type conn_ref() :: {atom(), term()} | {atom(), term(), term()}.

-define(MOD, mycelium_circuit_transport_quic).

-spec send(Node :: node(), CircuitId :: #circuit_id{}, Data :: binary()) ->
    ok | {error, term()}.
send(Node, CircuitId, Data) ->
    case ?MOD:get_connection(Node) of
        {ok, Conn} ->
            Result = ?MOD:send(Conn, CircuitId, Data),
            ?MOD:release_connection(Node, Conn),
            Result;
        Error ->
            Error
    end.

-spec get_connection(Node :: node()) -> {ok, conn_ref()} | {error, term()}.
get_connection(Node) ->
    ?MOD:get_connection(Node).

-spec release_connection(Node :: node(), ConnRef :: conn_ref()) -> ok.
release_connection(Node, ConnRef) ->
    ?MOD:release_connection(Node, ConnRef).

-spec register_circuit(Node :: node(), CircuitId :: #circuit_id{}, CircuitPid :: pid()) -> ok.
register_circuit(Node, CircuitId, CircuitPid) ->
    ?MOD:register_circuit(Node, CircuitId, CircuitPid).

-spec unregister_circuit(Node :: node(), CircuitId :: #circuit_id{}) -> ok.
unregister_circuit(Node, CircuitId) ->
    ?MOD:unregister_circuit(Node, CircuitId).
