%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(mycelium_crypto_SUITE).

%% Test suite for mycelium_crypto module
%% Tests X25519 key exchange, HKDF key derivation, and ChaCha20-Poly1305 encryption

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Key exchange tests
-export([
    test_ephemeral_keypair_generation/1,
    test_keypairs_are_unique/1,
    test_shared_secret_computation/1,
    test_shared_secret_symmetry/1,
    test_session_key_derivation/1,
    test_session_keys_are_different/1
]).

%% Encryption tests
-export([
    test_encrypt_decrypt_roundtrip/1,
    test_encrypt_small_data/1,
    test_encrypt_large_data/1,
    test_encrypt_empty_data/1,
    test_nonce_increments/1,
    test_wrong_key_fails/1,
    test_tampered_ciphertext_fails/1,
    test_tampered_tag_fails/1,
    test_wrong_nonce_fails/1
]).

%% Session tests
-export([
    test_initiator_responder_communication/1,
    test_bidirectional_communication/1,
    test_message_ordering/1,
    test_nonce_exhaustion_protection/1
]).

%% Security tests
-export([
    test_ciphertext_different_for_same_plaintext/1,
    test_key_independence/1,
    test_no_plaintext_in_ciphertext/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, key_exchange_tests},
     {group, encryption_tests},
     {group, session_tests},
     {group, security_tests}].

