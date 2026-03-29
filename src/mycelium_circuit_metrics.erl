-module(mycelium_circuit_metrics).

%% Circuit routing metrics collection
%%
%% Tracks circuit lifecycle, latency, and throughput metrics using ETS counters.
%% Metrics can be retrieved via get_metrics/0 or individual getters.

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    %% Recording
    circuit_created/1,
    circuit_established/2,
    circuit_failed/1,
    circuit_closed/1,
    data_sent/1,
    data_received/1,
    %% Retrieval
    get_metrics/0,
    get_latency_stats/0,
    reset_metrics/0
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(COUNTERS_TABLE, mycelium_circuit_counters).
-define(LATENCY_TABLE, mycelium_circuit_latencies).

%% Counter keys
-define(CIRCUITS_CREATED, circuits_created).
-define(CIRCUITS_ESTABLISHED, circuits_established).
-define(CIRCUITS_FAILED, circuits_failed).
-define(CIRCUITS_CLOSED, circuits_closed).
-define(CIRCUITS_ACTIVE, circuits_active).
-define(DATA_SENT_BYTES, data_sent_bytes).
-define(DATA_SENT_COUNT, data_sent_count).
-define(DATA_RECV_BYTES, data_recv_bytes).
-define(DATA_RECV_COUNT, data_recv_count).

%% Latency histogram buckets (in milliseconds)
-define(LATENCY_BUCKETS, [10, 50, 100, 250, 500, 1000, 2500, 5000, 10000]).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Record circuit creation started
-spec circuit_created(Role :: initiator | destination) -> ok.
circuit_created(Role) ->
    increment_counter(?CIRCUITS_CREATED),
    increment_counter({circuits_created, Role}),
    increment_counter(?CIRCUITS_ACTIVE),
    ok.

%% @doc Record circuit established with latency
-spec circuit_established(Role :: initiator | destination, LatencyMs :: non_neg_integer()) -> ok.
circuit_established(Role, LatencyMs) ->
    increment_counter(?CIRCUITS_ESTABLISHED),
    increment_counter({circuits_established, Role}),
    record_latency(LatencyMs),
    ok.

%% @doc Record circuit failure
-spec circuit_failed(Reason :: term()) -> ok.
circuit_failed(Reason) ->
    increment_counter(?CIRCUITS_FAILED),
    increment_counter({circuits_failed, categorize_failure(Reason)}),
    decrement_counter(?CIRCUITS_ACTIVE),
    ok.

%% @doc Record circuit closed normally
-spec circuit_closed(Reason :: term()) -> ok.
circuit_closed(Reason) ->
    increment_counter(?CIRCUITS_CLOSED),
    increment_counter({circuits_closed, categorize_close(Reason)}),
    decrement_counter(?CIRCUITS_ACTIVE),
    ok.

%% @doc Record data sent
-spec data_sent(Bytes :: non_neg_integer()) -> ok.
data_sent(Bytes) ->
    increment_counter(?DATA_SENT_COUNT),
    increment_counter(?DATA_SENT_BYTES, Bytes),
    ok.

%% @doc Record data received
-spec data_received(Bytes :: non_neg_integer()) -> ok.
data_received(Bytes) ->
    increment_counter(?DATA_RECV_COUNT),
    increment_counter(?DATA_RECV_BYTES, Bytes),
    ok.

