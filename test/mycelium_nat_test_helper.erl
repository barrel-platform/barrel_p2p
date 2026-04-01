-module(mycelium_nat_test_helper).

%% Test helper utilities for NAT traversal tests
%% Provides mock setup and test data creation functions

-include_lib("mycelium/include/mycelium.hrl").

-export([
    setup_estun_mocks/1,
    setup_nat_mocks/0,
    setup_transport_mocks/0,
    cleanup_mocks/0,
    cleanup_mocks/1,
    make_nat_info/2,
    make_nat_info/4,
    make_candidate/3,
    make_candidate/4,
    start_nat_cache/0,
    stop_nat_cache/0
]).

%% @doc Setup estun mocks for NAT discovery testing
-spec setup_estun_mocks(nat_type()) -> ok.
setup_estun_mocks(NatType) ->
    meck:new(estun, [non_strict]),
    meck:expect(estun, add_server, fun(_) -> {ok, mock_server_id} end),
    meck:expect(estun, discover, fun() ->
        {ok, #{address => {1,2,3,4}, port => 12345}}
    end),
    meck:expect(estun, discover_nat, fun(_) ->
        case NatType of
            public ->
                {ok, #{mapping => endpoint_independent, filtering => endpoint_independent}};
            full_cone ->
                {ok, #{mapping => endpoint_independent, filtering => endpoint_independent}};
            restricted_cone ->
                {ok, #{mapping => endpoint_independent, filtering => address_dependent}};
            port_restricted ->
                {ok, #{mapping => endpoint_independent, filtering => address_and_port_dependent}};
            symmetric ->
                {ok, #{mapping => address_and_port_dependent, filtering => address_and_port_dependent}};
            unknown ->
                {error, timeout}
        end
    end),
    ok.

%% @doc Setup erlang-nat mocks for UPnP/NAT-PMP testing
-spec setup_nat_mocks() -> ok.
setup_nat_mocks() ->
    meck:new(nat, [non_strict]),
    meck:expect(nat, discover, fun() -> {ok, mock_ctx} end),
    meck:expect(nat, get_external_address, fun(_) -> {ok, "1.2.3.4"} end),
    meck:expect(nat, add_port_mapping, fun(_, _, Port, _, _) ->
        {ok, 0, Port, Port, 7200}
    end),
    meck:expect(nat, delete_port_mapping, fun(_, _, _, _) -> ok end),
    ok.

%% @doc Setup transport mocks for connection simulation
-spec setup_transport_mocks() -> ok.
setup_transport_mocks() ->
    case erlang:function_exported(mycelium_circuit_transport_tcp, get_listen_port, 0) of
        true ->
            meck:new(mycelium_circuit_transport_tcp, [passthrough]),
            meck:expect(mycelium_circuit_transport_tcp, get_listen_port, fun() -> 4370 end);
        false ->
            ok
    end,
    ok.

%% @doc Cleanup all mocks
-spec cleanup_mocks() -> ok.
cleanup_mocks() ->
    cleanup_mocks([estun, nat, mycelium_circuit_transport_tcp]).

%% @doc Cleanup specific mocks
-spec cleanup_mocks([atom()]) -> ok.
cleanup_mocks(Modules) ->
    lists:foreach(fun(Mod) ->
        try
            case meck:validate(Mod) of
                true -> meck:unload(Mod);
                false -> meck:unload(Mod)
            end
        catch
            _:_ -> ok
        end
    end, Modules),
    ok.

%% @doc Create a #nat_info{} record for testing
-spec make_nat_info(nat_type(), inet:ip_address()) -> #nat_info{}.
make_nat_info(NatType, ExternalAddr) ->
    make_nat_info(NatType, ExternalAddr, 12345, []).

%% @doc Create a #nat_info{} record with full options
-spec make_nat_info(nat_type(), inet:ip_address(), inet:port_number(), [#candidate{}]) ->
    #nat_info{}.
make_nat_info(NatType, ExternalAddr, ExternalPort, Candidates) ->
    Now = erlang:monotonic_time(millisecond),
    #nat_info{
        nat_type = NatType,
        external_addr = ExternalAddr,
        external_port = ExternalPort,
        candidates = Candidates,
        discovered_at = Now,
        expires_at = Now + 3600000  %% 1 hour
    }.

%% @doc Create a #candidate{} record
-spec make_candidate(host | srflx | relay, inet:ip_address(), inet:port_number()) ->
    #candidate{}.
make_candidate(Type, Addr, Port) ->
    make_candidate(Type, Addr, Port, 100).

%% @doc Create a #candidate{} record with priority
-spec make_candidate(host | srflx | relay, inet:ip_address(), inet:port_number(),
                     non_neg_integer()) -> #candidate{}.
make_candidate(Type, Addr, Port, Priority) ->
    #candidate{
        type = Type,
        address = Addr,
        port = Port,
        priority = Priority
    }.

%% @doc Start NAT cache for testing
-spec start_nat_cache() -> {ok, pid()} | {error, term()}.
start_nat_cache() ->
    case whereis(mycelium_nat_cache) of
        undefined ->
            %% Clean up any leftover ETS table
            catch ets:delete(mycelium_nat_peer_cache),
            %% Use spawn to start unlinked so the server survives group init
            Parent = self(),
            Ref = make_ref(),
            spawn(fun() ->
                case mycelium_nat_cache:start_link() of
                    {ok, Pid} ->
                        unlink(Pid),  %% Unlink so it survives
                        Parent ! {Ref, {ok, Pid}};
                    {error, Reason} ->
                        Parent ! {Ref, {error, Reason}}
                end
            end),
            receive
                {Ref, Result} -> Result
            after 5000 ->
                {error, timeout}
            end;
        Pid ->
            {ok, Pid}
    end.

%% @doc Stop NAT cache
-spec stop_nat_cache() -> ok.
stop_nat_cache() ->
    case whereis(mycelium_nat_cache) of
        undefined ->
            %% Clean up any leftover ETS table
            catch ets:delete(mycelium_nat_peer_cache),
            ok;
        Pid ->
            try
                gen_server:stop(Pid, normal, 5000)
            catch
                _:_ -> ok
            end,
            %% Clean up ETS table
            catch ets:delete(mycelium_nat_peer_cache),
            ok
    end.
