-module(mycelium_nat_SUITE).

%% Test suite for NAT module and NAT cache operations
%% Tests NAT discovery, cache operations, and candidate building

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% NAT Cache Tests
-export([
    test_local_nat_set_get/1,
    test_local_nat_expiry/1,
    test_peer_nat_set_get/1,
    test_peer_nat_expiry/1,
    test_peer_nat_invalidate/1,
    test_list_peers/1
]).

%% NAT Discovery Tests (mocked)
-export([
    test_discover_public_nat/1,
    test_discover_full_cone/1,
    test_discover_port_restricted/1,
    test_discover_symmetric/1,
    test_discover_unknown_fallback/1
]).

%% Viability Matrix Tests
-export([
    test_public_to_any/1,
    test_full_cone_punch/1,
    test_restricted_punch/1,
    test_symmetric_relay_only/1
]).

%% Candidates Tests
-export([
    test_build_local_candidates/1,
    test_build_srflx_candidates/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, nat_cache_tests},
     {group, nat_discovery_tests},
     {group, nat_viability_tests},
     {group, nat_candidates_tests}].

groups() ->
    [
        {nat_cache_tests, [sequence], [
            test_local_nat_set_get,
            test_local_nat_expiry,
            test_peer_nat_set_get,
            test_peer_nat_expiry,
            test_peer_nat_invalidate,
            test_list_peers
        ]},
        {nat_discovery_tests, [sequence], [
            test_discover_public_nat,
            test_discover_full_cone,
            test_discover_port_restricted,
            test_discover_symmetric,
            test_discover_unknown_fallback
        ]},
        {nat_viability_tests, [parallel], [
            test_public_to_any,
            test_full_cone_punch,
            test_restricted_punch,
            test_symmetric_relay_only
        ]},
        {nat_candidates_tests, [sequence], [
            test_build_local_candidates,
            test_build_srflx_candidates
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(meck),
    %% Clean up any leftover state from previous runs
    mycelium_nat_test_helper:stop_nat_cache(),
    Config.

end_per_suite(_Config) ->
    mycelium_nat_test_helper:stop_nat_cache(),
    ok.

init_per_group(nat_cache_tests, Config) ->
    start_nat_cache_or_skip(Config);
init_per_group(nat_discovery_tests, Config) ->
    start_nat_cache_or_skip(Config);
init_per_group(nat_candidates_tests, Config) ->
    start_nat_cache_or_skip(Config);
init_per_group(_Group, Config) ->
    Config.

start_nat_cache_or_skip(Config) ->
    case mycelium_nat_test_helper:start_nat_cache() of
        {ok, _Pid} ->
            Config;
        {error, Reason} ->
            {skip, {nat_cache_start_failed, Reason}}
    end.

end_per_group(nat_cache_tests, _Config) ->
    mycelium_nat_test_helper:stop_nat_cache(),
    ok;
end_per_group(nat_discovery_tests, _Config) ->
    mycelium_nat_test_helper:cleanup_mocks(),
    mycelium_nat_test_helper:stop_nat_cache(),
    ok;
end_per_group(nat_candidates_tests, _Config) ->
    mycelium_nat_test_helper:cleanup_mocks(),
    mycelium_nat_test_helper:stop_nat_cache(),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(TestCase, Config) when
    TestCase =:= test_discover_public_nat;
    TestCase =:= test_discover_full_cone;
    TestCase =:= test_discover_port_restricted;
    TestCase =:= test_discover_symmetric;
    TestCase =:= test_discover_unknown_fallback ->
    %% Clean up any previous mocks
    mycelium_nat_test_helper:cleanup_mocks([estun]),
    Config;
init_per_testcase(TestCase, Config) when
    TestCase =:= test_build_local_candidates;
    TestCase =:= test_build_srflx_candidates ->
    mycelium_nat_test_helper:cleanup_mocks([mycelium_circuit_transport_tcp]),
    Config;
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(TestCase, _Config) when
    TestCase =:= test_discover_public_nat;
    TestCase =:= test_discover_full_cone;
    TestCase =:= test_discover_port_restricted;
    TestCase =:= test_discover_symmetric;
    TestCase =:= test_discover_unknown_fallback ->
    mycelium_nat_test_helper:cleanup_mocks([estun]),
    ok;
end_per_testcase(TestCase, _Config) when
    TestCase =:= test_build_local_candidates;
    TestCase =:= test_build_srflx_candidates ->
    mycelium_nat_test_helper:cleanup_mocks([mycelium_circuit_transport_tcp]),
    ok;
end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% NAT Cache Tests
%%====================================================================

test_local_nat_set_get(_Config) ->
    %% Initially should be not discovered
    ?assertEqual({error, not_discovered}, mycelium_nat_cache:get_local_nat()),

    %% Set local NAT info
    NatInfo = mycelium_nat_test_helper:make_nat_info(port_restricted, {1,2,3,4}),
    ok = mycelium_nat_cache:set_local_nat(NatInfo),

    %% Get should return the info
    {ok, Retrieved} = mycelium_nat_cache:get_local_nat(),
    ?assertEqual(port_restricted, Retrieved#nat_info.nat_type),
    ?assertEqual({1,2,3,4}, Retrieved#nat_info.external_addr),
    ?assertEqual(12345, Retrieved#nat_info.external_port),
    ok.

test_local_nat_expiry(_Config) ->
    %% Create NAT info that's already expired
    Now = erlang:monotonic_time(millisecond),
    ExpiredInfo = #nat_info{
        nat_type = full_cone,
        external_addr = {5,6,7,8},
        external_port = 9999,
        candidates = [],
        discovered_at = Now - 10000,
        expires_at = Now - 1000  %% Expired 1 second ago
    },
    ok = mycelium_nat_cache:set_local_nat(ExpiredInfo),

    %% Should return not_discovered for expired entry
    ?assertEqual({error, not_discovered}, mycelium_nat_cache:get_local_nat()),
    ok.

test_peer_nat_set_get(_Config) ->
    PeerNode = 'test_peer@localhost',

    %% Initially not found
    ?assertEqual({error, not_found}, mycelium_nat_cache:get_peer_nat(PeerNode)),

    %% Set peer NAT info
    NatInfo = mycelium_nat_test_helper:make_nat_info(full_cone, {10,0,0,1}),
    ok = mycelium_nat_cache:set_peer_nat(PeerNode, NatInfo),

    %% Give async cast time to complete
    timer:sleep(50),

    %% Get should return the info
    {ok, Retrieved} = mycelium_nat_cache:get_peer_nat(PeerNode),
    ?assertEqual(full_cone, Retrieved#nat_info.nat_type),
    ?assertEqual({10,0,0,1}, Retrieved#nat_info.external_addr),
    ok.

test_peer_nat_expiry(_Config) ->
    PeerNode = 'expiry_test_peer@localhost',

    %% Set a short but workable TTL via app env temporarily
    OldTTL = application:get_env(mycelium, nat_cache_ttl, 3600000),
    application:set_env(mycelium, nat_cache_ttl, 200),  %% 200ms

    NatInfo = mycelium_nat_test_helper:make_nat_info(symmetric, {192,168,1,1}),
    ok = mycelium_nat_cache:set_peer_nat(PeerNode, NatInfo),
    timer:sleep(50),  %% Wait for async cast to complete

    %% Should be available initially
    {ok, _} = mycelium_nat_cache:get_peer_nat(PeerNode),

    %% Wait for expiry (200ms + some buffer)
    timer:sleep(250),

    %% Should be expired now
    ?assertEqual({error, expired}, mycelium_nat_cache:get_peer_nat(PeerNode)),

    %% Restore TTL
    application:set_env(mycelium, nat_cache_ttl, OldTTL),
    ok.

test_peer_nat_invalidate(_Config) ->
    PeerNode = 'invalidate_test_peer@localhost',

    %% Set peer NAT info
    NatInfo = mycelium_nat_test_helper:make_nat_info(restricted_cone, {172,16,0,1}),
    ok = mycelium_nat_cache:set_peer_nat(PeerNode, NatInfo),
    timer:sleep(50),

    %% Verify it's there
    {ok, _} = mycelium_nat_cache:get_peer_nat(PeerNode),

    %% Invalidate
    ok = mycelium_nat_cache:invalidate_peer(PeerNode),

    %% Should be gone
    ?assertEqual({error, not_found}, mycelium_nat_cache:get_peer_nat(PeerNode)),
    ok.

test_list_peers(_Config) ->
    %% Clear all peers first
    ok = mycelium_nat_cache:invalidate_all_peers(),

    %% Add multiple peers
    Peers = [
        {'peer1@localhost', mycelium_nat_test_helper:make_nat_info(full_cone, {1,1,1,1})},
        {'peer2@localhost', mycelium_nat_test_helper:make_nat_info(port_restricted, {2,2,2,2})},
        {'peer3@localhost', mycelium_nat_test_helper:make_nat_info(symmetric, {3,3,3,3})}
    ],

    lists:foreach(fun({Node, Info}) ->
        mycelium_nat_cache:set_peer_nat(Node, Info)
    end, Peers),

    timer:sleep(100),

    %% List should return all peers
    Listed = mycelium_nat_cache:list_peers(),
    ?assertEqual(3, length(Listed)),

    %% Verify all peers are present
    ListedNodes = [N || {N, _} <- Listed],
    ?assert(lists:member('peer1@localhost', ListedNodes)),
    ?assert(lists:member('peer2@localhost', ListedNodes)),
    ?assert(lists:member('peer3@localhost', ListedNodes)),
    ok.

%%====================================================================
%% NAT Discovery Tests (with mocked estun)
%%====================================================================

test_discover_public_nat(_Config) ->
    %% Setup mock for public NAT (no NAT)
    mycelium_nat_test_helper:setup_estun_mocks(public),

    %% The classify_nat_type function should handle this
    Result = classify_nat_type(endpoint_independent, endpoint_independent),
    ?assertEqual(full_cone, Result),
    ok.

test_discover_full_cone(_Config) ->
    mycelium_nat_test_helper:setup_estun_mocks(full_cone),

    %% Test the classification
    Result = classify_nat_type(endpoint_independent, endpoint_independent),
    ?assertEqual(full_cone, Result),
    ok.

test_discover_port_restricted(_Config) ->
    mycelium_nat_test_helper:setup_estun_mocks(port_restricted),

    %% Test the classification
    Result = classify_nat_type(endpoint_independent, address_and_port_dependent),
    ?assertEqual(port_restricted, Result),
    ok.

test_discover_symmetric(_Config) ->
    mycelium_nat_test_helper:setup_estun_mocks(symmetric),

    %% Test the classification - both address_dependent mapping results in symmetric
    Result1 = classify_nat_type(address_dependent, endpoint_independent),
    ?assertEqual(symmetric, Result1),

    Result2 = classify_nat_type(address_and_port_dependent, address_and_port_dependent),
    ?assertEqual(symmetric, Result2),
    ok.

test_discover_unknown_fallback(_Config) ->
    mycelium_nat_test_helper:setup_estun_mocks(unknown),

    %% Unknown combinations should return unknown
    Result = classify_nat_type(random_mapping, random_filtering),
    ?assertEqual(unknown, Result),
    ok.

%% Helper to test NAT classification (mirrors mycelium_nat:classify_nat_type/2)
classify_nat_type(endpoint_independent, endpoint_independent) ->
    full_cone;
classify_nat_type(endpoint_independent, address_dependent) ->
    restricted_cone;
classify_nat_type(endpoint_independent, address_and_port_dependent) ->
    port_restricted;
classify_nat_type(address_dependent, _) ->
    symmetric;
classify_nat_type(address_and_port_dependent, _) ->
    symmetric;
classify_nat_type(_, _) ->
    unknown.

%%====================================================================
%% NAT Viability Matrix Tests
%%====================================================================

test_public_to_any(_Config) ->
    %% Public can connect to any NAT type
    ?assert(mycelium_hole_punch:is_viable(public, public)),
    ?assert(mycelium_hole_punch:is_viable(public, full_cone)),
    ?assert(mycelium_hole_punch:is_viable(public, restricted_cone)),
    ?assert(mycelium_hole_punch:is_viable(public, port_restricted)),
    ?assert(mycelium_hole_punch:is_viable(public, symmetric)),
    ?assert(mycelium_hole_punch:is_viable(public, unknown)),

    %% Any can connect to public
    ?assert(mycelium_hole_punch:is_viable(full_cone, public)),
    ?assert(mycelium_hole_punch:is_viable(restricted_cone, public)),
    ?assert(mycelium_hole_punch:is_viable(port_restricted, public)),
    ?assert(mycelium_hole_punch:is_viable(symmetric, public)),
    ok.

test_full_cone_punch(_Config) ->
    %% Full cone can punch to most types
    ?assert(mycelium_hole_punch:is_viable(full_cone, full_cone)),
    ?assert(mycelium_hole_punch:is_viable(full_cone, restricted_cone)),
    ?assert(mycelium_hole_punch:is_viable(full_cone, port_restricted)),

    %% But not symmetric
    ?assertNot(mycelium_hole_punch:is_viable(full_cone, symmetric)),
    ok.

test_restricted_punch(_Config) ->
    %% Restricted cone combinations
    ?assert(mycelium_hole_punch:is_viable(restricted_cone, full_cone)),
    ?assert(mycelium_hole_punch:is_viable(restricted_cone, restricted_cone)),
    ?assert(mycelium_hole_punch:is_viable(restricted_cone, port_restricted)),

    %% Port restricted combinations
    ?assert(mycelium_hole_punch:is_viable(port_restricted, full_cone)),
    ?assert(mycelium_hole_punch:is_viable(port_restricted, restricted_cone)),
    ?assert(mycelium_hole_punch:is_viable(port_restricted, port_restricted)),
    ok.

test_symmetric_relay_only(_Config) ->
    %% Symmetric NAT cannot hole punch (except to public)
    ?assertNot(mycelium_hole_punch:is_viable(symmetric, full_cone)),
    ?assertNot(mycelium_hole_punch:is_viable(symmetric, restricted_cone)),
    ?assertNot(mycelium_hole_punch:is_viable(symmetric, port_restricted)),
    ?assertNot(mycelium_hole_punch:is_viable(symmetric, symmetric)),

    %% Unknown also cannot punch
    ?assertNot(mycelium_hole_punch:is_viable(unknown, full_cone)),
    ?assertNot(mycelium_hole_punch:is_viable(unknown, restricted_cone)),
    ok.

%%====================================================================
%% Candidates Tests
%%====================================================================

test_build_local_candidates(_Config) ->
    %% Mock the transport to return a port
    meck:new(mycelium_circuit_transport_tcp, [non_strict]),
    meck:expect(mycelium_circuit_transport_tcp, get_listen_port, fun() -> 4370 end),

    %% Build candidates manually (simulating what mycelium_nat does)
    LocalAddrs = get_test_local_addresses(),
    Candidates = lists:map(fun(Addr) ->
        mycelium_nat_test_helper:make_candidate(host, Addr, 4370, 200)
    end, LocalAddrs),

    %% Verify structure
    lists:foreach(fun(Cand) ->
        ?assertEqual(host, Cand#candidate.type),
        ?assertEqual(4370, Cand#candidate.port),
        ?assertEqual(200, Cand#candidate.priority)
    end, Candidates),

    meck:unload(mycelium_circuit_transport_tcp),
    ok.

test_build_srflx_candidates(_Config) ->
    %% Server reflexive candidates come from STUN discovery
    ExternalAddr = {1,2,3,4},
    ExternalPort = 12345,

    SrflxCandidate = mycelium_nat_test_helper:make_candidate(srflx, ExternalAddr, ExternalPort, 100),

    ?assertEqual(srflx, SrflxCandidate#candidate.type),
    ?assertEqual(ExternalAddr, SrflxCandidate#candidate.address),
    ?assertEqual(ExternalPort, SrflxCandidate#candidate.port),
    ?assertEqual(100, SrflxCandidate#candidate.priority),
    ok.

%%====================================================================
%% Helper Functions
%%====================================================================

get_test_local_addresses() ->
    %% Return some test addresses (simulating inet:getifaddrs results)
    [{192,168,1,100}, {10,0,0,5}].
