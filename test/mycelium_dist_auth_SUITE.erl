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

%% Test cases - Trust mode
-export([
    test_strict_rejects_unknown/1,
    test_tofu_accepts_first/1,
    test_tofu_rejects_key_change/1,
    test_key_persistence_to_disk/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, unit_tests}, {group, protocol_tests}, {group, trust_tests}].

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
            test_invalid_message_rejected
        ]},
        {trust_tests, [sequence], [
            test_strict_rejects_unknown,
            test_tofu_accepts_first,
            test_tofu_rejects_key_change,
            test_key_persistence_to_disk
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

test_strict_rejects_unknown(_Config) ->
    %% Set strict mode
    mycelium_dist_keys:set_trust_mode(strict),
    ?assertEqual(strict, mycelium_dist_keys:get_trust_mode()),

    %% Unknown node should not be trusted
    UnknownNode = 'unknown@host',
    UnknownKey = crypto:strong_rand_bytes(32),
    ?assertNot(mycelium_dist_keys:is_trusted(UnknownNode, UnknownKey)),
    ok.

test_tofu_accepts_first(_Config) ->
    %% Set TOFU mode
    mycelium_dist_keys:set_trust_mode(tofu),
    ?assertEqual(tofu, mycelium_dist_keys:get_trust_mode()),

    %% Store a new key (TOFU)
    NewNode = 'newnode@host',
    NewKey = crypto:strong_rand_bytes(32),
    ok = mycelium_dist_keys:store_key_if_new(NewNode, NewKey),

    %% Should now be trusted
    ?assert(mycelium_dist_keys:is_trusted(NewNode, NewKey)),

    %% Can look it up
    {ok, LookedUpKey} = mycelium_dist_keys:lookup_key(NewNode),
    ?assertEqual(NewKey, LookedUpKey),
    ok.

test_tofu_rejects_key_change(_Config) ->
    mycelium_dist_keys:set_trust_mode(tofu),

    %% Store a key
    Node = 'stable@host',
    OriginalKey = crypto:strong_rand_bytes(32),
    ok = mycelium_dist_keys:store_key_if_new(Node, OriginalKey),

    %% Try to store a different key for the same node
    DifferentKey = crypto:strong_rand_bytes(32),
    {error, key_mismatch} = mycelium_dist_keys:store_key_if_new(Node, DifferentKey),

    %% Original key should still be trusted
    ?assert(mycelium_dist_keys:is_trusted(Node, OriginalKey)),

    %% Different key should NOT be trusted
    ?assertNot(mycelium_dist_keys:is_trusted(Node, DifferentKey)),
    ok.

test_key_persistence_to_disk(Config) ->
    KeyDir = proplists:get_value(key_dir, Config),
    mycelium_dist_keys:set_trust_mode(tofu),

    %% Store a key
    Node = 'persistent@host',
    PubKey = crypto:strong_rand_bytes(32),
    ok = mycelium_dist_keys:store_key_if_new(Node, PubKey),

    %% Check file was created
    TrustedDir = filename:join(KeyDir, "trusted"),
    KeyFile = filename:join(TrustedDir, "persistent@host.pub"),
    ?assert(filelib:is_file(KeyFile)),

    %% Read the file and verify contents
    {ok, FileContents} = file:read_file(KeyFile),
    ?assertEqual(PubKey, FileContents),

    %% Delete the key
    ok = mycelium_dist_keys:delete_key(Node),
    ?assertNot(filelib:is_file(KeyFile)),
    ok.
