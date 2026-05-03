%%% -*- erlang -*-
%%%
%%% Mycelium Circuit Supervisor
%%%
%%% Top supervisor wires:
%%%   - `mycelium_circuit_relay' (singleton, accepts incoming streams)
%%%   - `mycelium_circuit_pipe_sup' (simple_one_for_one for pipes)
%%%
%%% Pipes are dynamically started by both the public API
%%% (`mycelium_circuit:open/2', initiator role) and the relay
%%% (destination + relay roles).
%%%
%%% Copyright (c) 2026 Benoit Chesneau
%%% Apache License 2.0

-module(mycelium_circuit_sup).
-behaviour(supervisor).

-export([start_link/0, start_link_pipes/0]).
-export([
    start_pipe_initiator/6,
    start_pipe_destination/4,
    start_pipe_relay/4
]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, top).

%% @doc Initiator endpoint pipe: locally-driven endpoint that knows
%% the target and the path so it can repath on hop failure.
-spec start_pipe_initiator(
    quic_dist:stream_ref(),
    binary(),
    node(),
    [node()],
    pid(),
    map()
) -> {ok, pid()} | {error, term()}.
start_pipe_initiator(Stream, CircuitId, Target, FullPath, Owner, Opts) ->
    supervisor:start_child(mycelium_circuit_pipe_sup,
        [{initiator, Stream, CircuitId, Target, FullPath, Owner, Opts}]).

%% @doc Destination endpoint pipe: terminates the circuit. Pending
%% is the residual app data that arrived in the same chunk as CREATE.
-spec start_pipe_destination(
    quic_dist:stream_ref(),
    binary(),
    binary(),
    pid()
) -> {ok, pid()} | {error, term()}.
start_pipe_destination(Stream, CircuitId, Pending, Owner) ->
    supervisor:start_child(mycelium_circuit_pipe_sup,
        [{destination, Stream, CircuitId, Pending, Owner}]).

%% @doc Relay pipe: intermediate hop that splices two raw streams.
-spec start_pipe_relay(
    quic_dist:stream_ref(),
    quic_dist:stream_ref(),
    binary(),
    binary()
) -> {ok, pid()} | {error, term()}.
start_pipe_relay(In, Out, CircuitId, Pending) ->
    supervisor:start_child(mycelium_circuit_pipe_sup,
        [{relay, In, Out, CircuitId, Pending}]).

init(top) ->
    SupFlags = #{strategy => one_for_one, intensity => 10, period => 10},
    PipeSup = #{
        id => mycelium_circuit_pipe_sup,
        start => {?MODULE, start_link_pipes, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [?MODULE]
    },
    Relay = #{
        id => mycelium_circuit_relay,
        start => {mycelium_circuit_relay, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_circuit_relay]
    },
    {ok, {SupFlags, [PipeSup, Relay]}};
init(pipes) ->
    SupFlags = #{strategy => simple_one_for_one, intensity => 10, period => 10},
    Spec = #{
        id => mycelium_circuit_pipe,
        start => {mycelium_circuit_pipe, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [mycelium_circuit_pipe]
    },
    {ok, {SupFlags, [Spec]}}.

%% @private Bridge for the pipe sub-supervisor (invoked by the top
%% spec above).
start_link_pipes() ->
    supervisor:start_link({local, mycelium_circuit_pipe_sup}, ?MODULE, pipes).