%% @doc Get all metrics as a map
-spec get_metrics() -> map().
get_metrics() ->
    Counters = get_all_counters(),
    LatencyStats = get_latency_stats(),
    maps:merge(Counters, #{latency => LatencyStats}).

%% @doc Get latency statistics
-spec get_latency_stats() -> map().
get_latency_stats() ->
    case ets:info(?LATENCY_TABLE, size) of
        undefined -> empty_latency_stats();
        0 -> empty_latency_stats();
        _ -> compute_latency_stats()
    end.

%% @doc Reset all metrics
-spec reset_metrics() -> ok.
reset_metrics() ->
    gen_server:call(?SERVER, reset_metrics).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    %% Create counters table with write_concurrency
    ?COUNTERS_TABLE = ets:new(?COUNTERS_TABLE, [
        named_table, public, set,
        {write_concurrency, true},
        {read_concurrency, true}
    ]),

    %% Create latency samples table (ring buffer of recent samples)
    ?LATENCY_TABLE = ets:new(?LATENCY_TABLE, [
        named_table, public, ordered_set,
        {write_concurrency, true}
    ]),

    %% Initialize counters
    lists:foreach(fun(Key) ->
        ets:insert(?COUNTERS_TABLE, {Key, 0})
    end, [
        ?CIRCUITS_CREATED, ?CIRCUITS_ESTABLISHED, ?CIRCUITS_FAILED,
        ?CIRCUITS_CLOSED, ?CIRCUITS_ACTIVE,
        ?DATA_SENT_BYTES, ?DATA_SENT_COUNT,
        ?DATA_RECV_BYTES, ?DATA_RECV_COUNT
    ]),

    %% Initialize latency histogram buckets
    lists:foreach(fun(Bucket) ->
        ets:insert(?COUNTERS_TABLE, {{latency_bucket, Bucket}, 0})
    end, ?LATENCY_BUCKETS),
    ets:insert(?COUNTERS_TABLE, {{latency_bucket, infinity}, 0}),
    ets:insert(?COUNTERS_TABLE, {latency_sum, 0}),
    ets:insert(?COUNTERS_TABLE, {latency_count, 0}),

    {ok, #state{}}.

handle_call(reset_metrics, _From, State) ->
    do_reset_metrics(),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal Functions
%%====================================================================

increment_counter(Key) ->
    increment_counter(Key, 1).

increment_counter(Key, Amount) ->
    try
        ets:update_counter(?COUNTERS_TABLE, Key, Amount)
    catch
        error:badarg ->
            %% Counter doesn't exist, create it
            ets:insert_new(?COUNTERS_TABLE, {Key, Amount})
    end.

decrement_counter(Key) ->
    try
        ets:update_counter(?COUNTERS_TABLE, Key, -1)
    catch
        error:badarg -> ok
    end.

record_latency(LatencyMs) ->
    %% Update sum and count for average calculation
    increment_counter(latency_sum, LatencyMs),
    increment_counter(latency_count),

    %% Update histogram bucket
    Bucket = find_bucket(LatencyMs, ?LATENCY_BUCKETS),
    increment_counter({latency_bucket, Bucket}),

    %% Store sample with timestamp for percentile calculation
    Timestamp = erlang:monotonic_time(microsecond),
    ets:insert(?LATENCY_TABLE, {{Timestamp, make_ref()}, LatencyMs}),

    %% Prune old samples (keep last 1000)
    prune_latency_samples(1000).

find_bucket(_Value, []) ->
    infinity;
find_bucket(Value, [Bucket | _]) when Value =< Bucket ->
    Bucket;
find_bucket(Value, [_ | Rest]) ->
    find_bucket(Value, Rest).

prune_latency_samples(MaxSamples) ->
    Size = ets:info(?LATENCY_TABLE, size),
    case Size > MaxSamples of
        true ->
            %% Delete oldest entries
            ToDelete = Size - MaxSamples,
            Keys = ets:select(?LATENCY_TABLE, [{'$1', [], ['$_']}], ToDelete),
            case Keys of
                {Entries, _} ->
                    lists:foreach(fun({Key, _}) ->
                        ets:delete(?LATENCY_TABLE, Key)
                    end, Entries);
                '$end_of_table' ->
                    ok
            end;
        false ->
            ok
    end.

get_all_counters() ->
    lists:foldl(fun({Key, Value}, Acc) ->
        case Key of
            {latency_bucket, _} -> Acc;  % Skip histogram buckets
            latency_sum -> Acc;
            latency_count -> Acc;
            _ -> Acc#{Key => Value}
        end
    end, #{}, ets:tab2list(?COUNTERS_TABLE)).

compute_latency_stats() ->
    [{_, Sum}] = ets:lookup(?COUNTERS_TABLE, latency_sum),
    [{_, Count}] = ets:lookup(?COUNTERS_TABLE, latency_count),

    %% Get all samples for percentile calculation
    Samples = [V || {_, V} <- ets:tab2list(?LATENCY_TABLE)],

    case Count of
        0 ->
            empty_latency_stats();
        _ ->
            Sorted = lists:sort(Samples),
            #{
                count => Count,
                sum_ms => Sum,
                avg_ms => Sum / Count,
                min_ms => hd(Sorted),
                max_ms => lists:last(Sorted),
                p50_ms => percentile(Sorted, 50),
                p90_ms => percentile(Sorted, 90),
                p99_ms => percentile(Sorted, 99),
                histogram => get_histogram()
            }
    end.

percentile(Sorted, P) ->
    Len = length(Sorted),
    case Len of
        0 -> 0;
        _ ->
            Idx = max(1, min(Len, round(Len * P / 100))),
            lists:nth(Idx, Sorted)
    end.

get_histogram() ->
    Buckets = ?LATENCY_BUCKETS ++ [infinity],
    lists:foldl(fun(Bucket, Acc) ->
        case ets:lookup(?COUNTERS_TABLE, {latency_bucket, Bucket}) of
            [{_, Count}] -> Acc#{Bucket => Count};
            [] -> Acc#{Bucket => 0}
        end
    end, #{}, Buckets).

empty_latency_stats() ->
    #{
        count => 0,
        sum_ms => 0,
        avg_ms => 0,
        min_ms => 0,
        max_ms => 0,
        p50_ms => 0,
        p90_ms => 0,
        p99_ms => 0,
        histogram => #{}
    }.

do_reset_metrics() ->
    %% Reset all counters to 0
    ets:foldl(fun({Key, _}, _) ->
        ets:insert(?COUNTERS_TABLE, {Key, 0})
    end, ok, ?COUNTERS_TABLE),
    %% Clear latency samples
    ets:delete_all_objects(?LATENCY_TABLE),
    ok.

categorize_failure(timeout) -> timeout;
categorize_failure({transport_down, _}) -> transport_down;
categorize_failure({destroyed, _}) -> destroyed;
categorize_failure(not_enough_peers) -> not_enough_peers;
categorize_failure(local_close) -> local_close;
categorize_failure(_) -> other.

categorize_close(local) -> local;
categorize_close(expired) -> expired;
categorize_close({remote, _}) -> remote;
categorize_close(decrypt_failed) -> decrypt_failed;
categorize_close({transport_down, _}) -> transport_down;
categorize_close(_) -> other.
