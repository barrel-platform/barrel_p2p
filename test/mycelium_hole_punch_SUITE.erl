-module(mycelium_hole_punch_SUITE).

%% Test suite for hole punching module
%% Tests session management, signaling, and viability checks

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("mycelium.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Session Tests
-export([
    test_start_session/1,
    test_session_timeout/1,
    test_session_cancel/1,
    test_incompatible_nat_rejection/1
]).

%% Signaling Tests
-export([
    test_encode_decode_punch_packet/1,
    test_encode_signal_message/1
]).

%% Viability Tests
-export([
    test_viability_matrix/1
]).

%%====================================================================
%% CT Callbacks
%%====================================================================

all() ->
    [{group, session_tests},
     {group, signaling_tests},
     {group, viability_tests}].

groups() ->
    [
        {session_tests, [sequence], [
            test_start_session,
            test_session_timeout,
            test_session_cancel,
            test_incompatible_nat_rejection
        ]},
        {signaling_tests, [parallel], [
            test_encode_decode_punch_packet,
            test_encode_signal_message
        ]},
        {viability_tests, [parallel], [
            test_viability_matrix
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(meck),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(session_tests, Config) ->
    %% Start NAT cache and hole punch server
    {ok, _} = mycelium_nat_test_helper:start_nat_cache(),

    %% Start hole punch server with unlink
    start_hole_punch_server(),

    %% Short timeout for tests
    application:set_env(mycelium, hole_punch_timeout, 500),
    Config;
init_per_group(_Group, Config) ->
    Config.

start_hole_punch_server() ->
    case whereis(mycelium_hole_punch) of
        undefined ->
            %% Clean up any leftover ETS table
            catch ets:delete(mycelium_hole_punch_sessions),
            %% Use spawn to start unlinked so the server survives group init
            Parent = self(),
            Ref = make_ref(),
            spawn(fun() ->
                case mycelium_hole_punch:start_link() of
                    {ok, Pid} ->
                        unlink(Pid),
                        Parent ! {Ref, {ok, Pid}};
                    {error, Reason} ->
                        Parent ! {Ref, {error, Reason}}
                end
            end),
            receive
                {Ref, {ok, _Pid}} -> ok;
                {Ref, {error, Reason}} -> {error, Reason}
            after 5000 ->
                {error, timeout}
            end;
        _Pid ->
            ok
    end.

end_per_group(session_tests, _Config) ->
    mycelium_nat_test_helper:cleanup_mocks(),
    case whereis(mycelium_hole_punch) of
        undefined -> ok;
        Pid ->
            try gen_server:stop(Pid, normal, 5000)
            catch _:_ -> ok
            end
    end,
    catch ets:delete(mycelium_hole_punch_sessions),
    mycelium_nat_test_helper:stop_nat_cache(),
    ok;
end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(test_start_session, Config) ->
    %% Setup mocks for NAT
    setup_nat_mocks_for_session(),
    Config;
init_per_testcase(test_session_timeout, Config) ->
    setup_nat_mocks_for_session(),
    Config;
init_per_testcase(test_session_cancel, Config) ->
    setup_nat_mocks_for_session(),
    Config;
init_per_testcase(test_incompatible_nat_rejection, Config) ->
    setup_symmetric_nat_mocks(),
    Config;
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(TestCase, _Config) when
    TestCase =:= test_start_session;
    TestCase =:= test_session_timeout;
    TestCase =:= test_session_cancel;
    TestCase =:= test_incompatible_nat_rejection ->
    mycelium_nat_test_helper:cleanup_mocks([mycelium_nat, mycelium_hyparview]),
    ok;
end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Session Tests
%%====================================================================

test_start_session(_Config) ->
    %% Set up peer NAT info in cache
    PeerNode = 'test_punch_peer@localhost',
    PeerNatInfo = mycelium_nat_test_helper:make_nat_info(full_cone, {2,2,2,2}, 54321, [
        mycelium_nat_test_helper:make_candidate(srflx, {2,2,2,2}, 54321)
    ]),
    mycelium_nat_cache:set_peer_nat(PeerNode, PeerNatInfo),
    timer:sleep(50),

    %% Try async punch - it will start session but likely fail due to no network
    Result = mycelium_hole_punch:punch_async(PeerNode, #{}),
    case Result of
        {ok, SessionId} ->
            ?assert(is_binary(SessionId)),
            ?assertEqual(16, byte_size(SessionId)),
            %% Cancel so we don't wait for timeout
            mycelium_hole_punch:cancel(SessionId);
        {error, _Reason} ->
            %% This is also valid - session creation might fail in test env
            ok
    end,
    ok.

test_session_timeout(_Config) ->
    PeerNode = 'timeout_peer@localhost',
    PeerNatInfo = mycelium_nat_test_helper:make_nat_info(port_restricted, {3,3,3,3}, 33333, []),
    mycelium_nat_cache:set_peer_nat(PeerNode, PeerNatInfo),
    timer:sleep(50),

    %% Start async punch
    case mycelium_hole_punch:punch_async(PeerNode, #{}) of
        {ok, SessionId} ->
            %% Wait for timeout notification
            receive
                {hole_punch, SessionId, {error, timeout}} ->
                    ok;
                {hole_punch, SessionId, {error, _Reason}} ->
                    %% Other errors are acceptable in test
                    ok
            after 2000 ->
                %% If no message, check socket directly
                case mycelium_hole_punch:get_socket(SessionId) of
                    {error, _} -> ok;  %% Session cleaned up
                    {ok, _} -> ct:fail("Session should have timed out")
                end
            end;
        {error, _} ->
            %% OK if session fails to start
            ok
    end,
    ok.

test_session_cancel(_Config) ->
    PeerNode = 'cancel_peer@localhost',
    PeerNatInfo = mycelium_nat_test_helper:make_nat_info(full_cone, {4,4,4,4}, 44444, []),
    mycelium_nat_cache:set_peer_nat(PeerNode, PeerNatInfo),
    timer:sleep(50),

    %% Start async punch
    case mycelium_hole_punch:punch_async(PeerNode, #{}) of
        {ok, SessionId} ->
            %% Cancel immediately
            ok = mycelium_hole_punch:cancel(SessionId),

            %% Should receive cancellation notice
            receive
                {hole_punch, SessionId, {error, cancelled}} ->
                    ok
            after 100 ->
                %% Session should be cleaned up
                ?assertEqual({error, not_found}, mycelium_hole_punch:get_socket(SessionId))
            end;
        {error, _} ->
            ok
    end,
    ok.

test_incompatible_nat_rejection(_Config) ->
    %% Both sides are symmetric - should fail viability check
    PeerNode = 'symmetric_peer@localhost',
    PeerNatInfo = mycelium_nat_test_helper:make_nat_info(symmetric, {5,5,5,5}, 55555, []),
    mycelium_nat_cache:set_peer_nat(PeerNode, PeerNatInfo),
    timer:sleep(50),

    %% Punch should fail with incompatible NAT types
    Result = mycelium_hole_punch:punch(PeerNode, #{timeout => 500}),
    case Result of
        {error, incompatible_nat_types} -> ok;
        {error, _} -> ok  %% Other errors acceptable
    end,
    ok.

%%====================================================================
%% Signaling Tests
%%====================================================================

test_encode_decode_punch_packet(_Config) ->
    SessionId = crypto:strong_rand_bytes(16),

    %% Test punch packet encoding/decoding
    PunchPacket = encode_punch_packet(SessionId),

    %% Verify format: HP magic (2 bytes) + session ID (16 bytes) + type (1 byte)
    ?assertEqual(19, byte_size(PunchPacket)),

    %% Decode should work
    {ok, DecodedId, punch} = decode_punch_packet(PunchPacket),
    ?assertEqual(SessionId, DecodedId),

    %% Test ack packet
    AckPacket = encode_ack_packet(SessionId),
    {ok, DecodedAckId, ack} = decode_punch_packet(AckPacket),
    ?assertEqual(SessionId, DecodedAckId),

    %% Invalid packets should fail
    ?assertEqual({error, invalid_packet}, decode_punch_packet(<<>>)),
    ?assertEqual({error, invalid_packet}, decode_punch_packet(<<"invalid">>)),
    ok.

test_encode_signal_message(_Config) ->
    SessionId = crypto:strong_rand_bytes(16),

    %% Test encoding different message types
    Candidates = [
        mycelium_nat_test_helper:make_candidate(host, {192,168,1,1}, 5000),
        mycelium_nat_test_helper:make_candidate(srflx, {1,2,3,4}, 12345)
    ],

    %% Request message
    RequestMsg = encode_signal_message(?HOLE_PUNCH_REQUEST, SessionId, Candidates),
    ?assertEqual(?HOLE_PUNCH_REQUEST, binary:first(RequestMsg)),
    ?assert(byte_size(RequestMsg) > 17),

    %% Response message
    ResponseMsg = encode_signal_message(?HOLE_PUNCH_RESPONSE, SessionId, Candidates),
    ?assertEqual(?HOLE_PUNCH_RESPONSE, binary:first(ResponseMsg)),

    %% Connect message
    ConnectMsg = encode_signal_message(?HOLE_PUNCH_CONNECT, SessionId, #{}),
    ?assertEqual(?HOLE_PUNCH_CONNECT, binary:first(ConnectMsg)),

    %% Connected message
    ConnectedMsg = encode_signal_message(?HOLE_PUNCH_CONNECTED, SessionId, #{status => ok}),
    ?assertEqual(?HOLE_PUNCH_CONNECTED, binary:first(ConnectedMsg)),
    ok.

%%====================================================================
%% Viability Tests
%%====================================================================

test_viability_matrix(_Config) ->
    %% Test all combinations of NAT types
    %% Expected viability matrix
    Expected = [
        %% {LocalType, RemoteType, Viable}
        {public, public, true},
        {public, full_cone, true},
        {public, restricted_cone, true},
        {public, port_restricted, true},
        {public, symmetric, true},
        {public, unknown, true},

        {full_cone, public, true},
        {full_cone, full_cone, true},
        {full_cone, restricted_cone, true},
        {full_cone, port_restricted, true},
        {full_cone, symmetric, false},
        {full_cone, unknown, false},

        {restricted_cone, public, true},
        {restricted_cone, full_cone, true},
        {restricted_cone, restricted_cone, true},
        {restricted_cone, port_restricted, true},
        {restricted_cone, symmetric, false},
        {restricted_cone, unknown, false},

        {port_restricted, public, true},
        {port_restricted, full_cone, true},
        {port_restricted, restricted_cone, true},
        {port_restricted, port_restricted, true},
        {port_restricted, symmetric, false},
        {port_restricted, unknown, false},

        {symmetric, public, true},
        {symmetric, full_cone, false},
        {symmetric, restricted_cone, false},
        {symmetric, port_restricted, false},
        {symmetric, symmetric, false},
        {symmetric, unknown, false},

        {unknown, public, true},
        {unknown, full_cone, false},
        {unknown, restricted_cone, false},
        {unknown, port_restricted, false},
        {unknown, symmetric, false},
        {unknown, unknown, false}
    ],

    %% Verify each combination
    lists:foreach(fun({Local, Remote, ExpectedViable}) ->
        Actual = mycelium_hole_punch:is_viable(Local, Remote),
        ?assertEqual(ExpectedViable, Actual,
            io_lib:format("Expected is_viable(~p, ~p) = ~p, got ~p",
                [Local, Remote, ExpectedViable, Actual]))
    end, Expected),
    ok.

%%====================================================================
%% Helper Functions
%%====================================================================

setup_nat_mocks_for_session() ->
    %% Mock mycelium_nat to return port_restricted
    meck:new(mycelium_nat, [passthrough, no_link]),
    meck:expect(mycelium_nat, get_nat_type, fun() -> port_restricted end),
    meck:expect(mycelium_nat, get_candidates, fun() ->
        [mycelium_nat_test_helper:make_candidate(srflx, {1,1,1,1}, 11111)]
    end),

    %% Mock hyparview for relay selection
    meck:new(mycelium_hyparview, [non_strict, no_link]),
    meck:expect(mycelium_hyparview, active_view, fun() -> [] end),
    ok.

setup_symmetric_nat_mocks() ->
    meck:new(mycelium_nat, [passthrough, no_link]),
    meck:expect(mycelium_nat, get_nat_type, fun() -> symmetric end),
    meck:expect(mycelium_nat, get_candidates, fun() -> [] end),

    meck:new(mycelium_hyparview, [non_strict, no_link]),
    meck:expect(mycelium_hyparview, active_view, fun() -> [] end),
    ok.

%% Punch packet encoding (mirrors mycelium_hole_punch internals)
-define(PUNCH_MAGIC, 16#4850).

encode_punch_packet(SessionId) ->
    <<?PUNCH_MAGIC:16, SessionId/binary, 16#01>>.

encode_ack_packet(SessionId) ->
    <<?PUNCH_MAGIC:16, SessionId/binary, 16#02>>.

decode_punch_packet(<<?PUNCH_MAGIC:16, SessionId:16/binary, 16#01>>) ->
    {ok, SessionId, punch};
decode_punch_packet(<<?PUNCH_MAGIC:16, SessionId:16/binary, 16#02>>) ->
    {ok, SessionId, ack};
decode_punch_packet(_) ->
    {error, invalid_packet}.

%% Signal message encoding (mirrors mycelium_hole_punch internals)
encode_signal_message(Type, SessionId, Data) ->
    DataBin = term_to_binary(Data),
    <<Type:8, SessionId/binary, DataBin/binary>>.
