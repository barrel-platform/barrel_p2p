%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(barrel_p2p_dist_auth_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("barrel_p2p.hrl").

%% Fixed 32-byte TLS channel binding used by the sign/verify unit tests.
-define(TEST_BINDING, <<7:256>>).

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
    test_invalid_message_rejected/1,
    test_hello_decode_does_not_mint_atom/1
]).

%% Test cases - Trust mode (the four handshake decisions)
-export([
    test_strict_rejects_unknown/1,
    test_tofu_accepts_and_stores/1,
    test_conflicting_key_rejected/1,
    test_lookup_pin_tri_state/1,
    test_wrong_signature_rejected/1,
    test_key_persistence_to_disk/1,
    test_verify_response_uses_monotonic/1,
    test_peer_ts_outside_window_rejected/1,
    test_peer_ts_within_window_accepted/1,
    test_channel_binding_mismatch_rejected/1,
    test_reflection_rejected/1,
    test_peer_name_bound/1,
    test_transcript_layout/1,
    test_client_refuses_other_name/1,
    test_client_requires_dial_target/1
]).

%% Test cases - Whitelist
-export([
    test_whitelist_exact_match/1,
    test_whitelist_wildcard_host/1,
    test_whitelist_wildcard_name/1,
    test_whitelist_no_match/1,
    test_whitelist_empty/1,
    test_whitelist_invalid_pattern/1,
    test_whitelist_matches_binary_name/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [
        {group, unit_tests},
        {group, protocol_tests},
        {group, trust_tests},
        {group, whitelist_tests}
    ].

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
            test_hello_decode_does_not_mint_atom
        ]},
        {trust_tests, [sequence], [
            test_strict_rejects_unknown,
            test_tofu_accepts_and_stores,
            test_conflicting_key_rejected,
            test_lookup_pin_tri_state,
            test_wrong_signature_rejected,
            test_key_persistence_to_disk,
            test_verify_response_uses_monotonic,
            test_peer_ts_outside_window_rejected,
            test_peer_ts_within_window_accepted,
            test_channel_binding_mismatch_rejected,
            test_reflection_rejected,
            test_peer_name_bound,
            test_transcript_layout,
            test_client_refuses_other_name,
            test_client_requires_dial_target
        ]},
        {whitelist_tests, [sequence], [
            test_whitelist_exact_match,
            test_whitelist_wildcard_host,
            test_whitelist_wildcard_name,
            test_whitelist_no_match,
            test_whitelist_empty,
            test_whitelist_invalid_pattern,
            test_whitelist_matches_binary_name
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
    application:set_env(barrel_p2p, auth_key_dir, KeyDir),
    application:set_env(barrel_p2p, auth_enabled, true),
    application:set_env(barrel_p2p, auth_trust_mode, tofu),
    application:set_env(barrel_p2p, auth_handshake_timeout, 10000),
    application:set_env(barrel_p2p, auth_timestamp_window, 30000),
    %% Start clean: whitelist tests mutate this env, and a leftover value
    %% would trip the default-cookie boot guard on the next start.
    application:set_env(barrel_p2p, cookie_only_nodes, []),

    %% Start the application for tests that need it
    {ok, _} = application:ensure_all_started(barrel_p2p),
    Config.

end_per_testcase(_TestCase, _Config) ->
    application:stop(barrel_p2p),
    %% Do not leak the whitelist env into later suites sharing this VM.
    application:set_env(barrel_p2p, cookie_only_nodes, []),
    ok.

%%====================================================================
%% Unit Tests
%%====================================================================

test_keypair_generation(_Config) ->
    %% Generate a keypair
    {PubKey, PrivKey} = barrel_p2p_dist_auth:generate_keypair(),

    %% Verify sizes
    ?assertEqual(32, byte_size(PubKey)),
    ?assertEqual(32, byte_size(PrivKey)),

    %% Generate another keypair - should be different
    {PubKey2, PrivKey2} = barrel_p2p_dist_auth:generate_keypair(),
    ?assertNotEqual(PubKey, PubKey2),
    ?assertNotEqual(PrivKey, PrivKey2),
    ok.

test_keypair_persistence(Config) ->
    KeyDir = proplists:get_value(key_dir, Config),

    %% Generate and save a keypair
    {PubKey, PrivKey} = barrel_p2p_dist_auth:generate_keypair(),
    ok = barrel_p2p_dist_auth:save_keypair(KeyDir, PubKey, PrivKey),

    %% Load it back
    {ok, LoadedPubKey, LoadedPrivKey} = barrel_p2p_dist_auth:load_keypair(KeyDir),
    ?assertEqual(PubKey, LoadedPubKey),
    ?assertEqual(PrivKey, LoadedPrivKey),
    ok.

test_sign_verify_roundtrip(_Config) ->
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    {Nonce, Timestamp, MonoStart} = barrel_p2p_dist_auth:create_challenge(),
    ?assertEqual(32, byte_size(Nonce)),
    ?assert(is_integer(Timestamp)),
    ?assert(is_integer(MonoStart)),
    View = self_view(?TEST_BINDING),
    {ok, ClientSig} = barrel_p2p_dist_auth:sign_transcript(client, View),
    {ok, ServerSig} = barrel_p2p_dist_auth:sign_transcript(server, View),
    ?assertEqual(64, byte_size(ClientSig)),
    ?assert(barrel_p2p_dist_auth:verify_transcript(ClientSig, client, View, MonoStart)),
    ?assert(barrel_p2p_dist_auth:verify_transcript(ServerSig, server, View, MonoStart)),
    ok.

test_invalid_signature_rejected(_Config) ->
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    BogusSignature = crypto:strong_rand_bytes(64),
    ?assertNot(
        barrel_p2p_dist_auth:verify_transcript(
            BogusSignature, client, self_view(?TEST_BINDING), mono_now()
        )
    ),
    ok.

test_replay_attack_prevented(_Config) ->
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    View = self_view(?TEST_BINDING),
    {ok, Sig} = barrel_p2p_dist_auth:sign_transcript(client, View),
    ?assert(barrel_p2p_dist_auth:verify_transcript(Sig, client, View, mono_now())),
    %% A signature from an earlier handshake fails on fresh nonces.
    Fresh = View#{server_nonce := crypto:strong_rand_bytes(32)},
    ?assertNot(barrel_p2p_dist_auth:verify_transcript(Sig, client, Fresh, mono_now())),
    Fresh2 = View#{client_nonce := crypto:strong_rand_bytes(32)},
    ?assertNot(barrel_p2p_dist_auth:verify_transcript(Sig, client, Fresh2, mono_now())),
    ok.

test_timestamp_window_enforced(_Config) ->
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    View = self_view(?TEST_BINDING),
    {ok, Sig} = barrel_p2p_dist_auth:sign_transcript(client, View),
    %% A handshake that started 60 s ago is past the 30 s window, even with
    %% an otherwise valid signature.
    StaleMono = mono_now() - 60000,
    ?assertNot(barrel_p2p_dist_auth:verify_transcript(Sig, client, View, StaleMono)),
    ok.

%%====================================================================
%% Protocol Tests
%%====================================================================

test_hello_encode_decode(_Config) ->
    NodeName = 'test@localhost',
    PubKey = crypto:strong_rand_bytes(32),

    Encoded = barrel_p2p_dist_protocol:encode_hello(NodeName, PubKey),
    {hello, DecodedNode, DecodedPubKey} = barrel_p2p_dist_protocol:decode(Encoded),

    %% decode/1 returns the name as a validated binary; the atom is
    %% minted only after the Ed25519 signature is verified.
    ?assertEqual(atom_to_binary(NodeName, utf8), DecodedNode),
    ?assertEqual(PubKey, DecodedPubKey),
    ok.

test_challenge_encode_decode(_Config) ->
    Nonce = crypto:strong_rand_bytes(32),
    Timestamp = erlang:system_time(millisecond),

    Encoded = barrel_p2p_dist_protocol:encode_challenge(Nonce, Timestamp),
    {challenge, DecodedNonce, DecodedTimestamp} = barrel_p2p_dist_protocol:decode(Encoded),

    ?assertEqual(Nonce, DecodedNonce),
    ?assertEqual(Timestamp, DecodedTimestamp),
    ok.

test_response_encode_decode(_Config) ->
    Signature = crypto:strong_rand_bytes(64),

    Encoded = barrel_p2p_dist_protocol:encode_response(Signature),
    {response, DecodedSignature} = barrel_p2p_dist_protocol:decode(Encoded),

    ?assertEqual(Signature, DecodedSignature),
    ok.

test_ok_fail_encode_decode(_Config) ->
    %% Test OK message
    EncodedOk = barrel_p2p_dist_protocol:encode_ok(),
    ?assertEqual(ok, barrel_p2p_dist_protocol:decode(EncodedOk)),

    %% Test FAIL message
    Reason = <<"untrusted_key">>,
    EncodedFail = barrel_p2p_dist_protocol:encode_fail(Reason),
    {fail, DecodedReason} = barrel_p2p_dist_protocol:decode(EncodedFail),
    ?assertEqual(Reason, DecodedReason),
    ok.

test_invalid_message_rejected(_Config) ->
    %% Test unknown message type
    {error, {unknown_message_type, 99}} = barrel_p2p_dist_protocol:decode(<<99:8, "garbage">>),

    %% Test malformed message
    {error, malformed_message} = barrel_p2p_dist_protocol:decode(<<>>),

    %% Test invalid hello payload (current protocol version, oversized
    %% name length with too few bytes).
    {error, invalid_hello_payload} = barrel_p2p_dist_protocol:decode(
        <<1:8, 3:8, 100:16/big, "short">>
    ),

    %% Prior-version HELLOs are rejected with an explicit version error. v2
    %% has no fallback: accepting it would allow a downgrade.
    {error, {unsupported_version, 1}} = barrel_p2p_dist_protocol:decode(
        <<1:8, 1:8, 100:16/big, "short">>
    ),
    {error, {unsupported_version, 2}} = barrel_p2p_dist_protocol:decode(
        <<1:8, 2:8, 100:16/big, "short">>
    ),
    ok.

%% Decoding a HELLO must not create an atom for the peer-claimed name
%% (atom-table exhaustion defence). The name comes back as a binary; the
%% atom is minted only after the signature verifies.
test_hello_decode_does_not_mint_atom(_Config) ->
    Unique = integer_to_binary(erlang:unique_integer([positive])),
    NameBin = <<"nomint_", Unique/binary, "@h">>,
    %% Sanity: the atom does not exist yet.
    ?assertError(badarg, binary_to_existing_atom(NameBin, utf8)),

    %% Build a v3 HELLO wire by hand so encode_hello/2 (which takes an
    %% atom) does not mint it for us.
    PubKey = crypto:strong_rand_bytes(32),
    Wire = <<1:8, 3:8, (byte_size(NameBin)):16/big, NameBin/binary, PubKey/binary>>,
    ?assertEqual({hello, NameBin, PubKey}, barrel_p2p_dist_protocol:decode(Wire)),

    %% Still no atom after decode.
    ?assertError(badarg, binary_to_existing_atom(NameBin, utf8)),
    ok.

%%====================================================================
%% Trust Mode Tests
%%====================================================================

%% Peer presents a fingerprint we have never seen, strict mode -> reject.
test_strict_rejects_unknown(_Config) ->
    barrel_p2p_dist_keys:set_trust_mode(strict),
    ?assertEqual(strict, barrel_p2p_dist_keys:get_trust_mode()),

    Peer = 'unknown@host',
    UnknownKey = crypto:strong_rand_bytes(32),
    ?assertNot(barrel_p2p_dist_keys:is_trusted(Peer, UnknownKey)),
    ?assertEqual({error, not_found}, barrel_p2p_dist_keys:lookup_key(Peer)),
    ok.

%% Peer presents a fingerprint we have never seen, TOFU mode -> accept and store.
test_tofu_accepts_and_stores(_Config) ->
    barrel_p2p_dist_keys:set_trust_mode(tofu),
    ?assertEqual(tofu, barrel_p2p_dist_keys:get_trust_mode()),

    Peer = 'fresh@host',
    NewKey = crypto:strong_rand_bytes(32),

    ok = barrel_p2p_dist_keys:store_key_if_new(Peer, NewKey),
    ?assert(barrel_p2p_dist_keys:is_trusted(Peer, NewKey)),

    {ok, StoredKey} = barrel_p2p_dist_keys:lookup_key(Peer),
    ?assertEqual(NewKey, StoredKey),
    ok.

%% Peer presents a fingerprint that conflicts with the one stored for that
%% node -> reject (key change / possible attack).
test_conflicting_key_rejected(_Config) ->
    barrel_p2p_dist_keys:set_trust_mode(tofu),

    Peer = 'rotated@host',
    OriginalKey = crypto:strong_rand_bytes(32),
    ok = barrel_p2p_dist_keys:store_key_if_new(Peer, OriginalKey),
    ?assert(barrel_p2p_dist_keys:is_trusted(Peer, OriginalKey)),

    %% A different key for the same node is a conflict.
    ConflictingKey = crypto:strong_rand_bytes(32),
    ?assertNotEqual(OriginalKey, ConflictingKey),
    ?assertNot(barrel_p2p_dist_keys:is_trusted(Peer, ConflictingKey)),
    ?assertEqual(
        {error, key_mismatch},
        barrel_p2p_dist_keys:store_key_if_new(Peer, ConflictingKey)
    ),
    ok.

%% lookup_pin/1 distinguishes "no pin", "pin matches", "pin differs".
%% The TOFU re-pin fix depends on this tri-state: a mismatch must be
%% rejected even in TOFU mode.
test_lookup_pin_tri_state(_Config) ->
    Peer = 'tri@host',
    ?assertEqual(not_pinned, barrel_p2p_dist_keys:lookup_pin(Peer)),

    Pinned = crypto:strong_rand_bytes(32),
    ok = barrel_p2p_dist_keys:store_key(Peer, Pinned),
    ?assertEqual({pinned, Pinned}, barrel_p2p_dist_keys:lookup_pin(Peer)),

    Other = crypto:strong_rand_bytes(32),
    ?assertNotEqual(Pinned, Other),
    %% lookup_pin returns the *stored* key, not the presented one,
    %% so callers can compare and reject.
    ?assertMatch({pinned, Pinned}, barrel_p2p_dist_keys:lookup_pin(Peer)),
    ?assertEqual(
        {error, key_mismatch},
        barrel_p2p_dist_keys:store_key_if_new(Peer, Other)
    ),
    ok.

test_verify_response_uses_monotonic(_Config) ->
    %% The window is measured on the monotonic clock captured by
    %% create_challenge/0, and wall time is not part of the transcript, so an
    %% NTP step during the handshake cannot fail it.
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    {_Nonce, _WallTs, MonoStart} = barrel_p2p_dist_auth:create_challenge(),
    View = self_view(?TEST_BINDING),
    {ok, Sig} = barrel_p2p_dist_auth:sign_transcript(client, View),
    ?assert(barrel_p2p_dist_auth:verify_transcript(Sig, client, View, MonoStart)),
    ok.

%% A peer-supplied wall timestamp far from local wall time is
%% refused by validate_peer_ts/1 (defense in depth against replay).
test_peer_ts_outside_window_rejected(_Config) ->
    Now = erlang:system_time(millisecond),
    Window = application:get_env(barrel_p2p, auth_timestamp_window, 30000),
    %% 3x the window puts us clearly outside the 2x tolerance.
    Far = Now - 3 * Window - 5000,
    ?assertEqual(
        {error, peer_ts_skew},
        barrel_p2p_dist_auth:validate_peer_ts(Far)
    ),
    ?assertEqual(
        {error, peer_ts_skew},
        barrel_p2p_dist_auth:validate_peer_ts(Now + 3 * Window + 5000)
    ),
    ok.

%% A peer-supplied wall timestamp within tolerance is accepted.
test_peer_ts_within_window_accepted(_Config) ->
    Now = erlang:system_time(millisecond),
    ?assertEqual(ok, barrel_p2p_dist_auth:validate_peer_ts(Now)),
    ?assertEqual(ok, barrel_p2p_dist_auth:validate_peer_ts(Now - 1000)),
    ?assertEqual(ok, barrel_p2p_dist_auth:validate_peer_ts(Now + 1000)),
    ok.

test_wrong_signature_rejected(_Config) ->
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    View = self_view(?TEST_BINDING),
    {ok, Sig} = barrel_p2p_dist_auth:sign_transcript(client, View),
    %% Claim a different public key as the signer's.
    {WrongPubKey, _WrongPriv} = barrel_p2p_dist_auth:generate_keypair(),
    ?assertNot(
        barrel_p2p_dist_auth:verify_transcript(
            Sig, client, View#{peer_pk := WrongPubKey}, mono_now()
        )
    ),
    ok.

test_channel_binding_mismatch_rejected(_Config) ->
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    ServerCertHash = crypto:hash(sha256, <<"real-server-cert">>),
    MitmCertHash = crypto:hash(sha256, <<"mitm-cert">>),
    View = self_view(ServerCertHash),
    {ok, Sig} = barrel_p2p_dist_auth:sign_transcript(client, View),
    ?assert(barrel_p2p_dist_auth:verify_transcript(Sig, client, View, mono_now())),
    %% A verifier on a relayed channel (different cert) rejects.
    ?assertNot(
        barrel_p2p_dist_auth:verify_transcript(
            Sig, client, View#{binding := MitmCertHash}, mono_now()
        )
    ),
    ok.

%% Reflection (v2 weakness): a server signature must never verify as a
%% client one, even on identical names, keys, nonces and binding.
test_reflection_rejected(_Config) ->
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    View = self_view(?TEST_BINDING),
    {ok, ServerSig} = barrel_p2p_dist_auth:sign_transcript(server, View),
    {ok, ClientSig} = barrel_p2p_dist_auth:sign_transcript(client, View),
    ?assertNot(barrel_p2p_dist_auth:verify_transcript(ServerSig, client, View, mono_now())),
    ?assertNot(barrel_p2p_dist_auth:verify_transcript(ClientSig, server, View, mono_now())),
    ok.

%% Both node names are covered: a signature made while talking to one
%% peer name does not verify for another.
test_peer_name_bound(_Config) ->
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    View = self_view(?TEST_BINDING),
    {ok, Sig} = barrel_p2p_dist_auth:sign_transcript(client, View),
    ?assertNot(
        barrel_p2p_dist_auth:verify_transcript(
            Sig, client, View#{peer_name := <<"other@host">>}, mono_now()
        )
    ),
    ok.

%% The transcript layout: label, role, length-prefixed names, keys, nonces,
%% binding. Pinned so a change to the signed bytes is a deliberate protocol
%% bump.
test_transcript_layout(_Config) ->
    Pk = <<1:256>>,
    N = <<2:256>>,
    B = <<3:256>>,
    Msg = barrel_p2p_dist_auth:transcript_message(client, <<"a@h">>, <<"bb@h">>, Pk, Pk, N, N, B),
    ?assertEqual(
        <<"barrel_p2p-dist-auth-v3", 1, 3:16, "a@h", 4:16, "bb@h", Pk/binary, Pk/binary, N/binary,
            N/binary, B/binary>>,
        Msg
    ),
    ?assertNotEqual(
        Msg,
        barrel_p2p_dist_auth:transcript_message(server, <<"a@h">>, <<"bb@h">>, Pk, Pk, N, N, B)
    ),
    ok.

test_key_persistence_to_disk(Config) ->
    KeyDir = proplists:get_value(key_dir, Config),
    barrel_p2p_dist_keys:set_trust_mode(tofu),

    Peer = 'persist@host',
    PubKey = crypto:strong_rand_bytes(32),
    ok = barrel_p2p_dist_keys:store_key_if_new(Peer, PubKey),

    %% File is named <Node>.pub under <KeyDir>/trusted/.
    TrustedDir = filename:join(KeyDir, "trusted"),
    KeyFile = filename:join(TrustedDir, atom_to_list(Peer) ++ ".pub"),
    ?assert(filelib:is_file(KeyFile)),

    %% File contents are the raw 32-byte public key.
    {ok, FileContents} = file:read_file(KeyFile),
    ?assertEqual(PubKey, FileContents),

    ok = barrel_p2p_dist_keys:delete_key(Peer),
    ?assertNot(filelib:is_file(KeyFile)),
    ok.

%%====================================================================
%% Whitelist Tests
%%====================================================================

test_whitelist_exact_match(_Config) ->
    %% Set up whitelist with exact match
    application:set_env(barrel_p2p, cookie_only_nodes, ['cnode@localhost']),

    %% Exact match should be allowed
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed('cnode@localhost')),

    %% Different node should not match
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed('other@localhost')),
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed('cnode@otherhost')),
    ok.

