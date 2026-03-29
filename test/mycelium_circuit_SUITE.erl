-module(mycelium_circuit_SUITE).

%% Test suite for circuit-based routing
%% Tests protocol encoding, relay handling, and circuit lifecycle

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Protocol encoding tests
-export([
    test_encode_decode_create/1,
    test_encode_decode_created/1,
    test_encode_decode_extend/1,
    test_encode_decode_extended/1,
    test_encode_decode_data/1,
    test_encode_decode_destroy/1,
    test_decode_invalid_message/1,
    test_circuit_id_encoding/1
]).

%% Relay tests
-export([
    test_relay_create/1,
    test_relay_extend/1,
    test_relay_lookup/1,
    test_relay_remove/1,
    test_relay_count_limit/1
]).

%% Circuit state machine tests
-export([
    test_circuit_create_no_hops/1,
    test_circuit_send_before_ready/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, protocol_tests},
     {group, relay_tests},
     {group, circuit_tests}].

groups() ->
    [
        {protocol_tests, [sequence], [
            test_encode_decode_create,
            test_encode_decode_created,
            test_encode_decode_extend,
            test_encode_decode_extended,
            test_encode_decode_data,
            test_encode_decode_destroy,
            test_decode_invalid_message,
            test_circuit_id_encoding
        ]},
        {relay_tests, [sequence], [
            test_relay_create,
            test_relay_extend,
            test_relay_lookup,
            test_relay_remove,
            test_relay_count_limit
        ]},
        {circuit_tests, [sequence], [
            test_circuit_create_no_hops,
            test_circuit_send_before_ready
        ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(relay_tests, Config) ->
    %% Start the relay process for relay tests
    application:ensure_all_started(mycelium),
    Config;
init_per_group(_Group, Config) ->
    Config.

end_per_group(relay_tests, _Config) ->
    application:stop(mycelium),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Protocol Encoding Tests
%%====================================================================

test_encode_decode_create(_Config) ->
    CircuitId = make_circuit_id(),
    EphPubKey = crypto:strong_rand_bytes(32),

    Encoded = mycelium_circuit_protocol:encode_create(CircuitId, EphPubKey),

    {ok, {create, DecodedId, DecodedKey}} = mycelium_circuit_protocol:decode(Encoded),

    ?assertEqual(CircuitId#circuit_id.id, DecodedId#circuit_id.id),
    ?assertEqual(CircuitId#circuit_id.initiator, DecodedId#circuit_id.initiator),
    ?assertEqual(EphPubKey, DecodedKey),
    ok.

test_encode_decode_created(_Config) ->
    CircuitId = make_circuit_id(),
    EphPubKey = crypto:strong_rand_bytes(32),

    Encoded = mycelium_circuit_protocol:encode_created(CircuitId, EphPubKey),

    {ok, {created, DecodedId, DecodedKey}} = mycelium_circuit_protocol:decode(Encoded),

    ?assertEqual(CircuitId#circuit_id.id, DecodedId#circuit_id.id),
    ?assertEqual(EphPubKey, DecodedKey),
    ok.

test_encode_decode_extend(_Config) ->
    CircuitId = make_circuit_id(),
    TargetNode = 'target@localhost',
    EphPubKey = crypto:strong_rand_bytes(32),

    Encoded = mycelium_circuit_protocol:encode_extend(CircuitId, TargetNode, EphPubKey),

    {ok, {extend, DecodedId, {DecodedTarget, DecodedKey}}} = mycelium_circuit_protocol:decode(Encoded),

    ?assertEqual(CircuitId#circuit_id.id, DecodedId#circuit_id.id),
    ?assertEqual(TargetNode, DecodedTarget),
    ?assertEqual(EphPubKey, DecodedKey),
    ok.

test_encode_decode_extended(_Config) ->
    CircuitId = make_circuit_id(),
    EphPubKey = crypto:strong_rand_bytes(32),

    Encoded = mycelium_circuit_protocol:encode_extended(CircuitId, EphPubKey),

    {ok, {extended, DecodedId, DecodedKey}} = mycelium_circuit_protocol:decode(Encoded),

    ?assertEqual(CircuitId#circuit_id.id, DecodedId#circuit_id.id),
    ?assertEqual(EphPubKey, DecodedKey),
    ok.

test_encode_decode_data(_Config) ->
    CircuitId = make_circuit_id(),
    Payload = <<"encrypted data payload">>,

    Encoded = mycelium_circuit_protocol:encode_data(CircuitId, Payload),

    {ok, {data, DecodedId, DecodedPayload}} = mycelium_circuit_protocol:decode(Encoded),

    ?assertEqual(CircuitId#circuit_id.id, DecodedId#circuit_id.id),
    ?assertEqual(Payload, DecodedPayload),
    ok.

test_encode_decode_destroy(_Config) ->
    CircuitId = make_circuit_id(),

    %% Test different reason codes
    lists:foreach(fun(Reason) ->
        Encoded = mycelium_circuit_protocol:encode_destroy(CircuitId, Reason),
        {ok, {destroy, DecodedId, DecodedReason}} = mycelium_circuit_protocol:decode(Encoded),
        ?assertEqual(CircuitId#circuit_id.id, DecodedId#circuit_id.id),
        ?assertEqual(Reason, DecodedReason)
    end, [0, 1, 2]),
    ok.

test_decode_invalid_message(_Config) ->
    %% Empty message
    ?assertEqual({error, invalid_message}, mycelium_circuit_protocol:decode(<<>>)),

    %% Too short
    ?assertEqual({error, invalid_message}, mycelium_circuit_protocol:decode(<<1>>)),

    %% Invalid length
    ?assertEqual({error, invalid_message}, mycelium_circuit_protocol:decode(<<1, 0, 100>>)),

    ok.

test_circuit_id_encoding(_Config) ->
    %% Test with different node names
    Nodes = ['node1@localhost', 'node2@example.com', 'very_long_node_name@some.domain.com'],

    lists:foreach(fun(Node) ->
        Id = crypto:strong_rand_bytes(16),
        CircuitId = #circuit_id{id = Id, initiator = Node},
        EphPubKey = crypto:strong_rand_bytes(32),

        Encoded = mycelium_circuit_protocol:encode_create(CircuitId, EphPubKey),
        {ok, {create, DecodedId, _}} = mycelium_circuit_protocol:decode(Encoded),

        ?assertEqual(Id, DecodedId#circuit_id.id),
        ?assertEqual(Node, DecodedId#circuit_id.initiator)
    end, Nodes),
    ok.

%%====================================================================
%% Relay Tests
%%====================================================================

test_relay_create(_Config) ->
    CircuitId = make_circuit_id(),
    EphPubKey = crypto:strong_rand_bytes(32),
    From = 'sender@localhost',

    Result = mycelium_circuit_relay:handle_create(From, CircuitId, EphPubKey),
    ?assertEqual(ok, Result),

    %% Verify circuit is stored
    {ok, Hop} = mycelium_circuit_relay:lookup(CircuitId),
    ?assertEqual(CircuitId, Hop#circuit_hop.circuit_id),
    ?assertEqual(From, Hop#circuit_hop.prev_node),
    ?assertEqual(undefined, Hop#circuit_hop.next_node),

    %% Cleanup
    mycelium_circuit_relay:remove(CircuitId),
    ok.

test_relay_extend(_Config) ->
    CircuitId = make_circuit_id(),
    EphPubKey = crypto:strong_rand_bytes(32),
    From = 'sender@localhost',
    Target = 'target@localhost',

    %% First create the circuit
    ok = mycelium_circuit_relay:handle_create(From, CircuitId, EphPubKey),

    %% Then extend it
    Result = mycelium_circuit_relay:handle_extend(From, CircuitId, Target, EphPubKey),
    ?assertEqual(ok, Result),

    %% Verify next_node is set
    {ok, Hop} = mycelium_circuit_relay:lookup(CircuitId),
    ?assertEqual(Target, Hop#circuit_hop.next_node),

    %% Cleanup
    mycelium_circuit_relay:remove(CircuitId),
    ok.

test_relay_lookup(_Config) ->
    CircuitId = make_circuit_id(),
    EphPubKey = crypto:strong_rand_bytes(32),
    From = 'sender@localhost',

    %% Lookup non-existent circuit
    ?assertEqual({error, not_found}, mycelium_circuit_relay:lookup(CircuitId)),

    %% Create and lookup
    ok = mycelium_circuit_relay:handle_create(From, CircuitId, EphPubKey),
    {ok, Hop} = mycelium_circuit_relay:lookup(CircuitId),
    ?assert(is_record(Hop, circuit_hop)),

    %% Cleanup
    mycelium_circuit_relay:remove(CircuitId),
    ok.

test_relay_remove(_Config) ->
    CircuitId = make_circuit_id(),
    EphPubKey = crypto:strong_rand_bytes(32),
    From = 'sender@localhost',

    ok = mycelium_circuit_relay:handle_create(From, CircuitId, EphPubKey),
    {ok, _} = mycelium_circuit_relay:lookup(CircuitId),

    %% Remove
    ok = mycelium_circuit_relay:remove(CircuitId),

    %% Verify removed
    ?assertEqual({error, not_found}, mycelium_circuit_relay:lookup(CircuitId)),
    ok.

test_relay_count_limit(_Config) ->
    %% Get current count
    InitialCount = mycelium_circuit_relay:count(),

    %% Create several circuits
    Circuits = [begin
        CId = make_circuit_id(),
        ok = mycelium_circuit_relay:handle_create('sender@localhost', CId, crypto:strong_rand_bytes(32)),
        CId
    end || _ <- lists:seq(1, 10)],

    %% Verify count increased
    ?assertEqual(InitialCount + 10, mycelium_circuit_relay:count()),

    %% Cleanup
    lists:foreach(fun(CId) -> mycelium_circuit_relay:remove(CId) end, Circuits),
    ?assertEqual(InitialCount, mycelium_circuit_relay:count()),
    ok.

%%====================================================================
%% Circuit State Machine Tests
%%====================================================================

test_circuit_create_no_hops(_Config) ->
    %% Test that creating a circuit to self fails
    Result = mycelium_circuit:create(node(), #{}),
    ?assertEqual({error, cannot_circuit_to_self}, Result),
    ok.

test_circuit_send_before_ready(_Config) ->
    %% Create a circuit ID manually to test send without ready circuit
    CircuitId = #circuit_id{id = crypto:strong_rand_bytes(16), initiator = node()},

    %% Try to send - should fail because circuit doesn't exist
    Result = mycelium_circuit:send(CircuitId, <<"test">>),
    ?assertEqual({error, not_found}, Result),
    ok.

%%====================================================================
%% Helper Functions
%%====================================================================

make_circuit_id() ->
    #circuit_id{
        id = crypto:strong_rand_bytes(16),
        initiator = node()
    }.
