%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(mycelium_dist_auth).

%% Public API
-export([
    init/0,
    ensure_keypair/0,
    get_public_key/0,
    get_private_key/0,
    authenticate_outgoing/2,
    authenticate_incoming/1,
    is_cookie_only_allowed/1
]).

%% Challenge-response protocol
-export([
    create_challenge/0,
    sign_challenge/2,
    verify_response/3
]).

%% Internal exports for testing
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
-define(TIMESTAMP_WINDOW_MS, 30000).  %% Max clock drift allowed

%%====================================================================
%% Public API
%%====================================================================

%% @doc Initialize the authentication subsystem
-spec init() -> ok | {error, term()}.
init() ->
    case ensure_keypair() of
        ok -> ok;
        Error -> Error
    end.

%% @doc Ensure a keypair exists, generating one if needed
-spec ensure_keypair() -> ok | {error, term()}.
ensure_keypair() ->
    KeyDir = get_key_dir(),
    case filelib:ensure_dir(filename:join(KeyDir, "dummy")) of
        ok ->
            PrivKeyFile = filename:join(KeyDir, "node.key"),
            PubKeyFile = filename:join(KeyDir, "node.pub"),
            case filelib:is_file(PrivKeyFile) andalso filelib:is_file(PubKeyFile) of
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

%% @doc Get the node's public key
-spec get_public_key() -> {ok, binary()} | {error, term()}.
get_public_key() ->
    KeyDir = get_key_dir(),
    PubKeyFile = filename:join(KeyDir, "node.pub"),
    file:read_file(PubKeyFile).

%% @doc Get the node's private key
-spec get_private_key() -> {ok, binary()} | {error, term()}.
get_private_key() ->
    KeyDir = get_key_dir(),
    PrivKeyFile = filename:join(KeyDir, "node.key"),
    file:read_file(PrivKeyFile).

