%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Pure helpers for the Ed25519 dist auth handshake. The live
%%% handshake itself runs in `mycelium_dist_auth_stream' over a pair
%%% of QUIC unidirectional streams; this module owns key I/O, the
%%% challenge build/verify primitives, and the cookie_only_nodes
%%% policy.
%%%
-module(mycelium_dist_auth).

%% Public API
-export([
    init/0,
    ensure_keypair/0,
    get_public_key/0,
    get_private_key/0,
    is_cookie_only_allowed/1
]).

%% Challenge-response primitives used by the auth stream module.
-export([
    create_challenge/0,
    sign_challenge/2,
    verify_response/3
]).

%% Internal exports for testing.
-export([
    generate_keypair/0,
    load_keypair/1,
    save_keypair/3
]).

-include("mycelium.hrl").

-define(NONCE_SIZE, 32).
-define(SIGNATURE_SIZE, 64).
-define(PUBLIC_KEY_SIZE, 32).
-define(PRIVATE_KEY_SIZE, 32).
-define(TIMESTAMP_WINDOW_MS, 30000).

%%====================================================================
%% Public API
%%====================================================================

%% @doc Initialize the authentication subsystem.
-spec init() -> ok | {error, term()}.
init() ->
    case ensure_keypair() of
        ok -> ok;
        Error -> Error
    end.

%% @doc Ensure a node keypair exists, generating one if needed.
-spec ensure_keypair() -> ok | {error, term()}.
ensure_keypair() ->
    KeyDir = get_key_dir(),
    case filelib:ensure_dir(filename:join(KeyDir, "dummy")) of
        ok ->
            PrivKeyFile = filename:join(KeyDir, "node.key"),
            PubKeyFile  = filename:join(KeyDir, "node.pub"),
            case filelib:is_file(PrivKeyFile)
                 andalso filelib:is_file(PubKeyFile) of
                true ->
                    case load_keypair(KeyDir) of
                        {ok, _PubKey, _PrivKey} -> ok;
                        Error -> Error
                    end;
                false ->
                    {PubKey, PrivKey} = generate_keypair(),
                    save_keypair(KeyDir, PubKey, PrivKey)
            end;
        {error, Reason} ->
            {error, {mkdir_failed, Reason}}
    end.

%% @doc Read the node's Ed25519 public key from disk.
-spec get_public_key() -> {ok, binary()} | {error, term()}.
get_public_key() ->
    KeyDir = get_key_dir(),
    PubKeyFile = filename:join(KeyDir, "node.pub"),
    file:read_file(PubKeyFile).

%% @doc Read the node's Ed25519 private key from disk.
-spec get_private_key() -> {ok, binary()} | {error, term()}.
get_private_key() ->
    KeyDir = get_key_dir(),
    PrivKeyFile = filename:join(KeyDir, "node.key"),
    file:read_file(PrivKeyFile).

%%====================================================================
%% Challenge-Response Protocol
%%====================================================================

%% @doc Build a fresh (nonce, timestamp) challenge.
-spec create_challenge() -> {binary(), integer()}.
create_challenge() ->
    Nonce = crypto:strong_rand_bytes(?NONCE_SIZE),
    Timestamp = erlang:system_time(millisecond),
    {Nonce, Timestamp}.

%% @doc Sign a challenge built locally. The message format
%% `Nonce | Timestamp | OwnPubKey' binds the signature to the
%% signer's own identity.
-spec sign_challenge(binary(), integer()) -> {ok, binary()} | {error, term()}.
sign_challenge(Nonce, Timestamp) when byte_size(Nonce) =:= ?NONCE_SIZE ->
    case get_private_key() of
        {ok, PrivKey} ->
            case get_public_key() of
                {ok, PubKey} ->
                    Message =
                        <<Nonce/binary, Timestamp:64/big, PubKey/binary>>,
                    Sig = crypto:sign(eddsa, none, Message, [PrivKey, ed25519]),
                    {ok, Sig};
                Error -> Error
            end;
        Error -> Error
    end.

