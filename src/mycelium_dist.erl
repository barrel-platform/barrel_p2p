%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Mycelium proto_dist alt-dist module.
%%%
%%% Boot a mycelium node with just:
%%%
%%%   -proto_dist mycelium
%%%   -epmd_module mycelium_epmd
%%%   -start_epmd false
%%%
%%% Everything else (TLS cert generation, auth callback wiring,
%%% discovery module, on-disk cert/key paths) is filled in here
%%% before delegating to upstream `quic_dist'. Values the user sets
%%% explicitly under `{quic, [{dist, [...]}]}' or via `-quic_dist_*'
%%% init args are preserved.
%%%
%%% The shim is intentionally tiny: it owns the listen-time defaults
%%% and forwards the other alt-dist callbacks straight through. That
%%% keeps upstream `?MODULE'-relative spawns (do_setup, acceptor_loop,
%%% accept_connection inline fun) resolving to the right module.

-module(mycelium_dist).

%% Distribution module callbacks (the alt-dist contract).
-export([
    listen/1,
    listen/2,
    accept/1,
    accept_connection/5,
    setup/5,
    close/1,
    select/1,
    address/0,
    is_node_name/1
]).

%%====================================================================
%% Distribution Module Callbacks
%%====================================================================

listen(Name) ->
    listen(Name, #{}).

listen(Name, ExtraOpts) ->
    ok = ensure_modules_loaded(),
    ok = project_init_args(),
    ok = ensure_cert(),
    ok = project_defaults(),
    ok = project_listen_port(),
    quic_dist:listen(Name, ExtraOpts).

accept(Listener) ->
    quic_dist:accept(Listener).

accept_connection(AcceptPid, DistCtrl, MyNode, Allowed, SetupTime) ->
    quic_dist:accept_connection(AcceptPid, DistCtrl, MyNode, Allowed, SetupTime).

setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    quic_dist:setup(Node, Type, MyNode, LongOrShortNames, SetupTime).

close(Listener) ->
    quic_dist:close(Listener).

select(Node) ->
    quic_dist:select(Node).

address() ->
    quic_dist:address().

is_node_name(Node) ->
    quic_dist:is_node_name(Node).

%%====================================================================
%% Internal: early-boot wiring
%%====================================================================

%% Modules referenced by quic_dist at runtime that may not be auto-
%% loaded yet during early boot (proto_dist listen/1 runs before the
%% application controller starts mycelium).
ensure_modules_loaded() ->
    lists:foreach(
        fun(M) -> _ = code:ensure_loaded(M) end,
        [public_key,
         mycelium_quic_cert,
         mycelium_discovery,
         mycelium_discovery_static,
         mycelium_discovery_file,
         mycelium_discovery_dns,
         mycelium_dist_auth_callback,
         mycelium_dist_auth_stream]),
    ok.

%% Lazily materialise the QUIC TLS cert/key if they aren't on disk
%% yet. quic_dist:load_credentials runs straight after this and will
%% fail with {credentials, no_credentials} if the files are missing.
ensure_cert() ->
    case mycelium_quic_cert:ensure_cert() of
        ok ->
            ok;
        {error, Reason} ->
            logger:error("mycelium_dist: cert ensure failed: ~p", [Reason]),
            ok
    end.

%% Project mycelium defaults into the {quic, dist, ...} app env that
%% upstream quic_dist:load_config/0 reads. User-supplied values win:
%% we only fill keys that are absent.
project_defaults() ->
    User = application:get_env(quic, dist, []),
    Defaults = build_defaults(),
    Merged = merge_defaults(User, Defaults),
    application:set_env(quic, dist, Merged),
    ok.

build_defaults() ->
    CertDir = application:get_env(mycelium, quic_cert_dir, "data/quic"),
    CertFile = filename:join(CertDir, "node.crt"),
    KeyFile = filename:join(CertDir, "node.key"),
    AuthTimeout = application:get_env(mycelium, auth_handshake_timeout, 10000),
    %% register_with_epmd intentionally left at upstream default
    %% (false). mycelium_app:start/2 publishes the node into the
    %% discovery chain itself once sys.config envs are live, using
    %% the full atom node name; the listen-time path passes a bare
    %% name string which the file backend doesn't accept.
    [
        {auth_callback, {mycelium_dist_auth_callback, authenticate}},
        {auth_handshake_timeout, AuthTimeout},
        {discovery_module, mycelium_discovery},
        {cert_file, list_to_binary(CertFile)},
        {key_file, list_to_binary(KeyFile)}
    ].

%% Translate `-mycelium_dist_*' init args to their `quic.dist'
%% equivalents so users never have to type the upstream knob names.
%% Recognised today: -mycelium_dist_port N.
project_init_args() ->
    case init:get_argument(mycelium_dist_port) of
        {ok, [[PortStr] | _]} ->
            case catch list_to_integer(PortStr) of
                P when is_integer(P), P >= 0 ->
                    application:set_env(quic, dist_port, P);
                _ ->
                    ok
            end;
        _ ->
            ok
    end,
    ok.

%% Project mycelium.listen_port -> quic.dist_port so users keep a
%% single {mycelium, [{listen_port, ...}]} knob. Upstream's
%% -quic_dist_port init arg still wins over this (it's read straight
%% from init args, not the app env).
project_listen_port() ->
    case application:get_env(quic, dist_port) of
        {ok, _} ->
            ok;
        undefined ->
            case application:get_env(mycelium, listen_port) of
                {ok, Port} when is_integer(Port) ->
                    application:set_env(quic, dist_port, Port);
                _ ->
                    ok
            end
    end,
    ok.

merge_defaults(User, Defaults) ->
    lists:foldl(
        fun({K, V}, Acc) ->
            case proplists:is_defined(K, Acc) of
                true  -> Acc;
                false -> [{K, V} | Acc]
            end
        end,
        User,
        Defaults).