test_whitelist_wildcard_host(_Config) ->
    %% Set up whitelist with wildcard host
    application:set_env(barrel_p2p, cookie_only_nodes, ['monitor@*']),

    %% Any host should match
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed('monitor@localhost')),
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed('monitor@server1')),
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed('monitor@192.168.1.1')),

    %% Different name should not match
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed('other@localhost')),
    ok.

test_whitelist_wildcard_name(_Config) ->
    %% Set up whitelist with wildcard name
    application:set_env(barrel_p2p, cookie_only_nodes, ['*@trusted.local']),

    %% Any name should match on trusted.local
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed('cnode@trusted.local')),
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed('monitor@trusted.local')),
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed('anything@trusted.local')),

    %% Different host should not match
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed('cnode@untrusted.local')),
    ok.

test_whitelist_no_match(_Config) ->
    %% Set up whitelist
    application:set_env(barrel_p2p, cookie_only_nodes, [
        'cnode@localhost',
        'monitor@*',
        '*@trusted.local'
    ]),

    %% Nodes that don't match any pattern
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed('random@random')),
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed('other@server')),
    ok.

test_whitelist_empty(_Config) ->
    %% Empty whitelist
    application:set_env(barrel_p2p, cookie_only_nodes, []),

    %% Nothing should match
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed('cnode@localhost')),
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed('anything@anywhere')),
    ok.