%% @doc Verify a peer's response. Rebuilds the signed message as
%% `Nonce | Timestamp | ResponderPubKey' and checks the signature.
-spec verify_response(binary(), binary(), {binary(), integer()}) ->
    boolean().
verify_response(Signature, ResponderPubKey, {Nonce, Timestamp})
  when byte_size(Signature)       =:= ?SIGNATURE_SIZE,
       byte_size(ResponderPubKey) =:= ?PUBLIC_KEY_SIZE,
       byte_size(Nonce)           =:= ?NONCE_SIZE ->
    Now = erlang:system_time(millisecond),
    case abs(Now - Timestamp) =< get_timestamp_window() of
        true ->
            Message =
                <<Nonce/binary, Timestamp:64/big, ResponderPubKey/binary>>,
            crypto:verify(
                eddsa, none, Message, Signature, [ResponderPubKey, ed25519]
            );
        false ->
            false
    end;
verify_response(_, _, _) ->
    false.

%%====================================================================
%% Key Generation
%%====================================================================

%% @doc Generate a fresh Ed25519 keypair.
-spec generate_keypair() -> {PublicKey :: binary(), PrivateKey :: binary()}.
generate_keypair() ->
    {PubKey, PrivKey} = crypto:generate_key(eddsa, ed25519),
    {PubKey, PrivKey}.

%% @doc Load a keypair from disk.
-spec load_keypair(string()) ->
    {ok, binary(), binary()} | {error, term()}.
load_keypair(KeyDir) ->
    PrivKeyFile = filename:join(KeyDir, "node.key"),
    PubKeyFile  = filename:join(KeyDir, "node.pub"),
    case {file:read_file(PrivKeyFile), file:read_file(PubKeyFile)} of
        {{ok, PrivKey}, {ok, PubKey}}
          when byte_size(PrivKey) =:= ?PRIVATE_KEY_SIZE,
               byte_size(PubKey)  =:= ?PUBLIC_KEY_SIZE ->
            {ok, PubKey, PrivKey};
        {{ok, _}, {ok, _}} ->
            {error, invalid_key_size};
        {{error, Reason}, _} ->
            {error, {read_privkey_failed, Reason}};
        {_, {error, Reason}} ->
            {error, {read_pubkey_failed, Reason}}
    end.

%% @doc Save a keypair to disk. Private key written with 0600 perms.
-spec save_keypair(string(), binary(), binary()) -> ok | {error, term()}.
save_keypair(KeyDir, PubKey, PrivKey) ->
    PrivKeyFile = filename:join(KeyDir, "node.key"),
    PubKeyFile  = filename:join(KeyDir, "node.pub"),
    case file:write_file(PrivKeyFile, PrivKey) of
        ok ->
            file:change_mode(PrivKeyFile, 8#600),
            case file:write_file(PubKeyFile, PubKey) of
                ok -> ok;
                {error, Reason} -> {error, {write_pubkey_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {write_privkey_failed, Reason}}
    end.

%%====================================================================
%% C-Node Whitelist
%%====================================================================

%% @doc Check if a node may bypass the Ed25519 handshake on the
%% strength of the Erlang dist cookie alone (c-nodes, legacy tools).
-spec is_cookie_only_allowed(node()) -> boolean().
is_cookie_only_allowed(Node) ->
    Whitelist = application:get_env(mycelium, cookie_only_nodes, []),
    lists:any(fun(P) -> match_node_pattern(P, Node) end, Whitelist).

%% @doc Match a node against a pattern that may contain wildcards.
%% Patterns support `*' for any name or any host:
%%   'cnode@localhost'  - exact match
%%   'monitor@*'        - any host
%%   '*@trusted.local'  - any name on specific host
-spec match_node_pattern(atom(), node()) -> boolean().
match_node_pattern(Pattern, Node) when is_atom(Pattern), is_atom(Node) ->
    PatternStr = atom_to_list(Pattern),
    NodeStr    = atom_to_list(Node),
    case {string:split(PatternStr, "@"), string:split(NodeStr, "@")} of
        {[PName, PHost], [NName, NHost]} ->
            match_part(PName, NName) andalso match_part(PHost, NHost);
        _ -> false
    end;
match_node_pattern(_, _) -> false.

-spec match_part(string(), string()) -> boolean().
match_part("*", _) -> true;
match_part(P,   N) -> P =:= N.

%%====================================================================
%% Configuration Helpers
%%====================================================================

get_key_dir() ->
    application:get_env(mycelium, auth_key_dir, "data/keys").

get_timestamp_window() ->
    application:get_env(
        mycelium, auth_timestamp_window, ?TIMESTAMP_WINDOW_MS
    ).
