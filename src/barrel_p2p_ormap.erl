%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
-module(barrel_p2p_ormap).

%% A last-write-wins map with HLC-tagged tombstones, suitable for
%% replicating the service registry.
%%
%% Each key holds either a `value' entry (a payload plus the dot of the
%% write that produced it, the newest write seen for the key) or a
%% `tombstone' entry (an HLC marking the time of removal). Merge keeps the entry with the greater
%% HLC (ties between concurrent values broken deterministically by the
%% node atom, so the merge is commutative and replicas never diverge); a
%% tombstone newer than any value wins, and an add newer than
%% any tombstone wins. The two outcomes are symmetric, so delayed
%% gossip cannot resurrect a removed entry, nor can a delayed remove
%% silently drop a fresher add.
%%
%% Keeping only the newest dot makes the merge a strict join-semilattice
%% (commutative, associative, idempotent; checked exhaustively in
%% spec/tla/MergeLattice.tla): every replica that has seen the same writes
%% holds the same entry, not just the same visible value. The dot map
%% shape `#{Dot => true}' is kept for wire compatibility; an entry from an
%% older node carrying several dots is reduced to its newest one on merge.

-include_lib("hlc/include/hlc.hrl").

-export([new/0, add/3, remove/2, get/2, keys/1, to_list/1]).
-export([add_dot/4, remove_at/3]).
-export([merge/2, is_empty/1]).
-export([get_entry/2]).
-export([absorb_clock/1, gc_tombstones/2]).

-type dot() :: {node(), barrel_p2p_hlc:timestamp()}.
-type value_entry() :: {value, term(), #{dot() => true}}.
-type tombstone_entry() :: {tombstone, barrel_p2p_hlc:timestamp()}.
-type entry() :: value_entry() | tombstone_entry().
-type ormap() :: #{term() => entry()}.

-export_type([ormap/0, dot/0, entry/0]).

%%====================================================================
%% API
%%====================================================================

%% Create a new empty OR-Map.
-spec new() -> ormap().
new() -> #{}.

%% Add a key-value pair with a fresh dot. If the current entry is a
%% tombstone newer than the add's HLC, the add is silently ignored;
%% the tombstone won.
-spec add(term(), term(), ormap()) -> ormap().
add(Key, Value, Map) ->
    add_dot(Key, Value, {node(), barrel_p2p_hlc:now()}, Map).

%% Add a key-value pair with an explicit dot. `add/3' is this with a
%% fresh local dot; a writer that must gossip the exact entry it stored
%% reads it back with `get_entry/2'.
-spec add_dot(term(), term(), dot(), ormap()) -> ormap().
add_dot(Key, Value, Dot, Map) ->
    DotHLC = dot_hlc(Dot),
    case maps:get(Key, Map, undefined) of
        undefined ->
            Map#{Key => {value, Value, #{Dot => true}}};
        {tombstone, T} ->
            case barrel_p2p_hlc:compare(DotHLC, T) of
                gt -> Map#{Key => {value, Value, #{Dot => true}}};
                _ -> Map
            end;
        {value, _OldValue, _Dots} ->
            Map#{Key => {value, Value, #{Dot => true}}}
    end.

%% Remove a key by writing a tombstone tagged with the current HLC.
%% A subsequent add with a strictly greater HLC wins; a stale
%% delayed add never resurrects this entry.
-spec remove(term(), ormap()) -> ormap().
remove(Key, Map) ->
    remove_at(Key, barrel_p2p_hlc:now(), Map).

%% Remove a key with a tombstone at an explicit HLC.
-spec remove_at(term(), barrel_p2p_hlc:timestamp(), ormap()) -> ormap().
remove_at(Key, HLC, Map) ->
    Map#{Key => {tombstone, HLC}}.

%% Get the live value for a key. Tombstones return not_found.
-spec get(term(), ormap()) -> {ok, term()} | not_found.
get(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        {value, Value, _Dots} -> {ok, Value};
        _ -> not_found
    end.

%% Get the full entry (live value or tombstone) for a key. Used by
%% callers that need to inspect dot history; ordinary lookups should
%% use get/2.
-spec get_entry(term(), ormap()) -> {ok, entry()} | not_found.
get_entry(Key, Map) ->
    case maps:get(Key, Map, undefined) of
        undefined -> not_found;
        Entry -> {ok, Entry}
    end.

%% Keys with live entries. Tombstones are not listed.
-spec keys(ormap()) -> [term()].
keys(Map) ->
    [K || {K, {value, _, _}} <- maps:to_list(Map)].

%% Live key-value pairs. Tombstones are skipped.
-spec to_list(ormap()) -> [{term(), term()}].
to_list(Map) ->
    [{K, V} || {K, {value, V, _Dots}} <- maps:to_list(Map)].

%% A map is empty when it has no live entries; tombstones do not
%% count. Do not use it to decide whether to send a full-sync snapshot:
%% a tombstone-only map still carries removes a peer may have missed.
-spec is_empty(ormap()) -> boolean().
is_empty(Map) ->
    lists:all(
        fun
            ({_K, {value, _, _}}) -> false;
            (_) -> true
        end,
        maps:to_list(Map)
    ).

%% Advance the local HLC from every dot and tombstone in an incoming
%% map, so a value merged from a peer cannot later be out-ranked by a
%% locally generated timestamp that is behind it. Callers that merge a
%% whole received map must call this BEFORE `merge/2'. Callers that
%% reject some entries (e.g. on a freshness/skew check) must filter
%% first and absorb only the accepted sub-map: `barrel_p2p_hlc:update/1'
%% accepts future timestamps, so absorbing a rejected far-future dot
%% would still move the clock forward.
-spec absorb_clock(ormap()) -> ok.
absorb_clock(Map) ->
    maps:foreach(
        fun
            (_Key, {value, _Val, Dots}) ->
                lists:foreach(
                    fun({_Node, HLC}) -> barrel_p2p_hlc:update(HLC) end,
                    maps:keys(Dots)
                );
            (_Key, {tombstone, HLC}) ->
                barrel_p2p_hlc:update(HLC)
        end,
        Map
    ),
    ok.

%% Drop tombstones whose wall-clock time is older than `CutoffWallMs'.
%% Live value entries are never touched. This bounds the map for
%% high-churn callers (e.g. reminders) where every remove leaves a
%% tombstone. It is a best-effort shrink, not a correctness operation: a
%% re-arriving tombstone is idempotent, and the cutoff must be chosen so
%% no add older than a dropped tombstone can still be in flight.
-spec gc_tombstones(ormap(), non_neg_integer()) -> ormap().
gc_tombstones(Map, CutoffWallMs) ->
    maps:filter(
        fun
            (_Key, {tombstone, HLC}) ->
                barrel_p2p_hlc:wall_time(HLC) >= CutoffWallMs;
            (_Key, _Value) ->
                true
        end,
        Map
    ).

