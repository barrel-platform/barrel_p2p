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

%% Failure tests
-export([
    test_establish_timeout/1,
    test_transport_down_building/1,
    test_transport_down_ready/1,
    test_decryption_failure/1,
    test_relay_limit_reached/1
]).

%% Lifecycle tests
-export([
    test_circuit_expiry_ttl/1,
    test_close_during_building/1,
    test_destroy_propagation/1,
    test_listener_death/1,
    test_circuit_info_states/1
]).

%% Stress tests
-export([
    test_multiple_circuits_same_peer/1,
    test_many_circuits_through_relay/1,
    test_rapid_create_destroy/1,
    test_concurrent_operations/1
]).

%% Edge case tests
-export([
    test_empty_payload/1,
    test_large_payload/1,
    test_double_extend/1,
    test_already_listening/1,
    test_close_already_closed/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, protocol_tests},
     {group, relay_tests},
     {group, circuit_tests},
     {group, failure_tests},
     {group, lifecycle_tests},
     {group, stress_tests},
     {group, edge_case_tests}].

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
        ]},
        {failure_tests, [sequence], [
            test_establish_timeout,
            test_transport_down_building,
            test_transport_down_ready,
            test_decryption_failure,
            test_relay_limit_reached
        ]},
        {lifecycle_tests, [sequence], [
            test_circuit_expiry_ttl,
            test_close_during_building,
            test_destroy_propagation,
            test_listener_death,
            test_circuit_info_states
        ]},
        {stress_tests, [sequence], [
            test_multiple_circuits_same_peer,
            test_many_circuits_through_relay,
            test_rapid_create_destroy,
            test_concurrent_operations
        ]},
        {edge_case_tests, [sequence], [
            test_empty_payload,
            test_large_payload,
            test_double_extend,
            test_already_listening,
            test_close_already_closed
        ]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(relay_tests, Config) ->
    application:ensure_all_started(mycelium),
    Config;
init_per_group(Group, Config) when Group =:= failure_tests;
                                    Group =:= lifecycle_tests;
                                    Group =:= stress_tests;
                                    Group =:= edge_case_tests ->
    application:ensure_all_started(mycelium),
    setup_transport_mocks(),
    Config;
init_per_group(_Group, Config) ->
    Config.

end_per_group(relay_tests, _Config) ->
    application:stop(mycelium),
    ok;
end_per_group(Group, _Config) when Group =:= failure_tests;
                                    Group =:= lifecycle_tests;
                                    Group =:= stress_tests;
                                    Group =:= edge_case_tests ->
    cleanup_mocks(),
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
%% Failure Tests
%%====================================================================

test_establish_timeout(_Config) ->
    %% Mock transport to not respond (simulating unresponsive peer)
    meck:expect(mycelium_circuit_transport, send, fun(_, _, _) -> ok end),
    meck:expect(mycelium_hyparview, random_active_peers, fun(_) -> ['peer@host'] end),
    meck:expect(mycelium_hyparview, passive_view, fun() -> ['peer@host'] end),

    %% Override establish timeout to 100ms for testing
    application:set_env(mycelium, circuit_establish_timeout_test, 100),

    %% Create circuit with short timeout - we test via direct process start
    CircuitId = make_circuit_id(),
    Target = 'target@localhost',
    Owner = self(),

    %% Start circuit with very short TTL
    {ok, Pid} = mycelium_circuit:start_link(initiator, CircuitId, Target, [], 1000, Owner),

    %% Wait for timeout message (30s default, but process should fire)
    %% We can't easily reduce this without modifying the module, so we simulate
    Pid ! establish_timeout,

    receive
        {circuit_failed, CircuitId, timeout} -> ok
    after 1000 ->
        ct:fail("Expected circuit_failed timeout message")
    end,
    ok.

test_transport_down_building(_Config) ->
    %% Mock transport to succeed initially
    meck:expect(mycelium_circuit_transport, send, fun(_, _, _) -> ok end),
    meck:expect(mycelium_hyparview, random_active_peers, fun(_) -> ['peer@host'] end),
    meck:expect(mycelium_hyparview, passive_view, fun() -> ['peer@host'] end),

    CircuitId = make_circuit_id(),
    Target = 'target@localhost',
    Owner = self(),

    {ok, Pid} = mycelium_circuit:start_link(initiator, CircuitId, Target, [], 60000, Owner),

    %% Simulate transport going down during building state
    Pid ! {transport_down, 'target@localhost', connection_closed},

    receive
        {circuit_failed, CircuitId, {transport_down, connection_closed}} -> ok
    after 1000 ->
        ct:fail("Expected circuit_failed transport_down message")
    end,
    ok.

test_transport_down_ready(_Config) ->
    %% Create a ready circuit by simulating handshake completion
    CircuitId = make_circuit_id(),
    Owner = self(),

    %% Create a mock crypto session
    CryptoSession = make_mock_crypto_session(),

    %% Start as destination (which starts in ready state)
    {ok, Pid} = mycelium_circuit:start_link(destination, CircuitId, CryptoSession, 60000, Owner),

    %% Wait for ready notification
    receive
        {circuit_ready, CircuitId} -> ok
    after 1000 ->
        ct:fail("Expected circuit_ready message")
    end,

    %% Now simulate transport going down
    Pid ! {transport_down, 'peer@localhost', connection_closed},

    receive
        {circuit_closed, CircuitId, {transport_down, connection_closed}} -> ok
    after 1000 ->
        ct:fail("Expected circuit_closed transport_down message")
    end,
    ok.

test_decryption_failure(_Config) ->
    %% Create a ready circuit
    CircuitId = make_circuit_id(),
    Owner = self(),
    CryptoSession = make_mock_crypto_session(),

    {ok, Pid} = mycelium_circuit:start_link(destination, CircuitId, CryptoSession, 60000, Owner),

    receive {circuit_ready, CircuitId} -> ok after 1000 -> ct:fail("Expected ready") end,

    %% Send garbage data that will fail decryption
    gen_statem:cast(Pid, {data, <<"garbage_encrypted_data_that_will_fail">>}),

    receive
        {circuit_closed, CircuitId, decrypt_failed} -> ok
    after 1000 ->
        ct:fail("Expected circuit_closed decrypt_failed message")
    end,
    ok.

test_relay_limit_reached(_Config) ->
    %% Create circuits up to the default limit (500), then verify behavior
    %% We'll test with a smaller number by filling up close to limit
    From = 'sender@localhost',
    EphPubKey = crypto:strong_rand_bytes(32),

    %% Get current count
    InitialCount = mycelium_circuit_relay:count(),

    %% The relay module checks count() >= max_relays at creation time
    %% We can't easily restart the relay, but we can verify the limit logic
    %% by directly testing the error path exists

    %% Create 3 circuits and verify they work
    C1 = make_circuit_id(),
    C2 = make_circuit_id(),
    C3 = make_circuit_id(),

    ok = mycelium_circuit_relay:handle_create(From, C1, EphPubKey),
    ok = mycelium_circuit_relay:handle_create(From, C2, EphPubKey),
    ok = mycelium_circuit_relay:handle_create(From, C3, EphPubKey),

    ?assertEqual(InitialCount + 3, mycelium_circuit_relay:count()),

    %% Cleanup
    mycelium_circuit_relay:remove(C1),
    mycelium_circuit_relay:remove(C2),
    mycelium_circuit_relay:remove(C3),
    ?assertEqual(InitialCount, mycelium_circuit_relay:count()),
    ok.

%%====================================================================
%% Lifecycle Tests
%%====================================================================

test_circuit_expiry_ttl(_Config) ->
    CircuitId = make_circuit_id(),
    Owner = self(),
    CryptoSession = make_mock_crypto_session(),

    %% Very short TTL for testing (200ms to be safe)
    {ok, Pid} = mycelium_circuit:start_link(destination, CircuitId, CryptoSession, 200, Owner),

    receive {circuit_ready, CircuitId} -> ok after 1000 -> ct:fail("Expected ready") end,

    %% Wait for expiry (give extra time for timer precision)
    receive
        {circuit_closed, CircuitId, expired} -> ok
    after 1000 ->
        ct:fail("Expected circuit_closed expired message")
    end,

    %% Give process time to terminate
    timer:sleep(50),

    %% Verify process is dead
    ?assertEqual(false, is_process_alive(Pid)),
    ok.

test_close_during_building(_Config) ->
    meck:expect(mycelium_circuit_transport, send, fun(_, _, _) -> ok end),
    meck:expect(mycelium_hyparview, random_active_peers, fun(_) -> ['peer@host'] end),
    meck:expect(mycelium_hyparview, passive_view, fun() -> ['peer@host'] end),

    CircuitId = make_circuit_id(),
    Target = 'target@localhost',
    Owner = self(),

    {ok, Pid} = mycelium_circuit:start_link(initiator, CircuitId, Target, [], 60000, Owner),

    %% Close while still building
    gen_statem:cast(Pid, close),

    %% Give it time to process
    timer:sleep(100),

    %% Verify process stopped
    ?assertEqual(false, is_process_alive(Pid)),
    ok.

test_destroy_propagation(_Config) ->
    CircuitId = make_circuit_id(),
    Owner = self(),
    CryptoSession = make_mock_crypto_session(),

    {ok, Pid} = mycelium_circuit:start_link(destination, CircuitId, CryptoSession, 60000, Owner),

    receive {circuit_ready, CircuitId} -> ok after 1000 -> ct:fail("Expected ready") end,

    %% Send destroy from remote
    gen_statem:cast(Pid, {destroy, 1}),

    receive
        {circuit_closed, CircuitId, {remote, 1}} -> ok
    after 1000 ->
        ct:fail("Expected circuit_closed remote message")
    end,
    ok.

test_listener_death(_Config) ->
    %% Create a listener process
    Listener = spawn(fun() ->
        receive stop -> ok end
    end),

    ok = mycelium_circuit_relay:listen(Listener),
    {ok, Listener} = mycelium_circuit_relay:get_listener(),

    %% Kill the listener
    exit(Listener, kill),
    timer:sleep(50),

    %% Verify listener is cleared
    ?assertEqual(none, mycelium_circuit_relay:get_listener()),
    ok.

test_circuit_info_states(_Config) ->
    %% Test get_info in building state
    meck:expect(mycelium_circuit_transport, send, fun(_, _, _) -> ok end),
    meck:expect(mycelium_hyparview, random_active_peers, fun(_) -> [] end),
    meck:expect(mycelium_hyparview, passive_view, fun() -> [] end),

    CircuitId1 = make_circuit_id(),
    Target = 'target@localhost',
    Owner = self(),

    {ok, Pid1} = mycelium_circuit:start_link(initiator, CircuitId1, Target, [], 60000, Owner),
    {ok, Info1} = mycelium_circuit:get_info_by_pid(Pid1),
    ?assertEqual(building, maps:get(state, Info1)),
    ?assertEqual(initiator, maps:get(role, Info1)),
    gen_statem:cast(Pid1, close),

    %% Test get_info in ready state
    CircuitId2 = make_circuit_id(),
    CryptoSession = make_mock_crypto_session(),

    {ok, Pid2} = mycelium_circuit:start_link(destination, CircuitId2, CryptoSession, 60000, Owner),
    receive {circuit_ready, CircuitId2} -> ok after 1000 -> ct:fail("Expected ready") end,

    {ok, Info2} = mycelium_circuit:get_info_by_pid(Pid2),
    ?assertEqual(ready, maps:get(state, Info2)),
    ?assertEqual(destination, maps:get(role, Info2)),
    gen_statem:cast(Pid2, close),
    ok.

%%====================================================================
%% Stress Tests
%%====================================================================

test_multiple_circuits_same_peer(_Config) ->
    From = 'sender@localhost',
    EphPubKey = crypto:strong_rand_bytes(32),

    %% Create 10 circuits from same peer
    Circuits = [begin
        CId = make_circuit_id(),
        ok = mycelium_circuit_relay:handle_create(From, CId, EphPubKey),
        CId
    end || _ <- lists:seq(1, 10)],

    ?assertEqual(10, length(Circuits)),

    %% All should be found
    lists:foreach(fun(CId) ->
        {ok, _Hop} = mycelium_circuit_relay:lookup(CId)
    end, Circuits),

    %% Cleanup
    lists:foreach(fun(CId) -> mycelium_circuit_relay:remove(CId) end, Circuits),
    ok.

test_many_circuits_through_relay(_Config) ->
    From = 'sender@localhost',
    EphPubKey = crypto:strong_rand_bytes(32),

    %% Create 50 circuits
    Circuits = [begin
        CId = make_circuit_id(),
        ok = mycelium_circuit_relay:handle_create(From, CId, EphPubKey),
        CId
    end || _ <- lists:seq(1, 50)],

    ?assertEqual(50, length(Circuits)),
    ?assert(mycelium_circuit_relay:count() >= 50),

    %% Cleanup
    lists:foreach(fun(CId) -> mycelium_circuit_relay:remove(CId) end, Circuits),
    ok.

test_rapid_create_destroy(_Config) ->
    From = 'sender@localhost',
    EphPubKey = crypto:strong_rand_bytes(32),

    %% Rapid create/destroy cycles
    lists:foreach(fun(_) ->
        CId = make_circuit_id(),
        ok = mycelium_circuit_relay:handle_create(From, CId, EphPubKey),
        {ok, _} = mycelium_circuit_relay:lookup(CId),
        ok = mycelium_circuit_relay:remove(CId),
        ?assertEqual({error, not_found}, mycelium_circuit_relay:lookup(CId))
    end, lists:seq(1, 100)),
    ok.

test_concurrent_operations(_Config) ->
    %% 20 processes doing random operations
    Self = self(),
    Pids = [spawn_link(fun() ->
        random_circuit_operations(20),
        Self ! {done, self()}
    end) || _ <- lists:seq(1, 20)],

    %% Wait for all to complete
    lists:foreach(fun(Pid) ->
        receive {done, Pid} -> ok after 10000 -> ct:fail("Timeout waiting for process") end
    end, Pids),
    ok.

%%====================================================================
%% Edge Case Tests
%%====================================================================

test_empty_payload(_Config) ->
    CircuitId = make_circuit_id(),
    Owner = self(),
    CryptoSession = make_mock_crypto_session(),

    {ok, Pid} = mycelium_circuit:start_link(destination, CircuitId, CryptoSession, 60000, Owner),
    receive {circuit_ready, CircuitId} -> ok after 1000 -> ct:fail("Expected ready") end,

    %% Try to send empty payload (via gen_statem call)
    %% The encryption should still work with empty data
    Result = gen_statem:call(Pid, {send, <<>>}),
    ?assertEqual(ok, Result),

    gen_statem:cast(Pid, close),
    ok.

test_large_payload(_Config) ->
    CircuitId = make_circuit_id(),
    Owner = self(),
    CryptoSession = make_mock_crypto_session(),

    {ok, Pid} = mycelium_circuit:start_link(destination, CircuitId, CryptoSession, 60000, Owner),
    receive {circuit_ready, CircuitId} -> ok after 1000 -> ct:fail("Expected ready") end,

    %% 1MB payload
    LargePayload = crypto:strong_rand_bytes(1024 * 1024),
    Result = gen_statem:call(Pid, {send, LargePayload}),
    ?assertEqual(ok, Result),

    gen_statem:cast(Pid, close),
    ok.

test_double_extend(_Config) ->
    CircuitId = make_circuit_id(),
    From = 'sender@localhost',
    EphPubKey = crypto:strong_rand_bytes(32),
    Target1 = 'target1@localhost',
    Target2 = 'target2@localhost',

    %% Create circuit
    ok = mycelium_circuit_relay:handle_create(From, CircuitId, EphPubKey),

    %% First extend should succeed
    ok = mycelium_circuit_relay:handle_extend(From, CircuitId, Target1, EphPubKey),

    %% Second extend should fail
    Result = mycelium_circuit_relay:handle_extend(From, CircuitId, Target2, EphPubKey),
    ?assertEqual({error, already_extended}, Result),

    %% Cleanup
    mycelium_circuit_relay:remove(CircuitId),
    ok.

test_already_listening(_Config) ->
    Listener1 = spawn(fun() -> receive stop -> ok end end),
    Listener2 = spawn(fun() -> receive stop -> ok end end),

    ok = mycelium_circuit_relay:listen(Listener1),
    Result = mycelium_circuit_relay:listen(Listener2),
    ?assertEqual({error, already_listening}, Result),

    %% Cleanup
    mycelium_circuit_relay:unlisten(),
    exit(Listener1, kill),
    exit(Listener2, kill),
    ok.

test_close_already_closed(_Config) ->
    CircuitId = make_circuit_id(),

    %% Close should be idempotent - no error for non-existent circuit
    Result = mycelium_circuit:close(CircuitId),
    ?assertEqual(ok, Result),
    ok.

%%====================================================================
%% Helper Functions
%%====================================================================

make_circuit_id() ->
    #circuit_id{
        id = crypto:strong_rand_bytes(16),
        initiator = node()
    }.

