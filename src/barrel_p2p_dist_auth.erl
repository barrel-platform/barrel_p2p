%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Pure helpers for the Ed25519 dist auth handshake. The live
%%% handshake itself runs in `barrel_p2p_dist_auth_stream' over a pair
%%% of QUIC unidirectional streams; this module owns key I/O, the
%%% challenge build/verify primitives, and the cookie_only_nodes
%%% policy.
%%%
-module(barrel_p2p_dist_auth).

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
    sign_transcript/2,
    verify_transcript/4,
    transcript_message/8,
    validate_peer_ts/1
]).

-export_type([role/0, peer_view/0]).

%% Which side of the handshake produced a signature.
-type role() :: client | server.

%% What one side knows about the handshake when it signs or verifies: the
%% peer's HELLO name and key, both nonces, and the TLS channel binding. The
%% local name and key complete the transcript.
-type peer_view() :: #{
    peer_name := binary(),
    peer_pk := binary(),
    client_nonce := binary(),
    server_nonce := binary(),
    binding := binary()
}.

%% TLS channel binding (H1): SHA-256 of the listener's TLS cert.
-export([
    cache_server_cert_binding/0,
    server_cert_binding/0
]).

%% Internal exports for testing.
-export([
    generate_keypair/0,
    load_keypair/1,
    save_keypair/3
]).

-include("barrel_p2p.hrl").

-define(NONCE_SIZE, 32).
-define(SIGNATURE_SIZE, 64).
-define(PUBLIC_KEY_SIZE, 32).
-define(PRIVATE_KEY_SIZE, 32).
-define(TIMESTAMP_WINDOW_MS, 30000).
%% SHA-256 of the listener TLS cert, mixed into every signed handshake
%% message as the channel binding.
-define(BINDING_SIZE, 32).
-define(SERVER_CERT_BINDING_KEY, {?MODULE, server_cert_binding}).

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
            PubKeyFile = filename:join(KeyDir, "node.pub"),
            case
                filelib:is_file(PrivKeyFile) andalso
                    filelib:is_file(PubKeyFile)
            of
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

%% @doc Build a fresh challenge. The wall-clock timestamp is what
%% the peer signs and what is compared cross-host. The monotonic
%% start lets the responder measure the handshake duration without
%% an NTP-induced spurious failure.
-spec create_challenge() ->
    {Nonce :: binary(), WallTs :: integer(), MonoStart :: integer()}.
create_challenge() ->
    Nonce = crypto:strong_rand_bytes(?NONCE_SIZE),
    WallTs = erlang:system_time(millisecond),
    MonoStart = erlang:monotonic_time(millisecond),
    {Nonce, WallTs, MonoStart}.

%% Domain-separation label of protocol v3 signatures.
-define(TRANSCRIPT_LABEL, <<"barrel_p2p-dist-auth-v3">>).

%% @doc The bytes a v3 signature covers:
%% `Label | Role | ClientName | ServerName | ClientPk | ServerPk |
%% ClientNonce | ServerNonce | Binding', names length-prefixed.
%%
%% `Role' is the signer's side. It stops a server's signature from being
%% replayed as a client's (reflection). Both names bind the signature to
%% who is talking to whom, both keys and nonces to this handshake, and
%% `Binding' (SHA-256 of the server's TLS certificate) to the TLS channel.
-spec transcript_message(
    role(), binary(), binary(), binary(), binary(), binary(), binary(), binary()
) -> binary().
transcript_message(
    Role, ClientName, ServerName, ClientPk, ServerPk, ClientNonce, ServerNonce, Binding
) when
    is_binary(ClientName),
    is_binary(ServerName),
    byte_size(ClientPk) =:= ?PUBLIC_KEY_SIZE,
    byte_size(ServerPk) =:= ?PUBLIC_KEY_SIZE,
    byte_size(ClientNonce) =:= ?NONCE_SIZE,
    byte_size(ServerNonce) =:= ?NONCE_SIZE,
    byte_size(Binding) =:= ?BINDING_SIZE
