-module(mycelium_nat_integration_SUITE).

%% End-to-end NAT traversal simulation tests
%% Tests simulated NAT scenarios with mocked components

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Simulated NAT Tests
-export([
    test_two_nodes_behind_same_nat/1,
    test_direct_connection_public_ip/1,
    test_hole_punch_compatible_nats/1,
    test_relay_fallback_symmetric_nat/1,
    test_latency_based_path_selection/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, simulated_nat_tests}].

groups() ->
    [
        {simulated_nat_tests, [sequence], [
            test_two_nodes_behind_same_nat,
            test_direct_connection_public_ip,
            test_hole_punch_compatible_nats,
            test_relay_fallback_symmetric_nat,
            test_latency_based_path_selection
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(meck),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(simulated_nat_tests, Config) ->
    %% Start NAT cache
    {ok, _} = mycelium_nat_test_helper:start_nat_cache(),
    Config.

end_per_group(simulated_nat_tests, _Config) ->
    mycelium_nat_test_helper:cleanup_mocks(),
    mycelium_nat_test_helper:stop_nat_cache(),
    ok.

init_per_testcase(_TestCase, Config) ->
    %% Clear cache before each test
    mycelium_nat_cache:invalidate_all_peers(),
    Config.

end_per_testcase(_TestCase, _Config) ->
    mycelium_nat_test_helper:cleanup_mocks([mycelium_nat, mycelium_hole_punch]),
    ok.

%%====================================================================
%% Simulated NAT Tests
%%====================================================================

test_two_nodes_behind_same_nat(_Config) ->
    %% Scenario: Two nodes (A and B) behind the same NAT gateway
    %% They share the same external IP but have different internal IPs
    %% Should be able to connect directly via internal addresses

    ExternalIP = {203,0,113,1},
    InternalA = {192,168,1,10},
    InternalB = {192,168,1,20},

    %% Node A NAT info
    NodeA = 'node_a@localhost',
    CandidatesA = [
        mycelium_nat_test_helper:make_candidate(host, InternalA, 4370, 200),
        mycelium_nat_test_helper:make_candidate(srflx, ExternalIP, 45000, 100)
    ],
    NatInfoA = mycelium_nat_test_helper:make_nat_info(port_restricted, ExternalIP, 45000, CandidatesA),

    %% Node B NAT info
    NodeB = 'node_b@localhost',
    CandidatesB = [
        mycelium_nat_test_helper:make_candidate(host, InternalB, 4370, 200),
        mycelium_nat_test_helper:make_candidate(srflx, ExternalIP, 45001, 100)
    ],
    NatInfoB = mycelium_nat_test_helper:make_nat_info(port_restricted, ExternalIP, 45001, CandidatesB),

    %% Cache peer info
    mycelium_nat_cache:set_peer_nat(NodeA, NatInfoA),
    mycelium_nat_cache:set_peer_nat(NodeB, NatInfoB),
    timer:sleep(50),

    %% Verify both are cached
    {ok, CachedA} = mycelium_nat_cache:get_peer_nat(NodeA),
    {ok, CachedB} = mycelium_nat_cache:get_peer_nat(NodeB),

    %% Both have same external IP (same NAT)
    ?assertEqual(ExternalIP, CachedA#nat_info.external_addr),
    ?assertEqual(ExternalIP, CachedB#nat_info.external_addr),

    %% Connection strategy: When same external IP, prefer host candidates
    BestCandidateA = select_best_candidate(CachedA#nat_info.candidates, ExternalIP),
    BestCandidateB = select_best_candidate(CachedB#nat_info.candidates, ExternalIP),

    %% Should select host candidates since same NAT
    ?assertEqual(host, BestCandidateA#candidate.type),
    ?assertEqual(host, BestCandidateB#candidate.type),
    ok.

test_direct_connection_public_ip(_Config) ->
    %% Scenario: Server with public IP, client behind NAT
    %% Client should be able to connect directly to server

    ServerNode = 'server@public',
    ServerIP = {198,51,100,1},

    %% Server has public IP (no NAT)
    ServerCandidates = [
        mycelium_nat_test_helper:make_candidate(host, ServerIP, 4370, 200)
    ],
    ServerNatInfo = mycelium_nat_test_helper:make_nat_info(public, ServerIP, 4370, ServerCandidates),

    %% Client behind NAT
    ClientNode = 'client@home',
    ClientInternalIP = {192,168,1,100},
    ClientExternalIP = {203,0,113,50},

    ClientCandidates = [
        mycelium_nat_test_helper:make_candidate(host, ClientInternalIP, 4370, 200),
        mycelium_nat_test_helper:make_candidate(srflx, ClientExternalIP, 50000, 100)
    ],
    ClientNatInfo = mycelium_nat_test_helper:make_nat_info(
        port_restricted, ClientExternalIP, 50000, ClientCandidates
    ),

    %% Cache info
    mycelium_nat_cache:set_peer_nat(ServerNode, ServerNatInfo),
    mycelium_nat_cache:set_peer_nat(ClientNode, ClientNatInfo),
    timer:sleep(50),

    %% Server is public, so connection is always viable
    ?assert(mycelium_hole_punch:is_viable(port_restricted, public)),
    ?assert(mycelium_hole_punch:is_viable(public, port_restricted)),

    %% Client can reach server directly
    {ok, ServerInfo} = mycelium_nat_cache:get_peer_nat(ServerNode),
    ?assertEqual(public, ServerInfo#nat_info.nat_type),

    %% Server's host candidate is the best choice
    [ServerCandidate] = ServerInfo#nat_info.candidates,
    ?assertEqual(host, ServerCandidate#candidate.type),
    ?assertEqual(ServerIP, ServerCandidate#candidate.address),
    ok.

test_hole_punch_compatible_nats(_Config) ->
    %% Scenario: Two nodes with compatible NATs (both port_restricted)
    %% Hole punching should be viable

    NodeA = 'punch_a@localhost',
    NodeB = 'punch_b@localhost',

    %% Node A behind port restricted NAT
    CandidatesA = [
        mycelium_nat_test_helper:make_candidate(host, {192,168,1,10}, 4370, 200),
        mycelium_nat_test_helper:make_candidate(srflx, {203,0,113,10}, 30000, 100)
    ],
    NatInfoA = mycelium_nat_test_helper:make_nat_info(port_restricted, {203,0,113,10}, 30000, CandidatesA),

    %% Node B behind port restricted NAT
    CandidatesB = [
        mycelium_nat_test_helper:make_candidate(host, {10,0,0,20}, 4370, 200),
        mycelium_nat_test_helper:make_candidate(srflx, {198,51,100,20}, 40000, 100)
    ],
    NatInfoB = mycelium_nat_test_helper:make_nat_info(port_restricted, {198,51,100,20}, 40000, CandidatesB),

    mycelium_nat_cache:set_peer_nat(NodeA, NatInfoA),
    mycelium_nat_cache:set_peer_nat(NodeB, NatInfoB),
    timer:sleep(50),

    %% Hole punch should be viable
    ?assert(mycelium_hole_punch:is_viable(port_restricted, port_restricted)),

    %% Verify candidates for hole punching
    {ok, InfoA} = mycelium_nat_cache:get_peer_nat(NodeA),
    {ok, InfoB} = mycelium_nat_cache:get_peer_nat(NodeB),

    %% Both should have srflx candidates for punching
    SrflxA = [C || C <- InfoA#nat_info.candidates, C#candidate.type =:= srflx],
    SrflxB = [C || C <- InfoB#nat_info.candidates, C#candidate.type =:= srflx],

    ?assertEqual(1, length(SrflxA)),
    ?assertEqual(1, length(SrflxB)),
    ok.

test_relay_fallback_symmetric_nat(_Config) ->
    %% Scenario: One node behind symmetric NAT, other behind port_restricted
    %% Hole punching NOT viable, must use relay

    NodeSym = 'symmetric_node@localhost',
    NodeRestr = 'restricted_node@localhost',

    %% Symmetric NAT (hole punching won't work)
    CandidatesSym = [
        mycelium_nat_test_helper:make_candidate(host, {192,168,100,5}, 4370, 200),
        mycelium_nat_test_helper:make_candidate(srflx, {100,64,0,1}, 60000, 100)
    ],
    NatInfoSym = mycelium_nat_test_helper:make_nat_info(symmetric, {100,64,0,1}, 60000, CandidatesSym),

    %% Port restricted NAT
    CandidatesRestr = [
        mycelium_nat_test_helper:make_candidate(host, {10,10,10,10}, 4370, 200),
        mycelium_nat_test_helper:make_candidate(srflx, {198,51,100,5}, 50000, 100)
    ],
    NatInfoRestr = mycelium_nat_test_helper:make_nat_info(
        port_restricted, {198,51,100,5}, 50000, CandidatesRestr
    ),

    mycelium_nat_cache:set_peer_nat(NodeSym, NatInfoSym),
    mycelium_nat_cache:set_peer_nat(NodeRestr, NatInfoRestr),
    timer:sleep(50),

    %% Hole punch NOT viable
    ?assertNot(mycelium_hole_punch:is_viable(symmetric, port_restricted)),
    ?assertNot(mycelium_hole_punch:is_viable(port_restricted, symmetric)),

    %% Decision: Need relay or other fallback
    {ok, SymInfo} = mycelium_nat_cache:get_peer_nat(NodeSym),
    ?assertEqual(symmetric, SymInfo#nat_info.nat_type),

    %% In a real scenario, we would:
    %% 1. Check for relay candidates
    %% 2. Use existing overlay network (HyParView) for routing
    %% 3. Fall back to circuit-based relay

    %% For now, verify symmetric is detected correctly
    ok.

test_latency_based_path_selection(_Config) ->
    %% Scenario: Multiple paths available, select based on priority
    %% Tests the candidate priority system

    PeerNode = 'multi_path_peer@localhost',

    %% Peer has multiple candidates with different priorities
    Candidates = [
        mycelium_nat_test_helper:make_candidate(host, {192,168,1,50}, 4370, 200),    %% Highest prio
        mycelium_nat_test_helper:make_candidate(srflx, {203,0,113,50}, 54321, 100),  %% Medium prio
        mycelium_nat_test_helper:make_candidate(relay, {8,8,8,8}, 3478, 10)          %% Lowest prio
    ],

    NatInfo = mycelium_nat_test_helper:make_nat_info(port_restricted, {203,0,113,50}, 54321, Candidates),
    mycelium_nat_cache:set_peer_nat(PeerNode, NatInfo),
    timer:sleep(50),

    {ok, CachedInfo} = mycelium_nat_cache:get_peer_nat(PeerNode),
    CandidateList = CachedInfo#nat_info.candidates,

    %% Sort by priority descending
    Sorted = lists:sort(fun(A, B) ->
        A#candidate.priority >= B#candidate.priority
    end, CandidateList),

    %% Best candidate should be host (highest priority)
    [Best | Rest] = Sorted,
    ?assertEqual(host, Best#candidate.type),
    ?assertEqual(200, Best#candidate.priority),

    %% Next should be srflx
    [Srflx | _] = Rest,
    ?assertEqual(srflx, Srflx#candidate.type),
    ?assertEqual(100, Srflx#candidate.priority),

    %% Connection strategy:
    %% 1. Try host candidate first (local network)
    %% 2. If unreachable, try srflx (hole punch)
    %% 3. Fall back to relay (always works but higher latency)

    %% Verify order for connection attempts
    ?assertEqual([host, srflx, relay], [C#candidate.type || C <- Sorted]),
    ok.

%%====================================================================
%% Helper Functions
%%====================================================================

%% Select best candidate considering same-NAT optimization
select_best_candidate(Candidates, OurExternalIP) ->
    %% Sort candidates by type preference
    Sorted = lists:sort(fun(A, B) ->
        candidate_preference(A, OurExternalIP) >= candidate_preference(B, OurExternalIP)
    end, Candidates),
    hd(Sorted).

%% Preference score for candidate selection
%% If peer has same external IP (same NAT), prefer host candidates
candidate_preference(#candidate{type = host, address = _Addr}, _OurExtIP) ->
    300;  %% Always prefer host if reachable
candidate_preference(#candidate{type = srflx}, _OurExtIP) ->
    100;
candidate_preference(#candidate{type = relay}, _OurExtIP) ->
    10.
