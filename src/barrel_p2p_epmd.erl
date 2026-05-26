%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Barrel P2P epmd_module shim.
%%%
%%% A thin alias for upstream `quic_epmd' so users can boot with
%%% `-epmd_module barrel_p2p_epmd' and keep the proto_dist + epmd_module
%%% names symmetric.
%%%
%%% Discovery is delegated to `quic_discovery', which itself reads
%%% the `discovery_module' wired by `barrel_p2p_dist' (defaults to
%%% `barrel_p2p_discovery').

-module(barrel_p2p_epmd).

%% erl_epmd behaviour callbacks
-export([
    start_link/0,
    register_node/2,
    register_node/3,
    port_please/2,
    port_please/3,
    names/1,
    address_please/3
]).

start_link() ->
    quic_epmd:start_link().

register_node(Name, Port) ->
    quic_epmd:register_node(Name, Port).

register_node(Name, Port, Family) ->
    quic_epmd:register_node(Name, Port, Family).

port_please(Name, Host) ->
    quic_epmd:port_please(Name, Host).

port_please(Name, Host, Timeout) ->
    quic_epmd:port_please(Name, Host, Timeout).

names(Host) ->
    quic_epmd:names(Host).

address_please(Name, Host, AddressFamily) ->
    quic_epmd:address_please(Name, Host, AddressFamily).