->
    RoleByte = role_byte(Role),
    <<(?TRANSCRIPT_LABEL)/binary, RoleByte:8, (byte_size(ClientName)):16/big, ClientName/binary,
        (byte_size(ServerName)):16/big, ServerName/binary, ClientPk/binary, ServerPk/binary,
        ClientNonce/binary, ServerNonce/binary, Binding/binary>>.

role_byte(client) -> 1;
role_byte(server) -> 2.

%% @doc Sign the handshake transcript as `Role'. The local name and public
%% key come from `node()' and the same on-disk key pair the signature is made
%% with, so a key rotation mid-handshake cannot pair one key's signature with
%% the other key's identity.
-spec sign_transcript(role(), peer_view()) -> {ok, binary()} | {error, term()}.
sign_transcript(Role, #{binding := Binding} = View) when byte_size(Binding) =:= ?BINDING_SIZE ->
    case load_keypair(get_key_dir()) of
        {ok, PubKey, PrivKey} ->
            Message = transcript(Role, Role, PubKey, View),
            {ok, crypto:sign(eddsa, none, Message, [PrivKey, ed25519])};
        Error ->
            Error
    end;
sign_transcript(_Role, _View) ->
    {error, invalid_binding}.

%% @doc Verify the peer's signature over the transcript. `SignerRole' is
%% the peer's side; the local side is the other one. The handshake-elapsed
%% window is measured against the monotonic clock captured by
%% `create_challenge/0', so an NTP step during the handshake cannot
%% spuriously fail (or pass) the duration check.
-spec verify_transcript(binary(), role(), peer_view(), integer()) -> boolean().
verify_transcript(
    Signature, SignerRole, #{peer_pk := PeerPk, binding := Binding} = View, MonoStart
) when
    byte_size(Signature) =:= ?SIGNATURE_SIZE,
    byte_size(PeerPk) =:= ?PUBLIC_KEY_SIZE,
    byte_size(Binding) =:= ?BINDING_SIZE,
    is_integer(MonoStart)
->
    Elapsed = erlang:monotonic_time(millisecond) - MonoStart,
    case Elapsed =< get_timestamp_window() andalso get_public_key() of
        {ok, MyPubKey} ->
            Message = transcript(SignerRole, other(SignerRole), MyPubKey, View),
            crypto:verify(eddsa, none, Message, Signature, [PeerPk, ed25519]);
        _ ->
            false
    end;
verify_transcript(_, _, _, _) ->
    false.

other(client) -> server;
other(server) -> client.

%% Fill the transcript from the local side's point of view: `LocalRole' is
%% the side this node plays, `MyPubKey' its public key.
transcript(SignerRole, LocalRole, MyPubKey, View) ->
    #{
        peer_name := PeerName,
        peer_pk := PeerPk,
        client_nonce := ClientNonce,
        server_nonce := ServerNonce,
        binding := Binding
    } = View,
    MyName = atom_to_binary(node(), utf8),
    {ClientName, ServerName, ClientPk, ServerPk} =
        case LocalRole of
            client -> {MyName, PeerName, MyPubKey, PeerPk};
            server -> {PeerName, MyName, PeerPk, MyPubKey}
        end,
    transcript_message(
        SignerRole, ClientName, ServerName, ClientPk, ServerPk, ClientNonce, ServerNonce, Binding
    ).

%% @doc Reject a peer-supplied wall timestamp that is too far from
%% local wall time. Defense-in-depth against an attacker replaying
%% an old peer CHALLENGE: the nonce alone protects against replay
%% within a single signing session, this widens that to gross
%% clock skew.
-spec validate_peer_ts(integer()) -> ok | {error, peer_ts_skew}.
validate_peer_ts(PeerTs) when is_integer(PeerTs) ->
    Now = erlang:system_time(millisecond),
    case abs(Now - PeerTs) =< 2 * get_timestamp_window() of
        true -> ok;
        false -> {error, peer_ts_skew}
    end;
validate_peer_ts(_) ->
    {error, peer_ts_skew}.

%%====================================================================
%% Key Generation
%%====================================================================

%% @doc Generate a fresh Ed25519 keypair.
-spec generate_keypair() -> {PublicKey :: binary(), PrivateKey :: binary()}.
generate_keypair() ->
    {PubKey, PrivKey} = crypto:generate_key(eddsa, ed25519),
    {PubKey, PrivKey}.

%% @doc Load a keypair from disk. Verifies that the public key on
%% disk is the one derived from the private key: a crash between the
%% two file renames in save_keypair/3 could otherwise leave a
%% mismatched pair, and load would silently return inconsistent
%% material.
-spec load_keypair(string()) ->
    {ok, binary(), binary()} | {error, term()}.
load_keypair(KeyDir) ->
    PrivKeyFile = filename:join(KeyDir, "node.key"),
    PubKeyFile = filename:join(KeyDir, "node.pub"),
    case {file:read_file(PrivKeyFile), file:read_file(PubKeyFile)} of
        {{ok, PrivKey}, {ok, PubKey}} when
            byte_size(PrivKey) =:= ?PRIVATE_KEY_SIZE,
            byte_size(PubKey) =:= ?PUBLIC_KEY_SIZE
        ->
            case derived_pubkey(PrivKey) of
                PubKey ->
                    {ok, PubKey, PrivKey};
                _Other ->
                    {error, keypair_mismatch}
            end;
        {{ok, _}, {ok, _}} ->
            {error, invalid_key_size};
        {{error, Reason}, _} ->
            {error, {read_privkey_failed, Reason}};
        {_, {error, Reason}} ->
            {error, {read_pubkey_failed, Reason}}
    end.

%% @doc Save a keypair to disk atomically. Each file goes through the
%% barrel_p2p_file:write_secure/2 chmod-before-write+rename helper, so
%% neither key is ever world-readable mid-write. Two separate renames
%% are not collectively atomic, but load_keypair/1 detects the
%% mismatched-pair window and refuses to load.
-spec save_keypair(string(), binary(), binary()) -> ok | {error, term()}.
save_keypair(KeyDir, PubKey, PrivKey) ->
    PrivKeyFile = filename:join(KeyDir, "node.key"),
    PubKeyFile = filename:join(KeyDir, "node.pub"),
    case barrel_p2p_file:write_secure(PrivKeyFile, PrivKey) of
        ok ->
            case barrel_p2p_file:write_secure(PubKeyFile, PubKey) of
                ok -> ok;
                {error, Reason} -> {error, {write_pubkey_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {write_privkey_failed, Reason}}
    end.

%% Derive the Ed25519 public key from a private key. Used by
%% load_keypair/1 to detect a torn rotation.
derived_pubkey(PrivKey) ->
    try
        case crypto:generate_key(eddsa, ed25519, PrivKey) of
            {Pub, _Priv} when byte_size(Pub) =:= ?PUBLIC_KEY_SIZE ->
                Pub;
            _ ->
                undefined
        end
    catch
        _:_ ->
            undefined
    end.

%%====================================================================
%% C-Node Whitelist
%%====================================================================

%% @doc Check if a node may bypass the Ed25519 handshake on the
%% strength of the Erlang dist cookie alone (c-nodes, legacy tools).
%% Accepts a node atom or a (peer-supplied) name binary. The binary
%% form is matched without atomising, so the cookie-only check that
%% runs before Ed25519 verification cannot mint atoms.
-spec is_cookie_only_allowed(node() | binary()) -> boolean().
is_cookie_only_allowed(Node) ->
    case node_to_list(Node) of
        undefined ->
            false;
        NodeStr ->
            Whitelist = application:get_env(barrel_p2p, cookie_only_nodes, []),
            lists:any(fun(P) -> match_node_pattern(P, NodeStr) end, Whitelist)
    end.

node_to_list(Node) when is_atom(Node) -> atom_to_list(Node);
node_to_list(Node) when is_binary(Node) -> binary_to_list(Node);
node_to_list(_) -> undefined.

%% @doc Match a node name string against a pattern that may contain
%% wildcards. Patterns support `*' for any name or any host:
%%   'cnode@localhost'  - exact match
%%   'monitor@*'        - any host
%%   '*@trusted.local'  - any name on specific host
-spec match_node_pattern(atom(), string()) -> boolean().
match_node_pattern(Pattern, NodeStr) when is_atom(Pattern), is_list(NodeStr) ->
    PatternStr = atom_to_list(Pattern),
    case {string:split(PatternStr, "@"), string:split(NodeStr, "@")} of
        {[PName, PHost], [NName, NHost]} ->
            match_part(PName, NName) andalso match_part(PHost, NHost);
        _ ->
            false
    end;
match_node_pattern(_, _) ->
    false.

-spec match_part(string(), string()) -> boolean().
match_part("*", _) -> true;
match_part(P, N) -> P =:= N.

%%====================================================================
%% TLS channel binding (H1)
%%====================================================================

%% @doc Cache the SHA-256 of the effective listener TLS certificate, for
%% use as the handshake channel binding. Called once at listen time,
%% after the `quic.dist' config is projected, so the hash matches exactly
%% the cert `quic_dist' serves. Reads `cert_file' from the merged config
%% (honours `-barrel_p2p_dist_cert_dir' and a user-supplied cert), not the
%% default path. Best-effort: logs and continues on failure (the auth
%% path then fails closed when it cannot resolve the binding).
-spec cache_server_cert_binding() -> ok.
cache_server_cert_binding() ->
    case compute_server_cert_binding() of
        {ok, Hash} ->
            persistent_term:put(?SERVER_CERT_BINDING_KEY, Hash);
        {error, Reason} ->
            logger:error(
                "barrel_p2p_dist_auth: cannot hash listener cert for "
                "channel binding: ~p",
                [Reason]
            )
    end,
    ok.

%% @doc The server-side channel binding: SHA-256 of the listener cert.
%% Returns the cached value, recomputing from the effective config if the
%% cache is cold (e.g. the auth path runs before listen cached it).
-spec server_cert_binding() -> {ok, binary()} | {error, term()}.
server_cert_binding() ->
    case persistent_term:get(?SERVER_CERT_BINDING_KEY, undefined) of
        undefined -> compute_server_cert_binding();
        Hash -> {ok, Hash}
    end.

compute_server_cert_binding() ->
    DistOpts = application:get_env(quic, dist, []),
    case proplists:get_value(cert_file, DistOpts) of
        undefined -> {error, no_cert_file};
        CertFile -> cert_file_hash(CertFile)
    end.

cert_file_hash(CertFile) ->
    case file:read_file(CertFile) of
        {ok, Pem} ->
            case first_cert_der(Pem) of
                {ok, Der} -> {ok, crypto:hash(sha256, Der)};
                {error, _} = E -> E
            end;
        {error, Reason} ->
            {error, {read_cert_failed, Reason}}
    end.

first_cert_der(Pem) ->
    try [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)] of
        [Der | _] -> {ok, Der};
        [] -> {error, no_certificate_in_pem}
    catch
        _:Reason ->
            {error, {pem_decode_failed, Reason}}
    end.

%%====================================================================
%% Configuration Helpers
%%====================================================================

get_key_dir() ->
    application:get_env(barrel_p2p, auth_key_dir, "data/keys").

get_timestamp_window() ->
    application:get_env(
        barrel_p2p, auth_timestamp_window, ?TIMESTAMP_WINDOW_MS
    ).