test_whitelist_invalid_pattern(_Config) ->
    %% Set up whitelist with valid and invalid patterns
    application:set_env(barrel_p2p, cookie_only_nodes, [
        'valid@localhost',
        %% Missing @
        invalid_no_at,
        'also@valid'
    ]),

    %% Valid patterns should work
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed('valid@localhost')),
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed('also@valid')),

    %% Invalid pattern should not crash, just not match
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed('invalid_no_at@somewhere')),
    ok.

%% The handshake checks cookie-only before minting an atom, so the
%% whitelist must match on a name binary too, with the same result as
%% the atom form and without creating an atom.
test_whitelist_matches_binary_name(_Config) ->
    application:set_env(barrel_p2p, cookie_only_nodes, ['monitor@*']),
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed(<<"monitor@localhost">>)),
    ?assertNot(barrel_p2p_dist_auth:is_cookie_only_allowed(<<"other@localhost">>)),
    %% A never-seen matching name is allowed without minting an atom.
    Unique = integer_to_binary(erlang:unique_integer([positive])),
    NameBin = <<"monitor@h", Unique/binary>>,
    ?assert(barrel_p2p_dist_auth:is_cookie_only_allowed(NameBin)),
    ?assertError(badarg, binary_to_existing_atom(NameBin, utf8)),
    ok.

