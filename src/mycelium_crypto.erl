%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(mycelium_crypto).

%% X25519 Key Exchange and ChaCha20-Poly1305 Encryption for Distribution
%%
%% Provides end-to-end encryption for Erlang distribution traffic using:
%% - X25519 for ephemeral key exchange (ECDH)
%% - HKDF-SHA256 for key derivation
%% - ChaCha20-Poly1305 for authenticated encryption

-export([
    %% Key exchange
    generate_ephemeral_keypair/0,
    compute_shared_secret/2,
    derive_session_keys/3,

    %% Encryption
    encrypt/3,
    decrypt/3,

    %% Configuration
    is_encryption_enabled/0
]).

-include("mycelium.hrl").

-define(X25519_KEY_SIZE, 32).
-define(CHACHA20_KEY_SIZE, 32).
-define(CHACHA20_NONCE_SIZE, 12).
-define(POLY1305_TAG_SIZE, 16).

%%====================================================================
%% Key Exchange Functions
%%====================================================================

%% @doc Generate an ephemeral X25519 keypair for key exchange.
-spec generate_ephemeral_keypair() -> {PublicKey :: binary(), PrivateKey :: binary()}.
generate_ephemeral_keypair() ->
    {PubKey, PrivKey} = crypto:generate_key(ecdh, x25519),
    {PubKey, PrivKey}.

%% @doc Compute shared secret using X25519 ECDH.
-spec compute_shared_secret(PeerPublicKey :: binary(), MyPrivateKey :: binary()) -> binary().
compute_shared_secret(PeerPublicKey, MyPrivateKey)
  when byte_size(PeerPublicKey) =:= ?X25519_KEY_SIZE,
       byte_size(MyPrivateKey) =:= ?X25519_KEY_SIZE ->
    crypto:compute_key(ecdh, PeerPublicKey, MyPrivateKey, x25519).

%% @doc Derive session keys from shared secret using HKDF-SHA256.
%% Returns a crypto_session record with send/recv keys based on role.
%% The initiator uses SendKey for sending, RecvKey for receiving.
%% The responder uses RecvKey for sending, SendKey for receiving.
-spec derive_session_keys(SharedSecret :: binary(),
                          InitiatorEphPub :: binary(),
                          ResponderEphPub :: binary()) ->
    {InitiatorSession :: #crypto_session{}, ResponderSession :: #crypto_session{}}.
derive_session_keys(SharedSecret, InitiatorEphPub, ResponderEphPub)
  when byte_size(SharedSecret) =:= ?X25519_KEY_SIZE,
       byte_size(InitiatorEphPub) =:= ?X25519_KEY_SIZE,
       byte_size(ResponderEphPub) =:= ?X25519_KEY_SIZE ->
    %% Sort keys for deterministic derivation
    {First, Second} = if InitiatorEphPub < ResponderEphPub ->
                          {InitiatorEphPub, ResponderEphPub};
                       true ->
                          {ResponderEphPub, InitiatorEphPub}
                      end,
    Salt = <<First/binary, Second/binary>>,
    Info = <<"mycelium-session-v1">>,

    %% HKDF-Extract then Expand for 64 bytes (two 32-byte keys)
    PRK = hkdf_extract(Salt, SharedSecret),
    KeyMaterial = hkdf_expand(PRK, Info, 64),
    <<InitiatorToResponderKey:32/binary, ResponderToInitiatorKey:32/binary>> = KeyMaterial,

    %% Create session records
    InitiatorSession = #crypto_session{
        send_key = InitiatorToResponderKey,
        recv_key = ResponderToInitiatorKey,
        send_nonce = 0,
        recv_nonce = 0
    },
    ResponderSession = #crypto_session{
        send_key = ResponderToInitiatorKey,
        recv_key = InitiatorToResponderKey,
        send_nonce = 0,
        recv_nonce = 0
    },
    {InitiatorSession, ResponderSession}.

%%====================================================================
%% Encryption Functions
%%====================================================================

