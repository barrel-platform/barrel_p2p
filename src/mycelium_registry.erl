-module(mycelium_registry).
-behaviour(gen_server).

-include("mycelium.hrl").

%% API
-export([start_link/0]).
-export([register_service/2, unregister_service/1]).
-export([lookup/1, lookup_local/1, list_services/0]).
-export([get_all_local/0]).
-export([overlay_lookup/1]).

%% Internal API (used by sync)
-export([merge_remote/2, remove_node_entries/1, remove_entry/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {
    %% Local services: name -> #service_entry{}
    local = #{} :: #{atom() | binary() => #service_entry{}},
    %% Remote services: {name, node} -> #service_entry{}
    remote = #{} :: #{{atom() | binary(), node()} => #service_entry{}},
    %% Monitor refs: ref -> name
    monitors = #{} :: #{reference() => atom() | binary()},
    %% Version counter
    version = 0 :: non_neg_integer()
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec register_service(atom() | binary(), map()) -> ok | {error, term()}.
register_service(Name, Meta) ->
    gen_server:call(?SERVER, {register, Name, Meta}).

-spec unregister_service(atom() | binary()) -> ok.
unregister_service(Name) ->
    gen_server:call(?SERVER, {unregister, Name}).

-spec lookup(atom() | binary()) -> {ok, [#service_entry{}]} | {error, not_found}.
lookup(Name) ->
    gen_server:call(?SERVER, {lookup, Name}).

-spec lookup_local(atom() | binary()) -> {ok, pid()} | {error, not_found}.
lookup_local(Name) ->
    gen_server:call(?SERVER, {lookup_local, Name}).

-spec list_services() -> [atom() | binary()].
list_services() ->
    gen_server:call(?SERVER, list_services).

-spec get_all_local() -> [#service_entry{}].
get_all_local() ->
    gen_server:call(?SERVER, get_all_local).

%% Lookup using overlay routing (when not found locally/remotely)
-spec overlay_lookup(atom() | binary()) -> {ok, node(), pid()} | {error, not_found}.
overlay_lookup(Name) ->
    mycelium_router:find_service(Name).

%% Internal API
-spec merge_remote(node(), [#service_entry{}]) -> ok.
merge_remote(Node, Entries) ->
    gen_server:cast(?SERVER, {merge_remote, Node, Entries}).

-spec remove_node_entries(node()) -> ok.
remove_node_entries(Node) ->
    gen_server:cast(?SERVER, {remove_node, Node}).

-spec remove_entry(atom() | binary(), node()) -> ok.
remove_entry(Name, Node) ->
    gen_server:cast(?SERVER, {remove_entry, Name, Node}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    {ok, #state{}}.

handle_call({register, Name, Meta}, {Pid, _}, State) ->
    case maps:is_key(Name, State#state.local) of
        true ->
            {reply, {error, already_registered}, State};
        false ->
            Ref = monitor(process, Pid),
            Version = State#state.version + 1,
            Entry = #service_entry{
                name = Name,
                pid = Pid,
                node = node(),
                version = Version,
                meta = Meta
            },
            Local = maps:put(Name, Entry, State#state.local),
            Monitors = maps:put(Ref, Name, State#state.monitors),
            %% Notify sync
            mycelium_registry_sync:broadcast_update({add, Entry}),
            {reply, ok, State#state{
                local = Local,
                monitors = Monitors,
                version = Version
            }}
    end;

handle_call({unregister, Name}, _From, State) ->
    case maps:take(Name, State#state.local) of
        {Entry, Local} ->
            %% Find and remove monitor
            MonitorRef = find_monitor_for_name(Name, State#state.monitors),
            Monitors = case MonitorRef of
                undefined -> State#state.monitors;
                Ref ->
                    demonitor(Ref, [flush]),
                    maps:remove(Ref, State#state.monitors)
            end,
            %% Notify sync
            mycelium_registry_sync:broadcast_update({remove, Entry#service_entry.name, node()}),
            {reply, ok, State#state{local = Local, monitors = Monitors}};
        error ->
            {reply, ok, State}
    end;

handle_call({lookup, Name}, _From, State) ->
    LocalEntries = case maps:get(Name, State#state.local, undefined) of
        undefined -> [];
        Entry -> [Entry]
    end,
    RemoteEntries = [E || {{N, _Node}, E} <- maps:to_list(State#state.remote), N =:= Name],
    case LocalEntries ++ RemoteEntries of
        [] -> {reply, {error, not_found}, State};
        Entries -> {reply, {ok, Entries}, State}
    end;

handle_call({lookup_local, Name}, _From, State) ->
    case maps:get(Name, State#state.local, undefined) of
        undefined -> {reply, {error, not_found}, State};
        #service_entry{pid = Pid} -> {reply, {ok, Pid}, State}
    end;

handle_call(list_services, _From, State) ->
    LocalNames = maps:keys(State#state.local),
    RemoteNames = lists:usort([N || {N, _} <- maps:keys(State#state.remote)]),
    {reply, lists:usort(LocalNames ++ RemoteNames), State};

handle_call(get_all_local, _From, State) ->
    {reply, maps:values(State#state.local), State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({merge_remote, Node, Entries}, State) ->
    %% Merge entries from remote node using LWW
    Remote = lists:foldl(fun(Entry, Acc) ->
        Key = {Entry#service_entry.name, Node},
        case maps:get(Key, Acc, undefined) of
            undefined ->
                maps:put(Key, Entry, Acc);
            Existing when Entry#service_entry.version > Existing#service_entry.version ->
                maps:put(Key, Entry, Acc);
            _ ->
                Acc
        end
    end, State#state.remote, Entries),
    {noreply, State#state{remote = Remote}};

handle_cast({remove_node, Node}, State) ->
    Remote = maps:filter(fun({_Name, N}, _Entry) ->
        N =/= Node
    end, State#state.remote),
    %% Invalidate routes to this node
    mycelium_router:invalidate_route(Node),
    {noreply, State#state{remote = Remote}};

handle_cast({remove_entry, Name, Node}, State) ->
    %% Remove specific entry from remote cache
    Key = {Name, Node},
    Remote = maps:remove(Key, State#state.remote),
    %% Invalidate route cache for this service
    mycelium_router:invalidate_route(Name),
    {noreply, State#state{remote = Remote}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    case maps:take(Ref, State#state.monitors) of
        {Name, Monitors} ->
            case maps:take(Name, State#state.local) of
                {_Entry, Local} ->
                    mycelium_registry_sync:broadcast_update({remove, Name, node()}),
                    {noreply, State#state{local = Local, monitors = Monitors}};
                error ->
                    {noreply, State#state{monitors = Monitors}}
            end;
        error ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

find_monitor_for_name(Name, Monitors) ->
    case [Ref || {Ref, N} <- maps:to_list(Monitors), N =:= Name] of
        [Ref | _] -> Ref;
        [] -> undefined
    end.