groups() ->
    [
        {key_exchange_tests, [sequence], [
            test_ephemeral_keypair_generation,
            test_keypairs_are_unique,
            test_shared_secret_computation,
            test_shared_secret_symmetry,
            test_session_key_derivation,
            test_session_keys_are_different
        ]},
        {encryption_tests, [sequence], [
            test_encrypt_decrypt_roundtrip,
            test_encrypt_small_data,
            test_encrypt_large_data,
            test_encrypt_empty_data,
            test_nonce_increments,
            test_wrong_key_fails,
            test_tampered_ciphertext_fails,
            test_tampered_tag_fails,
            test_wrong_nonce_fails
        ]},
        {session_tests, [sequence], [
            test_initiator_responder_communication,
            test_bidirectional_communication,
            test_message_ordering,
            test_nonce_exhaustion_protection
        ]},
        {security_tests, [parallel], [
            test_ciphertext_different_for_same_plaintext,
            test_key_independence,
            test_no_plaintext_in_ciphertext
        ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Key Exchange Tests
%%====================================================================

test_ephemeral_keypair_generation(_Config) ->
    {PubKey, PrivKey} = mycelium_crypto:generate_ephemeral_keypair(),

    %% X25519 keys are 32 bytes
    ?assertEqual(32, byte_size(PubKey)),
    ?assertEqual(32, byte_size(PrivKey)),

    %% Keys should be different
    ?assertNotEqual(PubKey, PrivKey),
    ok.

test_keypairs_are_unique(_Config) ->
    %% Generate multiple keypairs
    KeyPairs = [mycelium_crypto:generate_ephemeral_keypair() || _ <- lists:seq(1, 10)],

    %% All public keys should be unique
    PubKeys = [PK || {PK, _} <- KeyPairs],
    ?assertEqual(10, length(lists:usort(PubKeys))),

    %% All private keys should be unique
    PrivKeys = [SK || {_, SK} <- KeyPairs],
    ?assertEqual(10, length(lists:usort(PrivKeys))),
    ok.

test_shared_secret_computation(_Config) ->
    %% Generate two keypairs (Alice and Bob)
    {AlicePub, AlicePriv} = mycelium_crypto:generate_ephemeral_keypair(),
    {BobPub, BobPriv} = mycelium_crypto:generate_ephemeral_keypair(),

    %% Compute shared secrets
    AliceShared = mycelium_crypto:compute_shared_secret(BobPub, AlicePriv),
    BobShared = mycelium_crypto:compute_shared_secret(AlicePub, BobPriv),

    %% Shared secrets should be 32 bytes
    ?assertEqual(32, byte_size(AliceShared)),
    ?assertEqual(32, byte_size(BobShared)),

    %% Shared secrets should be identical (ECDH property)
    ?assertEqual(AliceShared, BobShared),
    ok.

test_shared_secret_symmetry(_Config) ->
    %% Test multiple times to ensure symmetry
    lists:foreach(fun(_) ->
        {APub, APriv} = mycelium_crypto:generate_ephemeral_keypair(),
        {BPub, BPriv} = mycelium_crypto:generate_ephemeral_keypair(),

        SharedA = mycelium_crypto:compute_shared_secret(BPub, APriv),
        SharedB = mycelium_crypto:compute_shared_secret(APub, BPriv),

        ?assertEqual(SharedA, SharedB)
    end, lists:seq(1, 10)),
    ok.

test_session_key_derivation(_Config) ->
    %% Simulate key exchange
    {InitPub, InitPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    {RespPub, RespPriv} = mycelium_crypto:generate_ephemeral_keypair(),

    %% Both sides compute shared secret
    SharedInit = mycelium_crypto:compute_shared_secret(RespPub, InitPriv),
    SharedResp = mycelium_crypto:compute_shared_secret(InitPub, RespPriv),
    ?assertEqual(SharedInit, SharedResp),

    %% Derive session keys
    {InitSession, RespSession} = mycelium_crypto:derive_session_keys(SharedInit, InitPub, RespPub),

    %% Verify session records have correct structure
    ?assert(is_record(InitSession, crypto_session)),
    ?assert(is_record(RespSession, crypto_session)),

    %% Keys should be 32 bytes
    ?assertEqual(32, byte_size(InitSession#crypto_session.send_key)),
    ?assertEqual(32, byte_size(InitSession#crypto_session.recv_key)),
    ?assertEqual(32, byte_size(RespSession#crypto_session.send_key)),
    ?assertEqual(32, byte_size(RespSession#crypto_session.recv_key)),

    %% Initiator's send key should be responder's recv key (and vice versa)
    ?assertEqual(InitSession#crypto_session.send_key, RespSession#crypto_session.recv_key),
    ?assertEqual(InitSession#crypto_session.recv_key, RespSession#crypto_session.send_key),

    %% Nonces should start at 0
    ?assertEqual(0, InitSession#crypto_session.send_nonce),
    ?assertEqual(0, InitSession#crypto_session.recv_nonce),
    ?assertEqual(0, RespSession#crypto_session.send_nonce),
    ?assertEqual(0, RespSession#crypto_session.recv_nonce),
    ok.

test_session_keys_are_different(_Config) ->
    %% Different key exchanges should produce different session keys
    Sessions = lists:map(fun(_) ->
        {IPub, IPriv} = mycelium_crypto:generate_ephemeral_keypair(),
        {RPub, _RPriv} = mycelium_crypto:generate_ephemeral_keypair(),
        Shared = mycelium_crypto:compute_shared_secret(RPub, IPriv),
        {IS, _RS} = mycelium_crypto:derive_session_keys(Shared, IPub, RPub),
        IS#crypto_session.send_key
    end, lists:seq(1, 10)),

    %% All session keys should be unique
    ?assertEqual(10, length(lists:usort(Sessions))),
    ok.

%%====================================================================
%% Encryption Tests
%%====================================================================

test_encrypt_decrypt_roundtrip(_Config) ->
    Session = create_test_session(),
    Plaintext = <<"Hello, encrypted world!">>,
    AAD = <<>>,

    %% Encrypt
    {ok, Ciphertext, Session1} = mycelium_crypto:encrypt(Plaintext, Session, AAD),

    %% Ciphertext should be different from plaintext
    ?assertNotEqual(Plaintext, Ciphertext),

    %% Ciphertext should be larger (16-byte tag + ciphertext)
    ?assert(byte_size(Ciphertext) > byte_size(Plaintext)),

    %% Decrypt using corresponding recv session
    RecvSession = swap_keys(Session),
    {ok, Decrypted, _} = mycelium_crypto:decrypt(Ciphertext, RecvSession, AAD),

    ?assertEqual(Plaintext, Decrypted),

    %% Send nonce should have incremented
    ?assertEqual(1, Session1#crypto_session.send_nonce),
    ok.

test_encrypt_small_data(_Config) ->
    Session = create_test_session(),

    %% Test with various small sizes
    lists:foreach(fun(Size) ->
        Data = crypto:strong_rand_bytes(Size),
        {ok, Cipher, _} = mycelium_crypto:encrypt(Data, Session, <<>>),
        RecvSession = swap_keys(Session),
        {ok, Plain, _} = mycelium_crypto:decrypt(Cipher, RecvSession, <<>>),
        ?assertEqual(Data, Plain)
    end, [1, 2, 4, 8, 15, 16, 17, 31, 32, 33]),
    ok.

test_encrypt_large_data(_Config) ->
    Session = create_test_session(),

    %% Test with larger sizes
    lists:foreach(fun(Size) ->
        Data = crypto:strong_rand_bytes(Size),
        {ok, Cipher, _} = mycelium_crypto:encrypt(Data, Session, <<>>),
        RecvSession = swap_keys(Session),
        {ok, Plain, _} = mycelium_crypto:decrypt(Cipher, RecvSession, <<>>),
        ?assertEqual(Data, Plain)
    end, [1024, 4096, 65536, 1048576]),  %% 1KB, 4KB, 64KB, 1MB
    ok.

test_encrypt_empty_data(_Config) ->
    Session = create_test_session(),

    {ok, Cipher, _} = mycelium_crypto:encrypt(<<>>, Session, <<>>),

    %% Should still have auth tag
    ?assertEqual(16, byte_size(Cipher)),

    RecvSession = swap_keys(Session),
    {ok, Plain, _} = mycelium_crypto:decrypt(Cipher, RecvSession, <<>>),
    ?assertEqual(<<>>, Plain),
    ok.

test_nonce_increments(_Config) ->
    Session0 = create_test_session(),
    ?assertEqual(0, Session0#crypto_session.send_nonce),

    %% Encrypt multiple messages
    {ok, _, Session1} = mycelium_crypto:encrypt(<<"msg1">>, Session0, <<>>),
    ?assertEqual(1, Session1#crypto_session.send_nonce),

    {ok, _, Session2} = mycelium_crypto:encrypt(<<"msg2">>, Session1, <<>>),
    ?assertEqual(2, Session2#crypto_session.send_nonce),

    {ok, _, Session3} = mycelium_crypto:encrypt(<<"msg3">>, Session2, <<>>),
    ?assertEqual(3, Session3#crypto_session.send_nonce),
    ok.

test_wrong_key_fails(_Config) ->
    Session1 = create_test_session(),
    Session2 = create_test_session(),  %% Different keys

    Plaintext = <<"Secret message">>,
    {ok, Ciphertext, _} = mycelium_crypto:encrypt(Plaintext, Session1, <<>>),

    %% Try to decrypt with wrong key
    WrongSession = swap_keys(Session2),
    Result = mycelium_crypto:decrypt(Ciphertext, WrongSession, <<>>),
    ?assertEqual({error, decrypt_failed}, Result),
    ok.

test_tampered_ciphertext_fails(_Config) ->
    Session = create_test_session(),
    Plaintext = <<"Original message">>,

    {ok, Ciphertext, _} = mycelium_crypto:encrypt(Plaintext, Session, <<>>),

    %% Tamper with ciphertext (flip a bit in the ciphertext part, not tag)
    <<Tag:16/binary, OrigCipher/binary>> = Ciphertext,
    <<First:8, Rest/binary>> = OrigCipher,
    TamperedFirst = First bxor 1,
    TamperedCipher = <<TamperedFirst:8, Rest/binary>>,
    Tampered = <<Tag/binary, TamperedCipher/binary>>,

    RecvSession = swap_keys(Session),
    Result = mycelium_crypto:decrypt(Tampered, RecvSession, <<>>),
    ?assertEqual({error, decrypt_failed}, Result),
    ok.

test_tampered_tag_fails(_Config) ->
    Session = create_test_session(),
    Plaintext = <<"Original message">>,

    {ok, Ciphertext, _} = mycelium_crypto:encrypt(Plaintext, Session, <<>>),

    %% Tamper with auth tag
    <<Tag:16/binary, Cipher/binary>> = Ciphertext,
    <<TagFirst:8, TagRest/binary>> = Tag,
    TamperedTagFirst = TagFirst bxor 1,
    TamperedTag = <<TamperedTagFirst:8, TagRest/binary>>,
    Tampered = <<TamperedTag/binary, Cipher/binary>>,

    RecvSession = swap_keys(Session),
    Result = mycelium_crypto:decrypt(Tampered, RecvSession, <<>>),
    ?assertEqual({error, decrypt_failed}, Result),
    ok.

test_wrong_nonce_fails(_Config) ->
    Session = create_test_session(),

    %% Encrypt a message
    {ok, Ciphertext, _Session1} = mycelium_crypto:encrypt(<<"Message">>, Session, <<>>),

    %% Try to decrypt with wrong nonce (skip one)
    RecvSession = swap_keys(Session),
    RecvSession1 = RecvSession#crypto_session{recv_nonce = 1},  %% Wrong nonce

    Result = mycelium_crypto:decrypt(Ciphertext, RecvSession1, <<>>),
    ?assertEqual({error, decrypt_failed}, Result),
    ok.

%%====================================================================
%% Session Tests
%%====================================================================

test_initiator_responder_communication(_Config) ->
    %% Simulate full key exchange
    {InitPub, InitPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    {RespPub, RespPriv} = mycelium_crypto:generate_ephemeral_keypair(),

    %% Both compute shared secret
    SharedInit = mycelium_crypto:compute_shared_secret(RespPub, InitPriv),
    _SharedResp = mycelium_crypto:compute_shared_secret(InitPub, RespPriv),

    %% Derive session keys
    {InitSession, RespSession} = mycelium_crypto:derive_session_keys(SharedInit, InitPub, RespPub),

    %% Initiator sends to responder
    Msg1 = <<"Hello from initiator">>,
    {ok, Cipher1, InitSession1} = mycelium_crypto:encrypt(Msg1, InitSession, <<>>),
    {ok, Plain1, RespSession1} = mycelium_crypto:decrypt(Cipher1, RespSession, <<>>),
    ?assertEqual(Msg1, Plain1),

    %% Responder sends to initiator
    Msg2 = <<"Hello from responder">>,
    {ok, Cipher2, _RespSession2} = mycelium_crypto:encrypt(Msg2, RespSession1, <<>>),
    {ok, Plain2, _InitSession2} = mycelium_crypto:decrypt(Cipher2, InitSession1, <<>>),
    ?assertEqual(Msg2, Plain2),
    ok.

test_bidirectional_communication(_Config) ->
    %% Create paired sessions
    {InitPub, InitPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    {RespPub, _RespPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    Shared = mycelium_crypto:compute_shared_secret(RespPub, InitPriv),
    {InitSession, RespSession} = mycelium_crypto:derive_session_keys(Shared, InitPub, RespPub),

    %% Send multiple messages in both directions
    {InitS1, RespS1} = exchange_message(InitSession, RespSession, <<"Init->Resp 1">>),
    {RespS2, InitS2} = exchange_message(RespS1, InitS1, <<"Resp->Init 1">>),
    {InitS3, RespS3} = exchange_message(InitS2, RespS2, <<"Init->Resp 2">>),
    {RespS4, InitS4} = exchange_message(RespS3, InitS3, <<"Resp->Init 2">>),

    %% Verify nonces
    ?assertEqual(2, InitS4#crypto_session.send_nonce),
    ?assertEqual(2, InitS4#crypto_session.recv_nonce),
    ?assertEqual(2, RespS4#crypto_session.send_nonce),
    ?assertEqual(2, RespS4#crypto_session.recv_nonce),
    ok.

test_message_ordering(_Config) ->
    {InitPub, InitPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    {RespPub, _RespPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    Shared = mycelium_crypto:compute_shared_secret(RespPub, InitPriv),
    {InitSession, RespSession} = mycelium_crypto:derive_session_keys(Shared, InitPub, RespPub),

    %% Send 100 messages
    Messages = [list_to_binary(io_lib:format("Message ~p", [N])) || N <- lists:seq(1, 100)],

    {_FinalInit, Ciphertexts} = lists:foldl(fun(Msg, {Session, Acc}) ->
        {ok, Cipher, NewSession} = mycelium_crypto:encrypt(Msg, Session, <<>>),
        {NewSession, [Cipher | Acc]}
    end, {InitSession, []}, Messages),

    %% Decrypt in correct order
    CiphersInOrder = lists:reverse(Ciphertexts),
    {_FinalResp, Decrypted} = lists:foldl(fun(Cipher, {Session, Acc}) ->
        {ok, Plain, NewSession} = mycelium_crypto:decrypt(Cipher, Session, <<>>),
        {NewSession, [Plain | Acc]}
    end, {RespSession, []}, CiphersInOrder),

    ?assertEqual(Messages, lists:reverse(Decrypted)),
    ok.

test_nonce_exhaustion_protection(_Config) ->
    Session = create_test_session(),

    %% Set nonce to near max (this is a simplified test)
    %% In real use, we'd need to handle nonce rollover
    HighNonce = 16#FFFFFFFFFFFFFFFF - 10,
    HighSession = Session#crypto_session{send_nonce = HighNonce},

    %% Should still work for remaining nonces
    {ok, _, Session1} = mycelium_crypto:encrypt(<<"Test">>, HighSession, <<>>),
    ?assertEqual(HighNonce + 1, Session1#crypto_session.send_nonce),
    ok.

%%====================================================================
%% Security Tests
%%====================================================================

test_ciphertext_different_for_same_plaintext(_Config) ->
    Session0 = create_test_session(),
    Plaintext = <<"Same message">>,

    %% Encrypt same plaintext multiple times
    {ok, C1, Session1} = mycelium_crypto:encrypt(Plaintext, Session0, <<>>),
    {ok, C2, Session2} = mycelium_crypto:encrypt(Plaintext, Session1, <<>>),
    {ok, C3, _} = mycelium_crypto:encrypt(Plaintext, Session2, <<>>),

    %% All ciphertexts should be different (different nonces)
    ?assertNotEqual(C1, C2),
    ?assertNotEqual(C2, C3),
    ?assertNotEqual(C1, C3),
    ok.

test_key_independence(_Config) ->
    %% Different sessions with different keys should produce different ciphertexts
    Session1 = create_test_session(),
    Session2 = create_test_session(),
    Plaintext = <<"Test message">>,

    {ok, C1, _} = mycelium_crypto:encrypt(Plaintext, Session1, <<>>),
    {ok, C2, _} = mycelium_crypto:encrypt(Plaintext, Session2, <<>>),

    %% Should be completely different
    ?assertNotEqual(C1, C2),
    ok.

test_no_plaintext_in_ciphertext(_Config) ->
    Session = create_test_session(),
    Plaintext = <<"UNIQUE_MARKER_STRING_FOR_SEARCH">>,

    {ok, Ciphertext, _} = mycelium_crypto:encrypt(Plaintext, Session, <<>>),

    %% Plaintext should not appear in ciphertext
    ?assertEqual(nomatch, binary:match(Ciphertext, Plaintext)),

    %% Also check for partial matches
    ?assertEqual(nomatch, binary:match(Ciphertext, <<"UNIQUE_MARKER">>)),
    ok.

%%====================================================================
%% Helper Functions
%%====================================================================

create_test_session() ->
    {InitPub, InitPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    {RespPub, _RespPriv} = mycelium_crypto:generate_ephemeral_keypair(),
    Shared = mycelium_crypto:compute_shared_secret(RespPub, InitPriv),
    {InitSession, _RespSession} = mycelium_crypto:derive_session_keys(Shared, InitPub, RespPub),
    InitSession.

swap_keys(Session) ->
    #crypto_session{
        send_key = Session#crypto_session.recv_key,
        recv_key = Session#crypto_session.send_key,
        send_nonce = Session#crypto_session.recv_nonce,
        recv_nonce = Session#crypto_session.send_nonce
    }.

exchange_message(SenderSession, ReceiverSession, Message) ->
    {ok, Cipher, NewSender} = mycelium_crypto:encrypt(Message, SenderSession, <<>>),
    {ok, Plain, NewReceiver} = mycelium_crypto:decrypt(Cipher, ReceiverSession, <<>>),
    ?assertEqual(Message, Plain),
    {NewSender, NewReceiver}.