%%====================================================================
%% v3 transcript helpers
%%====================================================================

%% Single-node view: the same node plays both sides, so its own name and
%% key are also the peer's.
self_view(Binding) ->
    {ok, PubKey} = barrel_p2p_dist_auth:get_public_key(),
    #{
        peer_name => atom_to_binary(node(), utf8),
        peer_pk => PubKey,
        client_nonce => crypto:strong_rand_bytes(32),
        server_nonce => crypto:strong_rand_bytes(32),
        binding => Binding
    }.

mono_now() ->
    erlang:monotonic_time(millisecond).

%%====================================================================
%% Client identity check (v2 weakness: the authenticated name was never
%% compared with the dialed node)
%%====================================================================

%% A server proving a name other than the one dialed is refused right
%% after its HELLO, before the client sends a challenge or a signature,
%% even when the key is trusted for the name it claims.
test_client_refuses_other_name(_Config) ->
    ok = barrel_p2p_dist_auth:ensure_keypair(),
    {OtherPk, _} = barrel_p2p_dist_auth:generate_keypair(),
    ok = barrel_p2p_dist_keys:store_key_if_new('other@host', OtherPk),
    Sent = with_fake_quic(fun(Conn) ->
        ServerHello = barrel_p2p_dist_protocol:encode_hello('other@host', OtherPk),
        self() ! {quic, Conn, {stream_data, 3, frame(ServerHello), false}},
        ?assertEqual(
            {error, {auth_identity_mismatch, <<"other@host">>, 'target@host'}},
            barrel_p2p_dist_auth_stream:authenticate_outgoing(Conn, 'target@host', 1000)
        )
    end),
    %% Only our HELLO went out: no challenge, no signature.
    ?assertMatch([{hello, _, _}], [barrel_p2p_dist_protocol:decode(M) || M <- Sent]),
    ok = barrel_p2p_dist_keys:delete_key('other@host'),
    ok.

