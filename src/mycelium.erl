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
    whereis_service/1
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