%% @doc Authenticate as connection initiator (outgoing)
%% Returns {ok, CryptoSession} if encryption is enabled, ok otherwise.
-spec authenticate_outgoing(gen_tcp:socket() | ssl:sslsocket(), node()) ->
    ok | {ok, #crypto_session{}} | {error, term()}.
authenticate_outgoing(Socket, TargetNode) ->
    case is_auth_enabled() of
        false -> ok;
        true -> do_authenticate_outgoing(Socket, TargetNode)
    end.

%% @doc Authenticate as connection acceptor (incoming)
%% Returns {ok, CryptoSession} if encryption is enabled, ok otherwise.
%% Returns {error, auth_not_attempted} if peer doesn't support Ed25519 (c-node).
-spec authenticate_incoming(gen_tcp:socket() | ssl:sslsocket()) ->
    ok | {ok, #crypto_session{}} | {error, term()}.
authenticate_incoming(Socket) ->
    case is_auth_enabled() of
        false -> ok;
        true -> do_authenticate_incoming(Socket)
    end.

%%====================================================================
%% Challenge-Response Protocol
%%====================================================================

%% @doc Create a new challenge (nonce + timestamp)
-spec create_challenge() -> {binary(), integer()}.
create_challenge() ->
    Nonce = crypto:strong_rand_bytes(?NONCE_SIZE),
    Timestamp = erlang:system_time(millisecond),
    {Nonce, Timestamp}.

%% @doc Sign a challenge
%% Message format: `<<Nonce:32/binary, Timestamp:64/big, ResponderPubKey:32/binary>>'
-spec sign_challenge(binary(), integer()) -> {ok, binary()} | {error, term()}.
sign_challenge(Nonce, Timestamp) when byte_size(Nonce) =:= ?NONCE_SIZE ->
    case get_private_key() of
        {ok, PrivKey} ->
            case get_public_key() of
                {ok, PubKey} ->
                    Message = <<Nonce/binary, Timestamp:64/big, PubKey/binary>>,
                    Signature = crypto:sign(eddsa, none, Message, [PrivKey, ed25519]),
                    {ok, Signature};
                Error -> Error
            end;
        Error -> Error
    end.

%% @doc Verify a challenge response
-spec verify_response(binary(), binary(), {binary(), integer()}) ->
    boolean().
verify_response(Signature, ResponderPubKey, {Nonce, Timestamp})
  when byte_size(Signature) =:= ?SIGNATURE_SIZE,
       byte_size(ResponderPubKey) =:= ?PUBLIC_KEY_SIZE,
       byte_size(Nonce) =:= ?NONCE_SIZE ->
    %% Check timestamp is within acceptable window
    Now = erlang:system_time(millisecond),
    TimestampWindow = get_timestamp_window(),
    case abs(Now - Timestamp) =< TimestampWindow of
        true ->
            Message = <<Nonce/binary, Timestamp:64/big, ResponderPubKey/binary>>,
            crypto:verify(eddsa, none, Message, Signature, [ResponderPubKey, ed25519]);
        false ->
            false
    end;
verify_response(_, _, _) ->
    false.

%%====================================================================
%% Key Generation
%%====================================================================

%% @doc Generate a new Ed25519 keypair
-spec generate_keypair() -> {PublicKey :: binary(), PrivateKey :: binary()}.
generate_keypair() ->
    {PubKey, PrivKey} = crypto:generate_key(eddsa, ed25519),
    {PubKey, PrivKey}.

%% @doc Load keypair from disk
-spec load_keypair(string()) -> {ok, binary(), binary()} | {error, term()}.
load_keypair(KeyDir) ->
    PrivKeyFile = filename:join(KeyDir, "node.key"),
    PubKeyFile = filename:join(KeyDir, "node.pub"),
    case {file:read_file(PrivKeyFile), file:read_file(PubKeyFile)} of
        {{ok, PrivKey}, {ok, PubKey}} when byte_size(PrivKey) =:= ?PRIVATE_KEY_SIZE,
                                          byte_size(PubKey) =:= ?PUBLIC_KEY_SIZE ->
            {ok, PubKey, PrivKey};
        {{ok, _}, {ok, _}} ->
            {error, invalid_key_size};
        {{error, Reason}, _} ->
            {error, {read_privkey_failed, Reason}};
        {_, {error, Reason}} ->
            {error, {read_pubkey_failed, Reason}}
    end.

%% @doc Save keypair to disk
-spec save_keypair(string(), binary(), binary()) -> ok | {error, term()}.
save_keypair(KeyDir, PubKey, PrivKey) ->
    PrivKeyFile = filename:join(KeyDir, "node.key"),
    PubKeyFile = filename:join(KeyDir, "node.pub"),
    case file:write_file(PrivKeyFile, PrivKey) of
        ok ->
            %% Set restrictive permissions on private key
            file:change_mode(PrivKeyFile, 8#600),
            case file:write_file(PubKeyFile, PubKey) of
                ok -> ok;
                {error, Reason} -> {error, {write_pubkey_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {write_privkey_failed, Reason}}
    end.

%%====================================================================
%% Internal Functions - Protocol Implementation
%%====================================================================

do_authenticate_outgoing(Socket, TargetNode) ->
    Timeout = get_handshake_timeout(),
    case get_public_key() of
        {ok, MyPubKey} ->
            MyNode = node(),
            %% Step 1: Send AUTH_HELLO
            HelloMsg = mycelium_dist_protocol:encode_hello(MyNode, MyPubKey),
            case socket_send(Socket, HelloMsg) of
                ok ->
                    %% Step 2: Receive peer's AUTH_HELLO
                    case socket_recv(Socket, Timeout) of
                        {ok, HelloData} ->
                            case mycelium_dist_protocol:decode(HelloData) of
                                {hello, PeerNode, PeerPubKey} ->
                                    handle_outgoing_after_hello(
                                        Socket, TargetNode, MyPubKey,
                                        PeerNode, PeerPubKey, Timeout);
                                {fail, Reason} ->
                                    {error, {auth_rejected, Reason}};
                                _ ->
                                    {error, unexpected_message}
                            end;
                        {error, Reason} ->
                            {error, {recv_hello_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {send_hello_failed, Reason}}
            end;
        Error ->
            Error
    end.

handle_outgoing_after_hello(Socket, TargetNode, MyPubKey, PeerNode, PeerPubKey, Timeout) ->
    %% Verify peer node matches target
    case PeerNode =:= TargetNode of
        true ->
            %% Step 3: Send our challenge
            {MyNonce, MyTimestamp} = create_challenge(),
            ChallengeMsg = mycelium_dist_protocol:encode_challenge(MyNonce, MyTimestamp),
            case socket_send(Socket, ChallengeMsg) of
                ok ->
                    %% Step 4: Receive peer's challenge
                    case socket_recv(Socket, Timeout) of
                        {ok, ChallengeData} ->
                            case mycelium_dist_protocol:decode(ChallengeData) of
                                {challenge, PeerNonce, PeerTimestamp} ->
                                    handle_outgoing_challenge_exchange(
                                        Socket, MyPubKey, TargetNode, PeerPubKey,
                                        MyNonce, MyTimestamp,
                                        PeerNonce, PeerTimestamp, Timeout);
                                _ ->
                                    {error, unexpected_message}
                            end;
                        {error, Reason} ->
                            {error, {recv_challenge_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {send_challenge_failed, Reason}}
            end;
        false ->
            {error, {node_mismatch, {expected, TargetNode}, {got, PeerNode}}}
    end.

handle_outgoing_challenge_exchange(Socket, _MyPubKey, PeerNode, PeerPubKey,
                                   MyNonce, MyTimestamp,
                                   PeerNonce, PeerTimestamp, Timeout) ->
    %% Step 5: Sign peer's challenge and send response
    case sign_challenge_for_peer(PeerNonce, PeerTimestamp, PeerPubKey) of
        {ok, MySignature} ->
            ResponseMsg = mycelium_dist_protocol:encode_response(MySignature),
            case socket_send(Socket, ResponseMsg) of
                ok ->
                    %% Step 6: Receive peer's response
                    case socket_recv(Socket, Timeout) of
                        {ok, ResponseData} ->
                            case mycelium_dist_protocol:decode(ResponseData) of
                                {response, PeerSignature} ->
                                    %% Verify peer's signature
                                    case verify_response(PeerSignature, PeerPubKey,
                                                        {MyNonce, MyTimestamp}) of
                                        true ->
                                            %% Step 7: Receive final OK/FAIL
                                            finalize_auth(Socket, PeerNode, PeerPubKey, Timeout);
                                        false ->
                                            {error, signature_verification_failed}
                                    end;
                                _ ->
                                    {error, unexpected_message}
                            end;
                        {error, Reason} ->
                            {error, {recv_response_failed, Reason}}
                    end;
                {error, Reason} ->
                    {error, {send_response_failed, Reason}}
            end;
        Error ->
            Error
    end.

do_authenticate_incoming(Socket) ->
    Timeout = get_handshake_timeout(),
    %% Use a short timeout for initial detection of c-nodes
    %% C-nodes and legacy tools won't send AUTH_HELLO, they'll start OTP handshake directly
    CNodeTimeout = get_cnode_detection_timeout(),
    case get_public_key() of
        {ok, MyPubKey} ->
            MyNode = node(),
            %% Step 1: Try to receive peer's AUTH_HELLO with short timeout
            case socket_recv(Socket, CNodeTimeout) of
                {ok, HelloData} ->
                    case mycelium_dist_protocol:decode(HelloData) of
                        {hello, PeerNode, PeerPubKey} ->
                            %% Step 2: Send our AUTH_HELLO
                            HelloMsg = mycelium_dist_protocol:encode_hello(MyNode, MyPubKey),
                            case socket_send(Socket, HelloMsg) of
                                ok ->
                                    handle_incoming_after_hello(
                                        Socket, MyPubKey, PeerNode, PeerPubKey, Timeout
                                    );
                                {error, Reason} ->
                                    {error, {send_hello_failed, Reason}}
                            end;
                        _ ->
                            %% Received data but not AUTH_HELLO - likely OTP handshake
                            %% Return the raw data so it can be replayed for OTP
                            {error, {auth_not_attempted, HelloData}}
                    end;
                {error, timeout} ->
                    %% No data within short timeout - likely c-node waiting for us
                    %% Return so OTP handshake can proceed
                    {error, auth_not_attempted};
                {error, Reason} ->
                    {error, {recv_hello_failed, Reason}}
            end;
        Error ->
            Error
    end.

handle_incoming_after_hello(Socket, MyPubKey, PeerNode, PeerPubKey, Timeout) ->
    %% Check if peer's key is trusted for the claimed peer node.
    case mycelium_dist_keys:is_trusted(PeerNode, PeerPubKey) of
        true ->
            continue_incoming_auth(Socket, MyPubKey, PeerNode, PeerPubKey, Timeout);
        false ->
            %% In TOFU mode, we'll trust on first use
            case get_trust_mode() of
                tofu ->
                    continue_incoming_auth(Socket, MyPubKey, PeerNode, PeerPubKey, Timeout);
                strict ->
                    FailMsg = mycelium_dist_protocol:encode_fail(<<"untrusted_key">>),
                    socket_send(Socket, FailMsg),
                    {error, untrusted_key}
            end
    end.

continue_incoming_auth(Socket, MyPubKey, PeerNode, PeerPubKey, Timeout) ->
    %% Step 3: Receive peer's challenge
    case socket_recv(Socket, Timeout) of
        {ok, ChallengeData} ->
            case mycelium_dist_protocol:decode(ChallengeData) of
                {challenge, PeerNonce, PeerTimestamp} ->
                    %% Step 4: Send our challenge
                    {MyNonce, MyTimestamp} = create_challenge(),
                    ChallengeMsg = mycelium_dist_protocol:encode_challenge(MyNonce, MyTimestamp),
                    case socket_send(Socket, ChallengeMsg) of
                        ok ->
                            handle_incoming_challenge_exchange(
                                Socket, MyPubKey, PeerNode, PeerPubKey,
                                MyNonce, MyTimestamp,
                                PeerNonce, PeerTimestamp, Timeout);
                        {error, Reason} ->
                            {error, {send_challenge_failed, Reason}}
                    end;
                _ ->
                    {error, unexpected_message}
            end;
        {error, Reason} ->
            {error, {recv_challenge_failed, Reason}}
    end.

handle_incoming_challenge_exchange(Socket, _MyPubKey, PeerNode, PeerPubKey,
                                   MyNonce, MyTimestamp,
                                   PeerNonce, PeerTimestamp, Timeout) ->
    %% Step 5: Receive peer's response first (as acceptor)
    case socket_recv(Socket, Timeout) of
        {ok, ResponseData} ->
            case mycelium_dist_protocol:decode(ResponseData) of
                {response, PeerSignature} ->
                    %% Verify peer's signature
                    case verify_response(PeerSignature, PeerPubKey, {MyNonce, MyTimestamp}) of
                        true ->
                            %% Step 6: Sign peer's challenge and send our response
                            case sign_challenge_for_peer(PeerNonce, PeerTimestamp, PeerPubKey) of
                                {ok, MySignature} ->
                                    ResponseMsg = mycelium_dist_protocol:encode_response(MySignature),
                                    case socket_send(Socket, ResponseMsg) of
                                        ok ->
                                            %% Step 7: Send AUTH_OK and record the peer
                                            OkMsg = mycelium_dist_protocol:encode_ok(),
                                            case socket_send(Socket, OkMsg) of
                                                ok ->
                                                    %% Record trusted peer (TOFU)
                                                    mycelium_dist_keys:store_key_if_new(
                                                        PeerNode, PeerPubKey
                                                    ),
                                                    %% Step 8: Perform key exchange if encryption enabled
                                                    case mycelium_crypto:is_encryption_enabled() of
                                                        true ->
                                                            perform_key_exchange_responder(Socket, Timeout);
                                                        false ->
                                                            ok
                                                    end;
                                                {error, Reason} ->
                                                    {error, {send_ok_failed, Reason}}
                                            end;
                                        {error, Reason} ->
                                            {error, {send_response_failed, Reason}}
                                    end;
                                Error ->
                                    Error
                            end;
                        false ->
                            FailMsg = mycelium_dist_protocol:encode_fail(<<"signature_invalid">>),
                            socket_send(Socket, FailMsg),
                            {error, signature_verification_failed}
                    end;
                _ ->
                    {error, unexpected_message}
            end;
        {error, Reason} ->
            {error, {recv_response_failed, Reason}}
    end.

finalize_auth(Socket, PeerNode, PeerPubKey, Timeout) ->
    case socket_recv(Socket, Timeout) of
        {ok, FinalData} ->
            case mycelium_dist_protocol:decode(FinalData) of
                ok ->
                    %% Record trusted peer (TOFU)
                    mycelium_dist_keys:store_key_if_new(PeerNode, PeerPubKey),
                    %% Perform key exchange if encryption is enabled
                    case mycelium_crypto:is_encryption_enabled() of
                        true ->
                            perform_key_exchange_initiator(Socket, Timeout);
                        false ->
                            ok
                    end;
                {fail, Reason} ->
                    {error, {auth_rejected, Reason}};
                _ ->
                    {error, unexpected_final_message}
            end;
        {error, Reason} ->
            {error, {recv_final_failed, Reason}}
    end.

%% Sign challenge for peer - message includes peer's public key
sign_challenge_for_peer(Nonce, Timestamp, PeerPubKey) ->
    case get_private_key() of
        {ok, PrivKey} ->
            Message = <<Nonce/binary, Timestamp:64/big, PeerPubKey/binary>>,
            Signature = crypto:sign(eddsa, none, Message, [PrivKey, ed25519]),
            {ok, Signature};
        Error ->
            Error
    end.

%%====================================================================
%% Key Exchange Protocol
%%====================================================================

%% @doc Perform X25519 key exchange as the initiator (outgoing connection).
%% The initiator sends their ephemeral public key first, then receives peer's key.
-spec perform_key_exchange_initiator(gen_tcp:socket() | ssl:sslsocket(), timeout()) ->
    {ok, #crypto_session{}} | {error, term()}.
perform_key_exchange_initiator(Socket, Timeout) ->
    %% Generate our ephemeral X25519 keypair
    {MyEphPub, MyEphPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    %% Send our ephemeral public key
    KeyExMsg = mycelium_dist_protocol:encode_key_exchange(MyEphPub),
    case socket_send(Socket, KeyExMsg) of
        ok ->
            %% Receive peer's ephemeral public key
            case socket_recv(Socket, Timeout) of
                {ok, KeyExData} ->
                    case mycelium_dist_protocol:decode(KeyExData) of
                        {key_exchange, PeerEphPub} ->
                            %% Compute shared secret and derive session keys
                            SharedSecret = mycelium_crypto:compute_shared_secret(PeerEphPub, MyEphPriv),
                            {InitiatorSession, _ResponderSession} =
                                mycelium_crypto:derive_session_keys(SharedSecret, MyEphPub, PeerEphPub),
                            {ok, InitiatorSession};
                        {fail, Reason} ->
                            {error, {key_exchange_rejected, Reason}};
                        _ ->
                            {error, unexpected_key_exchange_message}
                    end;
                {error, Reason} ->
                    {error, {recv_key_exchange_failed, Reason}}
            end;
        {error, Reason} ->
            {error, {send_key_exchange_failed, Reason}}
    end.

%% @doc Perform X25519 key exchange as the responder (incoming connection).
%% The responder receives peer's ephemeral key first, then sends their key.
-spec perform_key_exchange_responder(gen_tcp:socket() | ssl:sslsocket(), timeout()) ->
    {ok, #crypto_session{}} | {error, term()}.
perform_key_exchange_responder(Socket, Timeout) ->
    %% Generate our ephemeral X25519 keypair
    {MyEphPub, MyEphPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    %% Receive peer's ephemeral public key first
    case socket_recv(Socket, Timeout) of
        {ok, KeyExData} ->
            case mycelium_dist_protocol:decode(KeyExData) of
                {key_exchange, PeerEphPub} ->
                    %% Send our ephemeral public key
                    KeyExMsg = mycelium_dist_protocol:encode_key_exchange(MyEphPub),
                    case socket_send(Socket, KeyExMsg) of
                        ok ->
                            %% Compute shared secret and derive session keys
                            %% Note: PeerEphPub is initiator's key, MyEphPub is responder's key
                            SharedSecret = mycelium_crypto:compute_shared_secret(PeerEphPub, MyEphPriv),
                            {_InitiatorSession, ResponderSession} =
                                mycelium_crypto:derive_session_keys(SharedSecret, PeerEphPub, MyEphPub),
                            {ok, ResponderSession};
                        {error, Reason} ->
                            {error, {send_key_exchange_failed, Reason}}
                    end;
                {fail, Reason} ->
                    {error, {key_exchange_rejected, Reason}};
                _ ->
                    {error, unexpected_key_exchange_message}
            end;
        {error, Reason} ->
            {error, {recv_key_exchange_failed, Reason}}
    end.

%%====================================================================
%% Socket Helpers
%%====================================================================

socket_send(Socket, Data) when is_port(Socket) ->
    gen_tcp:send(Socket, Data);
socket_send(Socket, Data) ->
    %% Assume SSL socket
    ssl:send(Socket, Data).

socket_recv(Socket, Timeout) when is_port(Socket) ->
    gen_tcp:recv(Socket, 0, Timeout);
socket_recv(Socket, Timeout) ->
    ssl:recv(Socket, 0, Timeout).

%%====================================================================
%% C-Node Whitelist
%%====================================================================

%% @doc Check if a node is allowed cookie-only connection (no Ed25519 auth).
%% Used for c-nodes and legacy tools that cannot perform Ed25519 authentication.
-spec is_cookie_only_allowed(node()) -> boolean().
is_cookie_only_allowed(Node) ->
    Whitelist = application:get_env(mycelium, cookie_only_nodes, []),
    lists:any(fun(Pattern) -> match_node_pattern(Pattern, Node) end, Whitelist).

%% @doc Match a node against a pattern that may contain wildcards.
%% Patterns support '*' for any name or any host:
%%   'cnode@localhost'  - exact match
%%   'monitor@*'        - any host
%%   '*@trusted.local'  - any name on specific host
-spec match_node_pattern(atom(), node()) -> boolean().
match_node_pattern(Pattern, Node) when is_atom(Pattern), is_atom(Node) ->
    PatternStr = atom_to_list(Pattern),
    NodeStr = atom_to_list(Node),
    case {string:split(PatternStr, "@"), string:split(NodeStr, "@")} of
        {[PName, PHost], [NName, NHost]} ->
            match_part(PName, NName) andalso match_part(PHost, NHost);
        _ -> false
    end;
match_node_pattern(_, _) -> false.

%% @doc Match a single part (name or host) with wildcard support.
-spec match_part(string(), string()) -> boolean().
match_part("*", _) -> true;
match_part(P, N) -> P =:= N.

%%====================================================================
%% Configuration Helpers
%%====================================================================

is_auth_enabled() ->
    application:get_env(mycelium, auth_enabled, true).

get_key_dir() ->
    application:get_env(mycelium, auth_key_dir, "data/keys").

get_handshake_timeout() ->
    application:get_env(mycelium, auth_handshake_timeout, 10000).

get_cnode_detection_timeout() ->
    application:get_env(mycelium, cnode_detection_timeout, 1000).

get_timestamp_window() ->
    application:get_env(mycelium, auth_timestamp_window, ?TIMESTAMP_WINDOW_MS).

get_trust_mode() ->
    application:get_env(mycelium, auth_trust_mode, tofu).
