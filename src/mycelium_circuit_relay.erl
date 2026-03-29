-module(mycelium_circuit_relay).
-behaviour(gen_server).

%% Circuit relay handler
%%
%% Manages circuits passing through this node as an intermediate hop.
%% Relay nodes do not decrypt traffic - they forward opaque blobs.
%% State is kept in an ETS table for fast lookup during forwarding.

-include("mycelium.hrl").

%% API
-export([
    start_link/0,
    handle_create/3,
    handle_extend/4,
    lookup/1,
    remove/1,
    count/0,
    list/0,
    %% Listener API for destination nodes
    listen/1,
    unlisten/0,
    get_listener/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(TABLE, mycelium_circuit_relay_table).

-record(state, {
    max_relays :: pos_integer(),
    idle_timeout :: pos_integer(),
    listener :: pid() | undefined,       %% Process receiving incoming circuits
    listener_mon :: reference() | undefined  %% Monitor ref for listener
}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Handle CREATE request - establish this node as first relay hop
-spec handle_create(From :: node(), CircuitId :: #circuit_id{}, EphPubKey :: binary()) ->
    ok | {error, term()}.
handle_create(From, CircuitId, EphPubKey) ->
    gen_server:call(?SERVER, {create, From, CircuitId, EphPubKey}).

%% @doc Handle EXTEND request - establish forward path to next hop
-spec handle_extend(From :: node(), CircuitId :: #circuit_id{}, TargetNode :: node(), EphPubKey :: binary()) ->
    ok | {error, term()}.
handle_extend(From, CircuitId, TargetNode, EphPubKey) ->
    gen_server:call(?SERVER, {extend, From, CircuitId, TargetNode, EphPubKey}).

%% @doc Lookup circuit hop state
-spec lookup(CircuitId :: #circuit_id{}) -> {ok, #circuit_hop{}} | {error, not_found}.
lookup(CircuitId) ->
    Key = circuit_key(CircuitId),
    case ets:lookup(?TABLE, Key) of
        [{_, Hop}] -> {ok, Hop};
        [] -> {error, not_found}
    end.

%% @doc Remove circuit hop
-spec remove(CircuitId :: #circuit_id{}) -> ok.
remove(CircuitId) ->
    Key = circuit_key(CircuitId),
    ets:delete(?TABLE, Key),
    ok.

%% @doc Count active relayed circuits
-spec count() -> non_neg_integer().
count() ->
    ets:info(?TABLE, size).

%% @doc List all relayed circuits
-spec list() -> [#circuit_hop{}].
list() ->
    [Hop || {_, Hop} <- ets:tab2list(?TABLE)].

%% @doc Register process to receive incoming circuit notifications.
%% The listener will receive:
%%   {circuit_ready, CircuitId} - when circuit is established
%%   {circuit_data, CircuitId, Data} - when data arrives
%%   {circuit_closed, CircuitId, Reason} - when circuit closes
-spec listen(pid()) -> ok | {error, already_listening}.
listen(Pid) ->
    gen_server:call(?SERVER, {listen, Pid}).

%% @doc Unregister as circuit listener
-spec unlisten() -> ok.
unlisten() ->
    gen_server:call(?SERVER, unlisten).

%% @doc Get current listener (internal use)
-spec get_listener() -> {ok, pid()} | none.
get_listener() ->
    gen_server:call(?SERVER, get_listener).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    ?TABLE = ets:new(?TABLE, [named_table, public, {read_concurrency, true}]),
    MaxRelays = application:get_env(mycelium, circuit_relay_max, 500),
    IdleTimeout = application:get_env(mycelium, circuit_idle_timeout, 300000),

    %% Start cleanup timer
    erlang:send_after(IdleTimeout, self(), cleanup),

    {ok, #state{
        max_relays = MaxRelays,
        idle_timeout = IdleTimeout,
        listener = undefined,
        listener_mon = undefined
    }}.

handle_call({listen, Pid}, _From, State) ->
    case State#state.listener of
        undefined ->
            MonRef = erlang:monitor(process, Pid),
            {reply, ok, State#state{listener = Pid, listener_mon = MonRef}};
        _OtherPid ->
            {reply, {error, already_listening}, State}
    end;

handle_call(unlisten, _From, State) ->
    case State#state.listener_mon of
        undefined -> ok;
        MonRef -> erlang:demonitor(MonRef, [flush])
    end,
    {reply, ok, State#state{listener = undefined, listener_mon = undefined}};

handle_call(get_listener, _From, State) ->
    Reply = case State#state.listener of
        undefined -> none;
        Pid -> {ok, Pid}
    end,
    {reply, Reply, State};

handle_call({create, From, CircuitId, EphPubKey}, _ReplyTo, State) ->
    %% Check if we have a listener waiting for incoming circuits
    case State#state.listener of
        Pid when is_pid(Pid) ->
            %% We're the destination - accept the circuit
            case mycelium_circuit:accept(CircuitId, EphPubKey, Pid) of
                {ok, _CircuitPid} ->
                    {reply, ok, State};
                {error, Reason} ->
                    {reply, {error, Reason}, State}
            end;
        undefined ->
            %% No listener - act as relay
            case count() >= State#state.max_relays of
                true ->
                    {reply, {error, relay_limit_reached}, State};
                false ->
                    Now = erlang:monotonic_time(millisecond),
                    Hop = #circuit_hop{
                        circuit_id = CircuitId,
                        prev_node = From,
                        next_node = undefined, %% Will be set on EXTEND
                        created_at = Now,
                        last_seen = Now
                    },
                    Key = circuit_key(CircuitId),
                    ets:insert(?TABLE, {Key, Hop}),

                    %% Generate our ephemeral keypair for key exchange with initiator
                    %% But since relays don't decrypt, we just acknowledge receipt
                    %% The initiator's pubkey is passed through to the destination
                    {PubKey, _PrivKey} = mycelium_crypto:generate_ephemeral_keypair(),

                    %% Send CREATED back to initiator through the previous hop
                    Reply = mycelium_circuit_protocol:encode_created(CircuitId, PubKey),
                    mycelium_circuit_transport:send(From, CircuitId, Reply),

                    {reply, ok, State}
            end
    end;

handle_call({extend, _From, CircuitId, TargetNode, EphPubKey}, _ReplyTo, State) ->
    Key = circuit_key(CircuitId),
    case ets:lookup(?TABLE, Key) of
        [{_, Hop}] ->
            case Hop#circuit_hop.next_node of
                undefined ->
                    %% Update hop with next node
                    Now = erlang:monotonic_time(millisecond),
                    UpdatedHop = Hop#circuit_hop{
                        next_node = TargetNode,
                        last_seen = Now
                    },
                    ets:insert(?TABLE, {Key, UpdatedHop}),

                    %% Forward CREATE to target node
                    %% The target becomes the destination (or next relay)
                    CreateMsg = mycelium_circuit_protocol:encode_create(CircuitId, EphPubKey),
                    mycelium_circuit_transport:send(TargetNode, CircuitId, CreateMsg),
                    {reply, ok, State};
                _ ->
                    {reply, {error, already_extended}, State}
            end;
        [] ->
            {reply, {error, circuit_not_found}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(cleanup, State) ->
    cleanup_idle_circuits(State#state.idle_timeout),
    erlang:send_after(State#state.idle_timeout, self(), cleanup),
    {noreply, State};

handle_info({'DOWN', MonRef, process, _Pid, _Reason}, State)
  when MonRef =:= State#state.listener_mon ->
    %% Listener process died, clear it
    {noreply, State#state{listener = undefined, listener_mon = undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

circuit_key(#circuit_id{id = Id, initiator = Initiator}) ->
    {Id, Initiator}.

cleanup_idle_circuits(IdleTimeout) ->
    Now = erlang:monotonic_time(millisecond),
    Cutoff = Now - IdleTimeout,
    %% Find and remove idle circuits
    ToRemove = ets:foldl(fun({Key, Hop}, Acc) ->
        case Hop#circuit_hop.last_seen < Cutoff of
            true -> [Key | Acc];
            false -> Acc
        end
    end, [], ?TABLE),
    lists:foreach(fun(Key) ->
        %% Send destroy to both sides before removing
        case ets:lookup(?TABLE, Key) of
            [{_, Hop}] ->
                CircuitId = Hop#circuit_hop.circuit_id,
                DestroyMsg = mycelium_circuit_protocol:encode_destroy(CircuitId, 1), %% 1 = timeout
                case Hop#circuit_hop.prev_node of
                    initiator -> ok;
                    PrevNode ->
                        mycelium_circuit_transport:send(PrevNode, CircuitId, DestroyMsg)
                end,
                case Hop#circuit_hop.next_node of
                    undefined -> ok;
                    destination -> ok;
                    NextNode ->
                        mycelium_circuit_transport:send(NextNode, CircuitId, DestroyMsg)
                end;
            [] -> ok
        end,
        ets:delete(?TABLE, Key)
    end, ToRemove).