%% @doc Encrypt data using ChaCha20-Poly1305.
%% Returns {Ciphertext, UpdatedSession} where Ciphertext includes the auth tag.
-spec encrypt(Data :: binary(), Session :: #crypto_session{}, AAD :: binary()) ->
    {ok, Ciphertext :: binary(), UpdatedSession :: #crypto_session{}} | {error, term()}.
encrypt(Data, Session, AAD) when is_binary(Data) ->
    #crypto_session{send_key = Key, send_nonce = Nonce} = Session,
    NonceBytes = make_nonce(Nonce),
    try
        {Ciphertext, Tag} = crypto:crypto_one_time_aead(
            chacha20_poly1305, Key, NonceBytes, Data, AAD, true),
        %% Prepend tag to ciphertext for easier decryption
        Encrypted = <<Tag/binary, Ciphertext/binary>>,
        UpdatedSession = Session#crypto_session{send_nonce = Nonce + 1},
        {ok, Encrypted, UpdatedSession}
    catch
        error:Reason ->
            {error, {encrypt_failed, Reason}}
    end.

%% @doc Decrypt data using ChaCha20-Poly1305.
%% Input format: <<Tag:16/binary, Ciphertext/binary>>
-spec decrypt(EncryptedData :: binary(), Session :: #crypto_session{}, AAD :: binary()) ->
    {ok, Plaintext :: binary(), UpdatedSession :: #crypto_session{}} | {error, term()}.
decrypt(<<Tag:?POLY1305_TAG_SIZE/binary, Ciphertext/binary>>, Session, AAD) ->
    #crypto_session{recv_key = Key, recv_nonce = Nonce} = Session,
    NonceBytes = make_nonce(Nonce),
    try
        case crypto:crypto_one_time_aead(
                chacha20_poly1305, Key, NonceBytes, Ciphertext, AAD, Tag, false) of
            Plaintext when is_binary(Plaintext) ->
                UpdatedSession = Session#crypto_session{recv_nonce = Nonce + 1},
                {ok, Plaintext, UpdatedSession};
            error ->
                {error, decrypt_failed}
        end
    catch
        error:Reason ->
            {error, {decrypt_failed, Reason}}
    end;
decrypt(_, _, _) ->
    {error, invalid_encrypted_data}.

%%====================================================================
%% Configuration
%%====================================================================

%% @doc Check if encryption is enabled for distribution.
-spec is_encryption_enabled() -> boolean().
is_encryption_enabled() ->
    application:get_env(mycelium, encryption_enabled, true).

%%====================================================================
%% Internal Functions
%%====================================================================

%% @doc HKDF-Extract (RFC 5869)
-spec hkdf_extract(Salt :: binary(), IKM :: binary()) -> binary().
hkdf_extract(Salt, IKM) ->
    crypto:mac(hmac, sha256, Salt, IKM).

%% @doc HKDF-Expand (RFC 5869)
-spec hkdf_expand(PRK :: binary(), Info :: binary(), Length :: pos_integer()) -> binary().
hkdf_expand(PRK, Info, Length) ->
    hkdf_expand(PRK, Info, Length, 1, <<>>, <<>>).

hkdf_expand(_PRK, _Info, Length, _Counter, _Prev, Acc) when byte_size(Acc) >= Length ->
    <<Result:Length/binary, _/binary>> = Acc,
    Result;
hkdf_expand(PRK, Info, Length, Counter, Prev, Acc) when Counter =< 255 ->
    T = crypto:mac(hmac, sha256, PRK, <<Prev/binary, Info/binary, Counter:8>>),
    hkdf_expand(PRK, Info, Length, Counter + 1, T, <<Acc/binary, T/binary>>).

%% @doc Create a 12-byte nonce from a 64-bit counter.
%% Format: <<0:32, Counter:64/little>>
-spec make_nonce(non_neg_integer()) -> binary().
make_nonce(Counter) ->
    <<0:32, Counter:64/little>>.
