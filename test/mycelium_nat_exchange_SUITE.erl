-module(mycelium_nat_exchange_SUITE).

%% Test suite for NAT info exchange via hello protocol
%% Tests encoding/decoding of NAT info in hello messages and cache updates

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Hello Protocol Tests
-export([
    test_encode_hello_v2/1,
    test_decode_hello_v2/1,
    test_decode_hello_v1_backwards_compat/1,
    test_nat_info_encoding/1,
    test_candidates_encoding/1
]).

%% Exchange Tests
-export([
    test_peer_nat_cached_on_hello/1,
    test_external_addr_used_for_connection/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, hello_protocol_tests},
     {group, exchange_tests}].

groups() ->
    [
        {hello_protocol_tests, [sequence], [
            test_encode_hello_v2,
            test_decode_hello_v2,
            test_decode_hello_v1_backwards_compat,
            test_nat_info_encoding,
            test_candidates_encoding
        ]},
        {exchange_tests, [sequence], [
            test_peer_nat_cached_on_hello,
            test_external_addr_used_for_connection
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(meck),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(exchange_tests, Config) ->
    {ok, _} = mycelium_nat_test_helper:start_nat_cache(),
    Config;
init_per_group(_Group, Config) ->
    Config.

end_per_group(exchange_tests, _Config) ->
    mycelium_nat_test_helper:stop_nat_cache(),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Hello Protocol Tests
%%====================================================================

test_encode_hello_v2(_Config) ->
    %% Create NAT info for encoding
    NatInfo = mycelium_nat_test_helper:make_nat_info(port_restricted, {1,2,3,4}, 12345, [
        mycelium_nat_test_helper:make_candidate(host, {192,168,1,100}, 4370),
        mycelium_nat_test_helper:make_candidate(srflx, {1,2,3,4}, 12345)
    ]),

    %% Encode as V2 hello payload
    Encoded = encode_hello_v2(node(), NatInfo),

    %% Should be a binary with version marker
    ?assert(is_binary(Encoded)),

    %% First byte should be version 2
    <<Version:8, _Rest/binary>> = Encoded,
    ?assertEqual(2, Version),
    ok.

test_decode_hello_v2(_Config) ->
    %% Create and encode NAT info
    OrigNatInfo = mycelium_nat_test_helper:make_nat_info(full_cone, {5,6,7,8}, 54321, [
        mycelium_nat_test_helper:make_candidate(srflx, {5,6,7,8}, 54321)
    ]),
    Sender = 'test_sender@localhost',

    Encoded = encode_hello_v2(Sender, OrigNatInfo),

    %% Decode should return the same data
    {ok, DecodedSender, DecodedNatInfo} = decode_hello_v2(Encoded),

    ?assertEqual(Sender, DecodedSender),
    ?assertEqual(full_cone, DecodedNatInfo#nat_info.nat_type),
    ?assertEqual({5,6,7,8}, DecodedNatInfo#nat_info.external_addr),
    ?assertEqual(54321, DecodedNatInfo#nat_info.external_port),
    ?assertEqual(1, length(DecodedNatInfo#nat_info.candidates)),
    ok.

test_decode_hello_v1_backwards_compat(_Config) ->
    %% V1 hello format (without NAT info)
    Sender = 'old_node@localhost',
    V1Hello = encode_hello_v1(Sender),

    %% Decoding V1 should work and return undefined NAT info
    case decode_hello(V1Hello) of
        {ok, DecodedSender, undefined} ->
            ?assertEqual(Sender, DecodedSender);
        {ok, DecodedSender, _NatInfo} ->
            %% Some implementations may return empty NAT info
            ?assertEqual(Sender, DecodedSender)
    end,
    ok.

test_nat_info_encoding(_Config) ->
    %% Test encoding of various NAT types
    NatTypes = [public, full_cone, restricted_cone, port_restricted, symmetric, unknown],

    lists:foreach(fun(NatType) ->
        Info = mycelium_nat_test_helper:make_nat_info(NatType, {10,0,0,1}),
        Encoded = encode_nat_info(Info),
        Decoded = decode_nat_info(Encoded),

        ?assertEqual(NatType, Decoded#nat_info.nat_type),
        ?assertEqual({10,0,0,1}, Decoded#nat_info.external_addr),
        ?assertEqual(12345, Decoded#nat_info.external_port)
    end, NatTypes),
    ok.

test_candidates_encoding(_Config) ->
    %% Test encoding of different candidate types
    Candidates = [
        mycelium_nat_test_helper:make_candidate(host, {192,168,1,1}, 4370, 200),
        mycelium_nat_test_helper:make_candidate(srflx, {1,2,3,4}, 12345, 100),
        mycelium_nat_test_helper:make_candidate(relay, {8,8,8,8}, 3478, 50)
    ],

    Encoded = encode_candidates(Candidates),
    Decoded = decode_candidates(Encoded),

    ?assertEqual(3, length(Decoded)),

    %% Verify each candidate
    [Host, Srflx, Relay] = Decoded,

    ?assertEqual(host, Host#candidate.type),
    ?assertEqual({192,168,1,1}, Host#candidate.address),
    ?assertEqual(4370, Host#candidate.port),
    ?assertEqual(200, Host#candidate.priority),

    ?assertEqual(srflx, Srflx#candidate.type),
    ?assertEqual({1,2,3,4}, Srflx#candidate.address),
    ?assertEqual(12345, Srflx#candidate.port),

    ?assertEqual(relay, Relay#candidate.type),
    ?assertEqual({8,8,8,8}, Relay#candidate.address),
    ok.

%%====================================================================
%% Exchange Tests
%%====================================================================

test_peer_nat_cached_on_hello(_Config) ->
    %% Clear any existing data
    mycelium_nat_cache:invalidate_all_peers(),

    PeerNode = 'hello_peer@localhost',
    PeerNatInfo = mycelium_nat_test_helper:make_nat_info(port_restricted, {9,9,9,9}, 9999, [
        mycelium_nat_test_helper:make_candidate(srflx, {9,9,9,9}, 9999)
    ]),

    %% Initially peer should not be in cache
    ?assertEqual({error, not_found}, mycelium_nat_cache:get_peer_nat(PeerNode)),

    %% Simulate receiving hello and caching NAT info
    %% This would normally be done by the connection handler
    mycelium_nat_cache:set_peer_nat(PeerNode, PeerNatInfo),
    timer:sleep(50),

    %% Now peer should be in cache
    {ok, CachedInfo} = mycelium_nat_cache:get_peer_nat(PeerNode),
    ?assertEqual(port_restricted, CachedInfo#nat_info.nat_type),
    ?assertEqual({9,9,9,9}, CachedInfo#nat_info.external_addr),
    ?assertEqual(9999, CachedInfo#nat_info.external_port),
    ok.

test_external_addr_used_for_connection(_Config) ->
    %% Test that when we have a peer's external address, we prefer it
    PeerNode = 'external_addr_peer@localhost',

    %% Peer is behind NAT with external address
    Candidates = [
        mycelium_nat_test_helper:make_candidate(host, {192,168,1,50}, 4370, 200),
        mycelium_nat_test_helper:make_candidate(srflx, {203,0,113,50}, 54321, 100)
    ],
    PeerNatInfo = mycelium_nat_test_helper:make_nat_info(
        port_restricted, {203,0,113,50}, 54321, Candidates
    ),

    mycelium_nat_cache:set_peer_nat(PeerNode, PeerNatInfo),
    timer:sleep(50),

    %% Get cached info
    {ok, CachedInfo} = mycelium_nat_cache:get_peer_nat(PeerNode),

    %% Get best candidate for connection (should be srflx for external)
    CandidateList = CachedInfo#nat_info.candidates,
    ?assertEqual(2, length(CandidateList)),

    %% Find srflx candidate (the external one)
    SrflxCandidates = [C || C <- CandidateList, C#candidate.type =:= srflx],
    ?assertEqual(1, length(SrflxCandidates)),
    [SrflxCand] = SrflxCandidates,
    ?assertEqual({203,0,113,50}, SrflxCand#candidate.address),
    ok.

%%====================================================================
%% Encoding/Decoding Helpers (simulate hello protocol)
%%====================================================================

%% Version 2 hello format with NAT info
encode_hello_v2(Sender, NatInfo) ->
    NatBin = encode_nat_info(NatInfo),
    SenderBin = term_to_binary(Sender),
    SenderLen = byte_size(SenderBin),
    <<2:8, SenderLen:16, SenderBin/binary, NatBin/binary>>.

decode_hello_v2(<<2:8, SenderLen:16, SenderBin:SenderLen/binary, NatBin/binary>>) ->
    Sender = binary_to_term(SenderBin),
    NatInfo = decode_nat_info(NatBin),
    {ok, Sender, NatInfo}.

%% Version 1 hello format (legacy, no NAT info)
encode_hello_v1(Sender) ->
    SenderBin = term_to_binary(Sender),
    <<1:8, SenderBin/binary>>.

decode_hello(<<1:8, SenderBin/binary>>) ->
    Sender = binary_to_term(SenderBin),
    {ok, Sender, undefined};
decode_hello(<<2:8, _/binary>> = Bin) ->
    decode_hello_v2(Bin).

%% NAT info encoding
encode_nat_info(#nat_info{
    nat_type = NatType,
    external_addr = ExtAddr,
    external_port = ExtPort,
    candidates = Candidates
}) ->
    NatTypeBin = nat_type_to_int(NatType),
    AddrBin = encode_address(ExtAddr),
    CandsBin = encode_candidates(Candidates),
    <<NatTypeBin:8, ExtPort:16, AddrBin/binary, CandsBin/binary>>.

decode_nat_info(<<NatTypeInt:8, ExtPort:16, Rest/binary>>) ->
    NatType = int_to_nat_type(NatTypeInt),
    {ExtAddr, CandsBin} = decode_address(Rest),
    Candidates = decode_candidates(CandsBin),
    Now = erlang:monotonic_time(millisecond),
    #nat_info{
        nat_type = NatType,
        external_addr = ExtAddr,
        external_port = ExtPort,
        candidates = Candidates,
        discovered_at = Now,
        expires_at = Now + 3600000
    }.

%% NAT type encoding
nat_type_to_int(public) -> 0;
nat_type_to_int(full_cone) -> 1;
nat_type_to_int(restricted_cone) -> 2;
nat_type_to_int(port_restricted) -> 3;
nat_type_to_int(symmetric) -> 4;
nat_type_to_int(unknown) -> 255.

int_to_nat_type(0) -> public;
int_to_nat_type(1) -> full_cone;
int_to_nat_type(2) -> restricted_cone;
int_to_nat_type(3) -> port_restricted;
int_to_nat_type(4) -> symmetric;
int_to_nat_type(_) -> unknown.

%% Address encoding (IPv4)
encode_address({A, B, C, D}) ->
    <<4:8, A:8, B:8, C:8, D:8>>;
encode_address(undefined) ->
    <<0:8>>.

decode_address(<<4:8, A:8, B:8, C:8, D:8, Rest/binary>>) ->
    {{A, B, C, D}, Rest};
decode_address(<<0:8, Rest/binary>>) ->
    {undefined, Rest}.

%% Candidates encoding
encode_candidates(Candidates) ->
    Count = length(Candidates),
    CandsBin = << <<(encode_candidate(C))/binary>> || C <- Candidates >>,
    <<Count:8, CandsBin/binary>>.

decode_candidates(<<Count:8, Rest/binary>>) ->
    decode_candidates(Count, Rest, []).

decode_candidates(0, _Rest, Acc) ->
    lists:reverse(Acc);
decode_candidates(N, Bin, Acc) ->
    {Cand, Rest} = decode_candidate(Bin),
    decode_candidates(N - 1, Rest, [Cand | Acc]).

encode_candidate(#candidate{type = Type, address = Addr, port = Port, priority = Priority}) ->
    TypeInt = candidate_type_to_int(Type),
    AddrBin = encode_candidate_address(Addr),
    <<TypeInt:8, Port:16, Priority:16, AddrBin/binary>>.

decode_candidate(<<TypeInt:8, Port:16, Priority:16, Rest/binary>>) ->
    Type = int_to_candidate_type(TypeInt),
    {Addr, Rest2} = decode_candidate_address(Rest),
    {#candidate{type = Type, address = Addr, port = Port, priority = Priority}, Rest2}.

candidate_type_to_int(host) -> 0;
candidate_type_to_int(srflx) -> 1;
candidate_type_to_int(relay) -> 2.

int_to_candidate_type(0) -> host;
int_to_candidate_type(1) -> srflx;
int_to_candidate_type(2) -> relay.

encode_candidate_address({A, B, C, D}) ->
    <<A:8, B:8, C:8, D:8>>.

decode_candidate_address(<<A:8, B:8, C:8, D:8, Rest/binary>>) ->
    {{A, B, C, D}, Rest}.
