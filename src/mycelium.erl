%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(mycelium).

-include("mycelium.hrl").

%% Retry configuration
-define(DEFAULT_RETRIES, 3).
-define(BASE_BACKOFF_MS, 100).
-define(MAX_BACKOFF_MS, 2000).

%% Public API
-export([
    join/1,
    leave/0,
    active_view/0,
    passive_view/0,
    subscribe/0,
    subscribe/1,
    unsubscribe/1
]).

%% Service Registry API
-export([
    register_service/1,
    register_service/2,
    unregister_service/1,
    lookup/1,
    lookup_local/1,
    list_services/0,
    whereis_service/1,
    whereis_service/2,
    global_register/1,
    get_proxy/1
]).

%% Service Events API
-export([
    subscribe_services/0,
    subscribe_services/1,
    unsubscribe_services/1
]).

%% Circuit API
-export([
    circuit_open/1,
    circuit_open/2,
    circuit_send/2,
    circuit_close/1,
    circuit_listen/0,
    circuit_listen/1,
    circuit_unlisten/0,
    circuit_unlisten/1
]).

%% Via callbacks for {via, mycelium, Name} registration
-export([
    register_name/2,
    unregister_name/1,
    whereis_name/1,
    send/2
]).

%% Connection migration (RFC 9000 §9 path migration)
-export([
    migrate_peer/1,
    migrate_peer/2
]).

%% Test helpers (for integration tests)
-export([
    start_service_holder/1,
    stop_service_holder/1
]).

%%====================================================================
%% HyParView API
%%====================================================================

-spec join(node()) -> ok | {error, term()}.
join(ContactNode) ->
    mycelium_hyparview:join(ContactNode).

-spec leave() -> ok.
leave() ->
    mycelium_hyparview:leave().

-spec active_view() -> [node()].
active_view() ->
    mycelium_hyparview:active_view().

-spec passive_view() -> [node()].
passive_view() ->
    mycelium_hyparview:passive_view().

-spec subscribe() -> ok.
subscribe() ->
    mycelium_hyparview_events:subscribe(self()).

-spec subscribe(pid()) -> ok.
subscribe(Pid) ->
    mycelium_hyparview_events:subscribe(Pid).

-spec unsubscribe(pid()) -> ok.
unsubscribe(Pid) ->
    mycelium_hyparview_events:unsubscribe(Pid).

%%====================================================================
%% Service Registry API
%%====================================================================