%% Without a dial target the client cannot check who it reached, so it
%% fails closed.
test_client_requires_dial_target(_Config) ->
    with_fake_quic(fun(Conn) ->
        ?assertEqual(
            {error, no_dial_target},
            barrel_p2p_dist_auth_stream:authenticate_outgoing(Conn, undefined, 1000)
        )
    end),
    ok.

%% Run Fun(Conn) with the quic stream API stubbed; return the auth messages
%% the client sent, unframed.
with_fake_quic(Fun) ->
    Conn = self(),
    Self = self(),
    ok = meck:new(quic, [passthrough, no_link]),
    try
        meck:expect(quic, peercert, fun(_) -> {ok, <<"server-cert-der">>} end),
        meck:expect(quic, open_unidirectional_stream, fun(_) -> {ok, 2} end),
        meck:expect(quic, send_data, fun(_, _, Data, _Fin) ->
            Self ! {sent, Data},
            ok
        end),
        Fun(Conn),
        collect_sent([])
    after
        meck:unload(quic)
    end.

collect_sent(Acc) ->
    receive
        {sent, <<>>} -> collect_sent(Acc);
        {sent, <<Len:16/big, Msg:Len/binary>>} -> collect_sent([Msg | Acc])
    after 0 -> lists:reverse(Acc)
    end.

frame(Msg) ->
    <<(byte_size(Msg)):16/big, Msg/binary>>.