%% Merge two OR-Maps. Commutative, associative, idempotent.
-spec merge(ormap(), ormap()) -> ormap().
merge(Map1, Map2) ->
    Keys = lists:usort(maps:keys(Map1) ++ maps:keys(Map2)),
    lists:foldl(
        fun(Key, Acc) ->
            Acc#{
                Key => merge_entry(
                    maps:get(Key, Map1, undefined),
                    maps:get(Key, Map2, undefined)
                )
            }
        end,
        #{},
        Keys
    ).

%%====================================================================
%% Internal
%%====================================================================

merge_entry(undefined, E) ->
    normalize(E);
merge_entry(E, undefined) ->
    normalize(E);
merge_entry({value, V1, D1}, {value, V2, D2}) ->
    %% Last-write-wins by the maximum dot, and the winner keeps only that
    %% dot. Compare the full dot ({Node, HLC}), not just the HLC: when two
    %% concurrent writes land on the same HLC (common on a single host, same
    %% millisecond) the node atom breaks the tie. That keeps the merge
    %% commutative, so every replica resolves the conflict to the same value
    %% instead of diverging on argument order.
    M1 = max_dot(D1),
    M2 = max_dot(D2),
    case dot_compare(M1, M2) of
        gt -> {value, V1, #{M1 => true}};
        _ -> {value, V2, #{M2 => true}}
    end;
merge_entry({tombstone, T1}, {tombstone, T2}) ->
    case barrel_p2p_hlc:compare(T1, T2) of
        gt -> {tombstone, T1};
        _ -> {tombstone, T2}
    end;
merge_entry({tombstone, T} = Tomb, {value, _, D} = V) ->
    case barrel_p2p_hlc:compare(T, max_hlc(D)) of
        gt -> Tomb;
        _ -> normalize(V)
    end;
merge_entry({value, _, D} = V, {tombstone, T} = Tomb) ->
    case barrel_p2p_hlc:compare(T, max_hlc(D)) of
        gt -> Tomb;
        _ -> normalize(V)
    end.

%% Reduce a value entry to its newest dot (entries from older nodes may
%% carry the full dot history).
normalize({value, V, Dots}) when map_size(Dots) > 1 ->
    {value, V, #{max_dot(Dots) => true}};
normalize(E) ->
    E.

dot_hlc({_Node, HLC}) -> HLC.

%% Total order on dots: HLC first, then the node atom as a deterministic
%% tiebreak so two writes with an equal HLC resolve identically on every
%% replica (the merge stays commutative).
dot_compare({Na, Ha}, {Nb, Hb}) ->
    case barrel_p2p_hlc:compare(Ha, Hb) of
        eq -> compare_node(Na, Nb);
        Other -> Other
    end.

compare_node(N, N) -> eq;
compare_node(Na, Nb) when Na > Nb -> gt;
compare_node(_, _) -> lt.

%% The greatest dot in a non-empty dot set, by dot_compare/2.
max_dot(Dots) ->
    [First | Rest] = maps:keys(Dots),
    lists:foldl(
        fun(Dot, Acc) ->
            case dot_compare(Dot, Acc) of
                gt -> Dot;
                _ -> Acc
            end
        end,
        First,
        Rest
    ).

%% Maximum HLC across a non-empty dot set.
max_hlc(Dots) ->
    [First | Rest] = maps:keys(Dots),
    lists:foldl(
        fun({_, HLC}, Acc) ->
            case barrel_p2p_hlc:compare(HLC, Acc) of
                gt -> HLC;
                _ -> Acc
            end
        end,
        dot_hlc(First),
        Rest
    ).