-spec register_service(atom() | binary()) -> ok | {error, term()}.
register_service(Name) ->
    register_service(Name, #{}).

-spec register_service(atom() | binary(), map()) -> ok | {error, term()}.
register_service(Name, Meta) ->
    mycelium_registry:register_service(Name, Meta).

-spec unregister_service(atom() | binary()) -> ok.
unregister_service(Name) ->
    mycelium_registry:unregister_service(Name).

-spec lookup(atom() | binary()) -> {ok, [tuple()]} | {error, not_found}.
lookup(Name) ->
    mycelium_registry:lookup(Name).

-spec lookup_local(atom() | binary()) -> {ok, pid()} | {error, not_found}.
lookup_local(Name) ->
    mycelium_registry:lookup_local(Name).

-spec list_services() -> [atom() | binary()].
list_services() ->
    mycelium_registry:list_services().

%% Find service with overlay routing fallback and transparent retry
%% Checks local → remote cache → overlay routing
-spec whereis_service(atom() | binary()) -> {ok, pid()} | {ok, node(), pid()} | {error, not_found}.
whereis_service(Name) ->
    whereis_service(Name, #{}).

-spec whereis_service(atom() | binary(), map()) -> {ok, pid()} | {ok, node(), pid()} | {error, not_found}.
whereis_service(Name, Opts) ->
    Retries = maps:get(retries, Opts, ?DEFAULT_RETRIES),
    whereis_service_retry(Name, Retries, ?BASE_BACKOFF_MS).

whereis_service_retry(Name, 0, _Delay) ->
    do_whereis_service(Name);
whereis_service_retry(Name, Retries, Delay) ->
    case do_whereis_service(Name) of
        {ok, _} = Success -> Success;
        {ok, _, _} = Success -> Success;
        {error, not_found} ->
            ActualDelay = min(Delay, ?MAX_BACKOFF_MS),
            timer:sleep(ActualDelay + rand:uniform(ActualDelay div 2)),
            whereis_service_retry(Name, Retries - 1, Delay * 2)
    end.

do_whereis_service(Name) ->
    %% First try local
    case mycelium_registry:lookup_local(Name) of
        {ok, Pid} ->
            {ok, Pid};
        {error, not_found} ->
            %% Try remote cache
            case mycelium_registry:lookup(Name) of
                {ok, [Entry | _]} ->
                    %% Found in remote cache
                    {ok, Entry#service_entry.node, Entry#service_entry.pid};
                {error, not_found} ->
                    %% Try overlay routing
                    mycelium_registry:overlay_lookup(Name)
            end
    end.

%% Register a service with global for transparency
%% Creates a local proxy and registers it with global:register_name
-spec global_register(atom() | binary()) -> {ok, pid()} | {error, term()}.
global_register(Name) ->
    case whereis_service(Name) of
        {ok, Pid} when node(Pid) =:= node() ->
            %% Local service - register directly with global
            case global:register_name(Name, Pid) of
                yes -> {ok, Pid};
                no -> {error, already_registered}
            end;
        {ok, TargetNode, _Pid} ->
            %% Remote service - create proxy and register
            case mycelium_registry:ensure_proxy(Name, TargetNode) of
                {ok, Proxy} ->
                    case global:register_name(Name, Proxy) of
                        yes -> {ok, Proxy};
                        no -> {error, already_registered}
                    end;
                {error, _} = Error ->
                    Error
            end;
        {ok, Pid} ->
            %% Local pid returned from overlay lookup
            case global:register_name(Name, Pid) of
                yes -> {ok, Pid};
                no -> {error, already_registered}
            end;
        {error, not_found} ->
            {error, not_found}
    end.

%% Get existing proxy for a service
-spec get_proxy(atom() | binary()) -> {ok, pid()} | not_found.
get_proxy(Name) ->
    mycelium_registry:get_proxy(Name).

%%====================================================================
%% Service Events API
%%====================================================================

%% Subscribe to service events (register, unregister, down)
-spec subscribe_services() -> ok.
subscribe_services() ->
    mycelium_service_events:subscribe(self()).

-spec subscribe_services(pid()) -> ok.
subscribe_services(Pid) ->
    mycelium_service_events:subscribe(Pid).

-spec unsubscribe_services(pid()) -> ok.
unsubscribe_services(Pid) ->
    mycelium_service_events:unsubscribe(Pid).

%%====================================================================
%% Via Callbacks - for use with {via, mycelium, Name}
%%====================================================================
%% These callbacks implement the standard name registration interface,
%% allowing mycelium to be used as a process registry with gen_server,
%% gen_statem, etc.
%%
%% Example usage:
%%   %% Start a gen_server registered with mycelium
%%   gen_server:start({via, mycelium, my_service}, ?MODULE, [], [])
%%
%%   %% Call the service by name
%%   gen_server:call({via, mycelium, my_service}, request)
%%
%%   %% Send a message to a remote service
%%   mycelium:send(my_service, {data, Payload})
%%
%% For remote services, use whereis_service/1 which returns {ok, Node, Pid}
%% for remote processes, then send directly:
%%   case mycelium:whereis_service(remote_svc) of
%%       {ok, Pid} -> Pid ! Msg;                    %% local
%%       {ok, _Node, Pid} -> Pid ! Msg;             %% remote
%%       {error, not_found} -> handle_not_found()
%%   end

-spec register_name(Name :: term(), Pid :: pid()) -> yes | no.
register_name(Name, Pid) when is_pid(Pid) ->
    case mycelium_registry:register_service(Name, Pid, #{}) of
        ok -> yes;
        {error, _} -> no
    end.

-spec unregister_name(Name :: term()) -> ok.
unregister_name(Name) ->
    mycelium_registry:unregister_service(Name).

-spec whereis_name(Name :: term()) -> pid() | undefined.
whereis_name(Name) ->
    case whereis_service(Name) of
        {ok, Pid} -> Pid;
        {ok, _Node, Pid} -> Pid;
        {error, not_found} -> undefined
    end.

-spec send(Name :: term(), Msg :: term()) -> pid().
send(Name, Msg) ->
    case whereis_name(Name) of
        undefined ->
            erlang:error({badarg, {Name, Msg}});
        Pid ->
            Pid ! Msg,
            Pid
    end.

%%====================================================================
%% Circuit API
%%====================================================================
%%
%% Multi-hop streams over the existing per-peer dist QUIC connection.
%% Thin wrapper around the `mycelium_circuit' module; see that module
%% and `docs/external-relay.md' for details.

%% @doc Open a single-hop circuit (direct stream) to `Target'.
-spec circuit_open(node()) ->
    {ok, mycelium_circuit:circuit_ref()} | {error, term()}.
circuit_open(Target) ->
    mycelium_circuit:open(Target).

%% @doc Open a multi-hop circuit to `Target' through the listed
%% intermediate hops.
-spec circuit_open(node(), [node()]) ->
    {ok, mycelium_circuit:circuit_ref()} | {error, term()}.
circuit_open(Target, Path) ->
    mycelium_circuit:open(Target, Path).

%% @doc Send opaque application bytes on a circuit.
-spec circuit_send(mycelium_circuit:circuit_ref(), iodata()) ->
    ok | {error, term()}.
circuit_send(CRef, Data) ->
    mycelium_circuit:send(CRef, Data).

%% @doc Close a circuit (half-close, FIN). Both sides receive a
%% `closed' message after the other half is also closed.
-spec circuit_close(mycelium_circuit:circuit_ref()) -> ok.
circuit_close(CRef) ->
    mycelium_circuit:close(CRef).

%% @doc Register the calling process to receive incoming circuits.
-spec circuit_listen() -> ok.
circuit_listen() ->
    mycelium_circuit:listen().

-spec circuit_listen(pid()) -> ok.
circuit_listen(Pid) ->
    mycelium_circuit:listen(Pid).

-spec circuit_unlisten() -> ok.
circuit_unlisten() ->
    mycelium_circuit:unlisten().

-spec circuit_unlisten(pid()) -> ok.
circuit_unlisten(Pid) ->
    mycelium_circuit:unlisten(Pid).

%%====================================================================
%% Connection Migration
%%====================================================================

%% @doc Trigger RFC 9000 §9 path migration on the QUIC connection
%% backing the dist channel to `Node'. The connection rebinds to a
%% new local 4-tuple via PATH_CHALLENGE/PATH_RESPONSE; keys, streams,
%% and any open circuits ride through transparently. Useful when the
%% local network changes (NIC/IP swap, tethering, multi-link policy).
%%
%% Returns `ok' on successful path validation. Common errors:
%% - `{error, not_connected}' — no current dist channel to `Node'
%% - `{error, no_conn}' — controller alive but underlying conn gone
%% - `{error, peer_disable_migration}' — peer set the transport-param
%%   flag forbidding migration; treat as terminal for this connection
%% - `{error, timeout}' — path validation didn't complete in time
-spec migrate_peer(node()) -> ok | {error, term()}.
migrate_peer(Node) ->
    migrate_peer(Node, #{}).

-spec migrate_peer(node(), #{timeout => pos_integer()}) ->
    ok | {error, term()}.
migrate_peer(Node, Opts) when is_atom(Node), is_map(Opts) ->
    case mycelium_path_stats:connection(Node) of
        {ok, Conn} -> quic:migrate(Conn, Opts);
        Err        -> Err
    end.

%%====================================================================
%% Test Helpers
%%====================================================================

%% Start a persistent process that holds a service registration
%% Used by integration tests to avoid RPC process lifetime issues
-spec start_service_holder(atom() | binary()) -> {ok, pid()} | {error, term()}.
start_service_holder(ServiceName) ->
    Parent = self(),
    Pid = spawn(fun() -> service_holder_init(ServiceName, Parent) end),
    receive
        {Pid, ok} -> {ok, Pid};
        {Pid, {error, Reason}} -> {error, Reason}
    after 5000 ->
        exit(Pid, kill),
        {error, timeout}
    end.

%% Stop a service holder process
-spec stop_service_holder(pid()) -> ok.
stop_service_holder(Pid) ->
    Pid ! stop,
    ok.

%% Internal: service holder initialization
service_holder_init(ServiceName, Parent) ->
    case register_service(ServiceName, #{}) of
        ok ->
            Parent ! {self(), ok},
            service_holder_loop(ServiceName);
        {error, Reason} ->
            Parent ! {self(), {error, Reason}}
    end.

%% Internal: service holder loop
service_holder_loop(ServiceName) ->
    receive
        stop ->
            unregister_service(ServiceName),
            ok;
        _ ->
            service_holder_loop(ServiceName)
    end.
