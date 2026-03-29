-module(mycelium_ormap).

%% OR-Map (Observed-Remove Map) CRDT using HLC-based dots.
%% Provides conflict-free concurrent add/remove semantics.
%%
%% Each entry has a set of "dots" (node + HLC timestamp pairs) that track
%% when/where it was added. Merge unions dots, and the value with the
%% latest HLC "wins" when dots conflict.

-include_lib("hlc/include/hlc.hrl").

-export([new/0, add/3, remove/2, get/2, keys/1, to_list/1]).
-export([merge/2, is_empty/1]).
-export([get_entry/2]).

-type dot() :: {node(), mycelium_hlc:timestamp()}.
-type entry() :: {term(), #{dot() => true}}.
-type ormap() :: #{term() => entry()}.

-export_type([ormap/0, dot/0, entry/0]).

%%====================================================================
%% API
%%====================================================================

%% Create a new empty OR-Map
-spec new() -> ormap().
new() -> #{}.

%% Add a key-value pair with a new dot
-spec add(term(), term(), ormap()) -> ormap().
add(Key, Value, Map) ->
    Dot = {node(), mycelium_hlc:now()},
    case maps:get(Key, Map, undefined) of
        undefined ->
            maps:put(Key, {Value, #{Dot => true}}, Map);
        {_, Dots} ->
            maps:put(Key, {Value, maps:put(Dot, true, Dots)}, Map)
    end.

%% Remove a key (tombstone semantics - remove all dots)
-spec remove(term(), ormap()) -> ormap().
remove(Key, Map) ->
    maps:remove(Key, Map).

%% Get value for a key
-spec get(term(), ormap()) -> {ok, term()} | not_found.
get(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        undefined -> not_found;
        {Value, _Dots} -> {ok, Value}
    end.

%% Get full entry (value + dots) for a key
-spec get_entry(term(), ormap()) -> {ok, entry()} | not_found.
get_entry(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        undefined -> not_found;
        Entry -> {ok, Entry}
    end.

%% Get all keys in the map
-spec keys(ormap()) -> [term()].
keys(Map) -> maps:keys(Map).

%% Convert to list of {Key, Value} pairs
-spec to_list(ormap()) -> [{term(), term()}].
to_list(Map) ->
    [{K, V} || {K, {V, _Dots}} <- maps:to_list(Map)].

%% Check if map is empty
-spec is_empty(ormap()) -> boolean().
is_empty(Map) -> maps:size(Map) =:= 0.

%% Merge two OR-Maps (commutative, associative, idempotent)
-spec merge(ormap(), ormap()) -> ormap().
merge(Map1, Map2) ->
    Keys = lists:usort(maps:keys(Map1) ++ maps:keys(Map2)),
    lists:foldl(fun(Key, Acc) ->
        Entry = case {maps:get(Key, Map1, undefined),
                      maps:get(Key, Map2, undefined)} of
            {undefined, E2} -> E2;
            {E1, undefined} -> E1;
            {{V1, D1}, {V2, D2}} ->
                MergedDots = maps:merge(D1, D2),
                {pick_latest(V1, D1, V2, D2), MergedDots}
        end,
        maps:put(Key, Entry, Acc)
    end, #{}, Keys).

%%====================================================================
%% Internal Functions
%%====================================================================

%% Pick the value with the latest HLC timestamp
pick_latest(V1, D1, V2, D2) ->
    Max1 = max_hlc(maps:keys(D1)),
    Max2 = max_hlc(maps:keys(D2)),
    case mycelium_hlc:compare(Max1, Max2) of
        gt -> V1;
        _ -> V2
    end.

%% Find the maximum HLC timestamp from a list of dots
max_hlc([{_Node, HLC}]) -> HLC;
max_hlc([{_Node, HLC} | Rest]) ->
    RestMax = max_hlc(Rest),
    case mycelium_hlc:compare(HLC, RestMax) of
        gt -> HLC;
        _ -> RestMax
    end.
