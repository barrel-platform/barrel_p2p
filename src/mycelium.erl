-module(mycelium).

-include("mycelium.hrl").

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
    global_register/1,
    get_proxy/1
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

%% Find service with overlay routing fallback
%% Checks local → remote cache → overlay routing
-spec whereis_service(atom() | binary()) -> {ok, pid()} | {ok, node(), pid()} | {error, not_found}.
whereis_service(Name) ->
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