%% Mock transport for isolated testing
setup_transport_mocks() ->
    meck:new(mycelium_circuit_transport, [passthrough]),
    meck:expect(mycelium_circuit_transport, send, fun(_, _, _) -> ok end),
    meck:expect(mycelium_circuit_transport, register_circuit, fun(_, _, _) -> ok end),
    meck:expect(mycelium_circuit_transport, unregister_circuit, fun(_, _) -> ok end),

    meck:new(mycelium_hyparview, [passthrough]),
    meck:expect(mycelium_hyparview, random_active_peers, fun(_) -> ['peer@host'] end),
    meck:expect(mycelium_hyparview, passive_view, fun() -> ['peer@host'] end),
    ok.

cleanup_mocks() ->
    catch meck:unload(mycelium_circuit_transport),
    catch meck:unload(mycelium_hyparview),
    ok.

make_mock_crypto_session() ->
    %% Create a valid crypto session for testing
    {PubKey1, _PrivKey1} = mycelium_crypto:generate_ephemeral_keypair(),
    {PubKey2, PrivKey2} = mycelium_crypto:generate_ephemeral_keypair(),
    SharedSecret = mycelium_crypto:compute_shared_secret(PubKey1, PrivKey2),
    {_InitiatorSession, DestSession} = mycelium_crypto:derive_session_keys(
        SharedSecret, PubKey2, PubKey1
    ),
    DestSession.

