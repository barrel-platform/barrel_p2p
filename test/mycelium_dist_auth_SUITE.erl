%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(mycelium_dist_auth_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases - Unit tests
-export([
    test_keypair_generation/1,
    test_keypair_persistence/1,
    test_sign_verify_roundtrip/1,
    test_invalid_signature_rejected/1,
    test_replay_attack_prevented/1,
    test_timestamp_window_enforced/1
]).

%% Test cases - Protocol encoding
-export([
    test_hello_encode_decode/1,
    test_challenge_encode_decode/1,
    test_response_encode_decode/1,
    test_ok_fail_encode_decode/1,
    test_invalid_message_rejected/1
]).

%% Test cases - Trust mode (the four handshake decisions)
-export([
    test_strict_rejects_unknown/1,
    test_tofu_accepts_and_stores/1,
    test_conflicting_key_rejected/1,
    test_lookup_pin_tri_state/1,
    test_wrong_signature_rejected/1,
    test_key_persistence_to_disk/1
]).

%% Test cases - Whitelist
-export([
    test_whitelist_exact_match/1,
    test_whitelist_wildcard_host/1,
    test_whitelist_wildcard_name/1,
    test_whitelist_no_match/1,
    test_whitelist_empty/1,
    test_whitelist_invalid_pattern/1
]).

%% Test cases - Key exchange protocol
-export([
    test_key_exchange_encode_decode/1,
    test_key_exchange_invalid_size/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, unit_tests}, {group, protocol_tests}, {group, trust_tests},
     {group, whitelist_tests}, {group, key_exchange_tests}].

groups() ->
    [
        {unit_tests, [sequence], [
            test_keypair_generation,
            test_keypair_persistence,
            test_sign_verify_roundtrip,
            test_invalid_signature_rejected,
            test_replay_attack_prevented,
            test_timestamp_window_enforced
        ]},
        {protocol_tests, [sequence], [
            test_hello_encode_decode,
            test_challenge_encode_decode,
            test_response_encode_decode,
            test_ok_fail_encode_decode,
            test_invalid_message_rejected,
            test_key_exchange_encode_decode,
            test_key_exchange_invalid_size
        ]},
        {trust_tests, [sequence], [
            test_strict_rejects_unknown,
            test_tofu_accepts_and_stores,
            test_conflicting_key_rejected,
            test_lookup_pin_tri_state,
            test_wrong_signature_rejected,
            test_key_persistence_to_disk
        ]},
        {whitelist_tests, [sequence], [
            test_whitelist_exact_match,
            test_whitelist_wildcard_host,
            test_whitelist_wildcard_name,
            test_whitelist_no_match,
            test_whitelist_empty,
            test_whitelist_invalid_pattern
        ]},
        {key_exchange_tests, [sequence], [
            test_key_exchange_encode_decode,
            test_key_exchange_invalid_size
        ]}
    ].

init_per_suite(Config) ->
    %% Create a temporary directory for keys
    PrivDir = proplists:get_value(priv_dir, Config),
    KeyDir = filename:join(PrivDir, "keys"),
    ok = filelib:ensure_dir(filename:join(KeyDir, "dummy")),
    [{key_dir, KeyDir} | Config].

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Set up test key directory
    KeyDir = proplists:get_value(key_dir, Config),
    application:set_env(mycelium, auth_key_dir, KeyDir),
    application:set_env(mycelium, auth_enabled, true),
    application:set_env(mycelium, auth_trust_mode, tofu),
    application:set_env(mycelium, auth_handshake_timeout, 10000),
    application:set_env(mycelium, auth_timestamp_window, 30000),

    %% Start the application for tests that need it
    {ok, _} = application:ensure_all_started(mycelium),
    Config.

end_per_testcase(_TestCase, _Config) ->
    application:stop(mycelium),
    ok.

%%====================================================================
%% Unit Tests
%%====================================================================

test_keypair_generation(_Config) ->
    %% Generate a keypair
    {PubKey, PrivKey} = mycelium_dist_auth:generate_keypair(),

    %% Verify sizes
    ?assertEqual(32, byte_size(PubKey)),
    ?assertEqual(32, byte_size(PrivKey)),

    %% Generate another keypair - should be different
    {PubKey2, PrivKey2} = mycelium_dist_auth:generate_keypair(),
    ?assertNotEqual(PubKey, PubKey2),
    ?assertNotEqual(PrivKey, PrivKey2),
    ok.

test_keypair_persistence(Config) ->
    KeyDir = proplists:get_value(key_dir, Config),

    %% Generate and save a keypair
    {PubKey, PrivKey} = mycelium_dist_auth:generate_keypair(),
    ok = mycelium_dist_auth:save_keypair(KeyDir, PubKey, PrivKey),

    %% Load it back
    {ok, LoadedPubKey, LoadedPrivKey} = mycelium_dist_auth:load_keypair(KeyDir),
    ?assertEqual(PubKey, LoadedPubKey),
    ?assertEqual(PrivKey, LoadedPrivKey),
    ok.

test_sign_verify_roundtrip(_Config) ->
    %% Ensure keypair exists
    ok = mycelium_dist_auth:ensure_keypair(),

    %% Create a challenge
    {Nonce, Timestamp} = mycelium_dist_auth:create_challenge(),
    ?assertEqual(32, byte_size(Nonce)),
    ?assert(is_integer(Timestamp)),

    %% Sign the challenge
    {ok, Signature} = mycelium_dist_auth:sign_challenge(Nonce, Timestamp),
    ?assertEqual(64, byte_size(Signature)),

    %% Verify with our own public key
    {ok, PubKey} = mycelium_dist_auth:get_public_key(),
    ?assert(mycelium_dist_auth:verify_response(Signature, PubKey, {Nonce, Timestamp})),
    ok.

test_invalid_signature_rejected(_Config) ->
    ok = mycelium_dist_auth:ensure_keypair(),
    {ok, PubKey} = mycelium_dist_auth:get_public_key(),

    {Nonce, Timestamp} = mycelium_dist_auth:create_challenge(),

    %% Create a bogus signature
    BogusSignature = crypto:strong_rand_bytes(64),

    %% Should fail verification
    ?assertNot(mycelium_dist_auth:verify_response(BogusSignature, PubKey, {Nonce, Timestamp})),
    ok.

test_replay_attack_prevented(_Config) ->
    ok = mycelium_dist_auth:ensure_keypair(),
    {ok, PubKey} = mycelium_dist_auth:get_public_key(),

    %% Create a valid challenge and signature
    {Nonce, Timestamp} = mycelium_dist_auth:create_challenge(),
    {ok, Signature} = mycelium_dist_auth:sign_challenge(Nonce, Timestamp),

    %% Verify with correct timestamp - should pass
    ?assert(mycelium_dist_auth:verify_response(Signature, PubKey, {Nonce, Timestamp})),

    %% Modify the nonce - should fail
    ModifiedNonce = crypto:strong_rand_bytes(32),
    ?assertNot(mycelium_dist_auth:verify_response(Signature, PubKey, {ModifiedNonce, Timestamp})),
    ok.

test_timestamp_window_enforced(_Config) ->
    ok = mycelium_dist_auth:ensure_keypair(),
    {ok, PubKey} = mycelium_dist_auth:get_public_key(),

    %% Create a challenge with a very old timestamp
    Nonce = crypto:strong_rand_bytes(32),
    OldTimestamp = erlang:system_time(millisecond) - 60000,  %% 60 seconds ago

    %% Sign with old timestamp
    {ok, PrivKey} = mycelium_dist_auth:get_private_key(),
    Message = <<Nonce/binary, OldTimestamp:64/big, PubKey/binary>>,
    Signature = crypto:sign(eddsa, none, Message, [PrivKey, ed25519]),

    %% Verification should fail due to timestamp
    ?assertNot(mycelium_dist_auth:verify_response(Signature, PubKey, {Nonce, OldTimestamp})),
    ok.

%%====================================================================
%% Protocol Tests
%%====================================================================

test_hello_encode_decode(_Config) ->
    NodeName = 'test@localhost',
    PubKey = crypto:strong_rand_bytes(32),

    Encoded = mycelium_dist_protocol:encode_hello(NodeName, PubKey),
    {hello, DecodedNode, DecodedPubKey} = mycelium_dist_protocol:decode(Encoded),

    ?assertEqual(NodeName, DecodedNode),
    ?assertEqual(PubKey, DecodedPubKey),
    ok.

test_challenge_encode_decode(_Config) ->
    Nonce = crypto:strong_rand_bytes(32),
    Timestamp = erlang:system_time(millisecond),

    Encoded = mycelium_dist_protocol:encode_challenge(Nonce, Timestamp),
    {challenge, DecodedNonce, DecodedTimestamp} = mycelium_dist_protocol:decode(Encoded),

    ?assertEqual(Nonce, DecodedNonce),
    ?assertEqual(Timestamp, DecodedTimestamp),
    ok.

test_response_encode_decode(_Config) ->
    Signature = crypto:strong_rand_bytes(64),

    Encoded = mycelium_dist_protocol:encode_response(Signature),
    {response, DecodedSignature} = mycelium_dist_protocol:decode(Encoded),

    ?assertEqual(Signature, DecodedSignature),
    ok.

test_ok_fail_encode_decode(_Config) ->
    %% Test OK message
    EncodedOk = mycelium_dist_protocol:encode_ok(),
    ?assertEqual(ok, mycelium_dist_protocol:decode(EncodedOk)),

    %% Test FAIL message
    Reason = <<"untrusted_key">>,
    EncodedFail = mycelium_dist_protocol:encode_fail(Reason),
    {fail, DecodedReason} = mycelium_dist_protocol:decode(EncodedFail),
    ?assertEqual(Reason, DecodedReason),
    ok.

test_invalid_message_rejected(_Config) ->
    %% Test unknown message type
    {error, {unknown_message_type, 99}} = mycelium_dist_protocol:decode(<<99:8, "garbage">>),

    %% Test malformed message
    {error, malformed_message} = mycelium_dist_protocol:decode(<<>>),

    %% Test invalid hello payload
    {error, invalid_hello_payload} = mycelium_dist_protocol:decode(<<1:8, 1:8, 100:16/big, "short">>),
    ok.

%%====================================================================
%% Trust Mode Tests
%%====================================================================

%% Peer presents a fingerprint we have never seen, strict mode -> reject.
test_strict_rejects_unknown(_Config) ->
    mycelium_dist_keys:set_trust_mode(strict),
    ?assertEqual(strict, mycelium_dist_keys:get_trust_mode()),

    Peer = 'unknown@host',
    UnknownKey = crypto:strong_rand_bytes(32),
    ?assertNot(mycelium_dist_keys:is_trusted(Peer, UnknownKey)),
    ?assertEqual({error, not_found}, mycelium_dist_keys:lookup_key(Peer)),
    ok.

%% Peer presents a fingerprint we have never seen, TOFU mode -> accept and store.
test_tofu_accepts_and_stores(_Config) ->
    mycelium_dist_keys:set_trust_mode(tofu),
    ?assertEqual(tofu, mycelium_dist_keys:get_trust_mode()),

    Peer = 'fresh@host',
    NewKey = crypto:strong_rand_bytes(32),

    ok = mycelium_dist_keys:store_key_if_new(Peer, NewKey),
    ?assert(mycelium_dist_keys:is_trusted(Peer, NewKey)),

    {ok, StoredKey} = mycelium_dist_keys:lookup_key(Peer),
    ?assertEqual(NewKey, StoredKey),
    ok.

%% Peer presents a fingerprint that conflicts with the one stored for that
%% node -> reject (key change / possible attack).
test_conflicting_key_rejected(_Config) ->
    mycelium_dist_keys:set_trust_mode(tofu),

    Peer = 'rotated@host',
    OriginalKey = crypto:strong_rand_bytes(32),
    ok = mycelium_dist_keys:store_key_if_new(Peer, OriginalKey),
    ?assert(mycelium_dist_keys:is_trusted(Peer, OriginalKey)),

    %% A different key for the same node is a conflict.
    ConflictingKey = crypto:strong_rand_bytes(32),
    ?assertNotEqual(OriginalKey, ConflictingKey),
    ?assertNot(mycelium_dist_keys:is_trusted(Peer, ConflictingKey)),
    ?assertEqual({error, key_mismatch},
                 mycelium_dist_keys:store_key_if_new(Peer, ConflictingKey)),
    ok.

%% lookup_pin/1 distinguishes "no pin", "pin matches", "pin differs".
%% The TOFU re-pin fix depends on this tri-state: a mismatch must be
%% rejected even in TOFU mode.
test_lookup_pin_tri_state(_Config) ->
    Peer = 'tri@host',
    ?assertEqual(not_pinned, mycelium_dist_keys:lookup_pin(Peer)),

    Pinned = crypto:strong_rand_bytes(32),
    ok = mycelium_dist_keys:store_key(Peer, Pinned),
    ?assertEqual({pinned, Pinned}, mycelium_dist_keys:lookup_pin(Peer)),

    Other = crypto:strong_rand_bytes(32),
    ?assertNotEqual(Pinned, Other),
    %% lookup_pin returns the *stored* key, not the presented one,
    %% so callers can compare and reject.
    ?assertMatch({pinned, Pinned}, mycelium_dist_keys:lookup_pin(Peer)),
    ?assertEqual({error, key_mismatch},
                 mycelium_dist_keys:store_key_if_new(Peer, Other)),
    ok.

%% Peer signs the challenge with the wrong key -> verify_response rejects.
test_wrong_signature_rejected(_Config) ->
    ok = mycelium_dist_auth:ensure_keypair(),
    {Nonce, Timestamp} = mycelium_dist_auth:create_challenge(),

    %% Sign with our own key, then claim a different public key as origin.
    {ok, Signature} = mycelium_dist_auth:sign_challenge(Nonce, Timestamp),
    {WrongPubKey, _WrongPriv} = mycelium_dist_auth:generate_keypair(),

    ?assertNot(mycelium_dist_auth:verify_response(Signature, WrongPubKey, {Nonce, Timestamp})),
    ok.

test_key_persistence_to_disk(Config) ->
    KeyDir = proplists:get_value(key_dir, Config),
    mycelium_dist_keys:set_trust_mode(tofu),

    Peer = 'persist@host',
    PubKey = crypto:strong_rand_bytes(32),
    ok = mycelium_dist_keys:store_key_if_new(Peer, PubKey),

    %% File is named <Node>.pub under <KeyDir>/trusted/.
    TrustedDir = filename:join(KeyDir, "trusted"),
    KeyFile = filename:join(TrustedDir, atom_to_list(Peer) ++ ".pub"),
    ?assert(filelib:is_file(KeyFile)),

    %% File contents are the raw 32-byte public key.
    {ok, FileContents} = file:read_file(KeyFile),
    ?assertEqual(PubKey, FileContents),

    ok = mycelium_dist_keys:delete_key(Peer),
    ?assertNot(filelib:is_file(KeyFile)),
    ok.

%%====================================================================
%% Whitelist Tests
%%====================================================================

test_whitelist_exact_match(_Config) ->
    %% Set up whitelist with exact match
    application:set_env(mycelium, cookie_only_nodes, ['cnode@localhost']),

    %% Exact match should be allowed
    ?assert(mycelium_dist_auth:is_cookie_only_allowed('cnode@localhost')),

    %% Different node should not match
    ?assertNot(mycelium_dist_auth:is_cookie_only_allowed('other@localhost')),
    ?assertNot(mycelium_dist_auth:is_cookie_only_allowed('cnode@otherhost')),
    ok.

test_whitelist_wildcard_host(_Config) ->
    %% Set up whitelist with wildcard host
    application:set_env(mycelium, cookie_only_nodes, ['monitor@*']),

    %% Any host should match
    ?assert(mycelium_dist_auth:is_cookie_only_allowed('monitor@localhost')),
    ?assert(mycelium_dist_auth:is_cookie_only_allowed('monitor@server1')),
    ?assert(mycelium_dist_auth:is_cookie_only_allowed('monitor@192.168.1.1')),

    %% Different name should not match
    ?assertNot(mycelium_dist_auth:is_cookie_only_allowed('other@localhost')),
    ok.

test_whitelist_wildcard_name(_Config) ->
    %% Set up whitelist with wildcard name
    application:set_env(mycelium, cookie_only_nodes, ['*@trusted.local']),

    %% Any name should match on trusted.local
    ?assert(mycelium_dist_auth:is_cookie_only_allowed('cnode@trusted.local')),
    ?assert(mycelium_dist_auth:is_cookie_only_allowed('monitor@trusted.local')),
    ?assert(mycelium_dist_auth:is_cookie_only_allowed('anything@trusted.local')),

    %% Different host should not match
    ?assertNot(mycelium_dist_auth:is_cookie_only_allowed('cnode@untrusted.local')),
    ok.

test_whitelist_no_match(_Config) ->
    %% Set up whitelist
    application:set_env(mycelium, cookie_only_nodes, [
        'cnode@localhost',
        'monitor@*',
        '*@trusted.local'
    ]),

    %% Nodes that don't match any pattern
    ?assertNot(mycelium_dist_auth:is_cookie_only_allowed('random@random')),
    ?assertNot(mycelium_dist_auth:is_cookie_only_allowed('other@server')),
    ok.

test_whitelist_empty(_Config) ->
    %% Empty whitelist
    application:set_env(mycelium, cookie_only_nodes, []),

    %% Nothing should match
    ?assertNot(mycelium_dist_auth:is_cookie_only_allowed('cnode@localhost')),
    ?assertNot(mycelium_dist_auth:is_cookie_only_allowed('anything@anywhere')),
    ok.

test_whitelist_invalid_pattern(_Config) ->
    %% Set up whitelist with valid and invalid patterns
    application:set_env(mycelium, cookie_only_nodes, [
        'valid@localhost',
        invalid_no_at,  %% Missing @
        'also@valid'
    ]),

    %% Valid patterns should work
    ?assert(mycelium_dist_auth:is_cookie_only_allowed('valid@localhost')),
    ?assert(mycelium_dist_auth:is_cookie_only_allowed('also@valid')),

    %% Invalid pattern should not crash, just not match
    ?assertNot(mycelium_dist_auth:is_cookie_only_allowed('invalid_no_at@somewhere')),
    ok.

%%====================================================================
%% Key Exchange Protocol Tests
%%====================================================================

test_key_exchange_encode_decode(_Config) ->
    %% Generate X25519 keypair
    {PubKey, _PrivKey} = crypto:generate_key(ecdh, x25519),
    ?assertEqual(32, byte_size(PubKey)),

    %% Encode key exchange message
    Encoded = mycelium_dist_protocol:encode_key_exchange(PubKey),

    %% Decode and verify
    {key_exchange, DecodedPubKey} = mycelium_dist_protocol:decode(Encoded),
    ?assertEqual(PubKey, DecodedPubKey),
    ok.

test_key_exchange_invalid_size(_Config) ->
    %% Try to decode with wrong key size
    InvalidMsg = <<6:8, "short">>,  %% Type 6 = KEY_EXCHANGE, but only 5 bytes
    Result = mycelium_dist_protocol:decode(InvalidMsg),
    ?assertEqual({error, invalid_key_exchange_payload}, Result),
    ok.
