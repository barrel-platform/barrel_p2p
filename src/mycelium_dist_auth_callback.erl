%%% -*- erlang -*-
%%%
%%% Mycelium Distribution Auth Callback
%%%
%%% Adapter that plugs mycelium's Ed25519 identity protocol into the
%%% upstream `quic_dist_auth' behaviour. The actual handshake lives in
%%% `mycelium_dist_auth_stream'; this module exists only to expose the
%%% `(Conn, Side, Timeout) -> {ok, _} | {error, _}' contract that
%%% `quic_dist' calls between QUIC handshake and Erlang dist handshake.
%%%
%%% Wire it up via sys.config:
%%%
%%% ```
%%% {quic, [{dist, [
%%%     {auth_callback, {mycelium_dist_auth_callback, authenticate}},
%%%     {auth_handshake_timeout, 10000}
%%% ]}]}.
%%% '''
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%% Apache License 2.0
%%%

-module(mycelium_dist_auth_callback).

-behaviour(quic_dist_auth).

-export([authenticate/3]).

-spec authenticate(
    Conn :: pid(),
    Side :: client | server,
    Timeout :: timeout()
) ->
    {ok, node() | undefined} | {error, term()}.
authenticate(Conn, server, Timeout) ->
    mycelium_dist_auth_stream:authenticate_incoming(Conn, Timeout);
authenticate(Conn, client, Timeout) ->
    mycelium_dist_auth_stream:authenticate_outgoing(Conn, Timeout).