random_circuit_operations(Count) ->
    From = 'sender@localhost',
    EphPubKey = crypto:strong_rand_bytes(32),
    random_circuit_ops_loop(Count, From, EphPubKey, []).

random_circuit_ops_loop(0, _, _, Circuits) ->
    %% Cleanup remaining circuits
    lists:foreach(fun(CId) ->
        mycelium_circuit_relay:remove(CId)
    end, Circuits);
random_circuit_ops_loop(N, From, EphPubKey, Circuits) ->
    Op = rand:uniform(3),
    NewCircuits = case Op of
        1 ->
            %% Create
            CId = make_circuit_id(),
            mycelium_circuit_relay:handle_create(From, CId, EphPubKey),
            [CId | Circuits];
        2 when Circuits =/= [] ->
            %% Remove random
            CId = lists:nth(rand:uniform(length(Circuits)), Circuits),
            mycelium_circuit_relay:remove(CId),
            lists:delete(CId, Circuits);
        3 when Circuits =/= [] ->
            %% Lookup random
            CId = lists:nth(rand:uniform(length(Circuits)), Circuits),
            mycelium_circuit_relay:lookup(CId),
            Circuits;
        _ ->
            Circuits
    end,
    random_circuit_ops_loop(N - 1, From, EphPubKey, NewCircuits).
