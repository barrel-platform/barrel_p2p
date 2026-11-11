%%% -*- erlang -*-
%%% Copyright (c) 2026 Benoit Chesneau
%%% SPDX-License-Identifier: Apache-2.0
%%%
%%% Multi-replica convergence of the barrel_p2p_replica write path,
%%% simulated over the real barrel_p2p_ormap (add_dot/4, remove_at/3,
%%% merge/2) and barrel_p2p_crdt_wire:accept/2.
%%%
%%% Each replica has an OR-Map, an HLC (an integer wall time) and a FIFO of
%%% broadcast casts its replica process has not handled yet. A writer
%%% stamps locally; flushing the queue turns a cast into a delta, either
%%% the stored entry (one stamp, the fixed path) or a freshly stamped
%%% entry (two stamps, the code before the fix). Deltas can be lost; a
%%% heal then runs full syncs, sending tombstone-only maps or not.
%%%
%%% The same scenarios are model-checked in spec/tla/ReplicaORMap.tla.

-module(barrel_p2p_replica_convergence_prop_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("hlc/include/hlc.hrl").
%% eunit and proper both define ?LET; proper's is the one we use here.
-undef('LET').
-include_lib("proper/include/proper.hrl").

-define(NUMTESTS, 2000).
-define(KEY, k).
-define(NODES, [n1, n2, n3]).

prop_test_() ->
    [
        {timeout, 300, ?_assert(run(prop_single_writer_intent_kept(fixed)))},
        {timeout, 300, ?_assert(run(prop_converges(fixed)))},
        {timeout, 300, ?_assert(run(prop_no_resurrection(fixed)))}
    ].

run(Prop) ->
    proper:quickcheck(Prop, [{numtests, ?NUMTESTS}, {to_file, user}]).

%% The TLA+ counterexamples (MC_registry_stamp, MC_*_snap), replayed: each
%% bug alone breaks the writer's intent, the fixed path keeps it. The
%% simulation never merges a node's own deltas back, like the registry; a
%% consumer that does was healed from the double stamp (see check.sh).
%% n1 puts then removes before its replica process runs; n2 receives the
%% add and then loses its link before the tombstone arrives.
counterexample_test_() ->
    Ops = [{add, n1, a}, {remove, n1}, {flush, n1}, {flush, n1}, {deliver, n2}, {cut, n2}],
    [
        ?_assertEqual(not_found, visible(n2, simulate(Ops, owner, fixed))),
        ?_assertEqual(not_found, visible(n2, simulate(Ops, full, fixed))),
        %% Double stamp: the heal repairs with the local T@2, older than
        %% the gossiped add@3, so n2 keeps the removed value.
        ?_assertEqual({ok, a}, visible(n2, simulate(Ops, owner, double_stamp))),
        %% Tombstone-only snapshot never sent: n2 is never told.
        ?_assertEqual({ok, a}, visible(n2, simulate(Ops, owner, skip_tombstone_snapshot))),
        ?_assertEqual({ok, a}, visible(n2, simulate(Ops, full, skip_tombstone_snapshot)))
    ].

%%====================================================================
%% Properties
%%====================================================================

%% One writer (n1) puts and removes; after any loss pattern and a heal,
%% every replica shows the writer's last operation. Covers the registry
%% and leader (one writer per key) and the common map pattern.
prop_single_writer_intent_kept(Mode) ->
    ?FORALL(
        {Ops, Sync},
        {ops(oneof([n1])), oneof([owner, full])},
        begin
            Final = simulate(Ops, Sync, Mode),
            Intent = intent(Ops),
            Views = [visible(N, Final) || N <- ?NODES],
            ?WHENFAIL(
                io:format("intent ~p views ~p~n", [Intent, Views]),
                lists:all(fun(V) -> V =:= Intent end, Views)
            )
        end
    ).

%% Several writers; after a heal with full syncs every replica holds the
%% same visible value (barrel_p2p_map with anti-entropy).
prop_converges(Mode) ->
    ?FORALL(
        Ops,
        ops(oneof(?NODES)),
        begin
            Final = simulate(Ops, full, Mode),
            Views = [visible(N, Final) || N <- ?NODES],
            ?WHENFAIL(
                io:format("views ~p~n", [Views]),
                length(lists:usort(Views)) =:= 1
            )
        end
    ).

%% No replica ever shows a value older than a tombstone it holds or held
%% (checked after every step, not only at the end).
prop_no_resurrection(Mode) ->
    ?FORALL(
        Ops,
        ops(oneof(?NODES)),
        begin
            {_Final, Ok} = lists:foldl(
                fun(Op, {S, Ok}) ->
                    S1 = step(Op, S, Mode),
                    {S1, Ok andalso no_stale_value(S1)}
                end,
                {init(), true},
                Ops
            ),
            Ok
        end
    ).

%%====================================================================
%% Generators
%%====================================================================

ops(Writer) ->
    list(
        frequency([
            {4, {add, Writer, oneof([a, b])}},
            {3, {remove, Writer}},
            {2, {tick, oneof(?NODES)}},
            {5, {flush, oneof(?NODES)}},
            {5, {deliver, oneof(?NODES)}},
            {2, {lose, oneof(?NODES)}},
            {1, {cut, oneof(?NODES)}}
        ])
    ).

%%====================================================================
%% Simulation
%%====================================================================

init() ->
    maps:from_list([
        {N, #{map => barrel_p2p_ormap:new(), clock => 0, queue => [], inbox => [], tomb => 0}}
     || N <- ?NODES
    ]).

simulate(Ops, Sync, Mode) ->
    S = lists:foldl(fun(Op, Acc) -> step(Op, Acc, Mode) end, init(), Ops),
    heal(drain(S, Mode), Sync, Mode).

step({add, N, V}, S, _Mode) ->
    #{map := M, clock := C, queue := Q} = R = maps:get(N, S),
    T = C + 1,
    M1 = barrel_p2p_ormap:add_dot(?KEY, V, {N, ts(T)}, M),
    S#{N => R#{map := M1, clock := T, queue := Q ++ [{add, V, entry(M1)}]}};
step({remove, N}, S, _Mode) ->
    #{map := M, clock := C, queue := Q} = R = maps:get(N, S),
    T = C + 1,
    M1 = barrel_p2p_ormap:remove_at(?KEY, ts(T), M),
    S1 = S#{N => R#{map := M1, clock := T, queue := Q ++ [{remove, entry(M1)}]}},
    note_tomb(N, S1);
step({tick, N}, S, _Mode) ->
    R = maps:get(N, S),
    S#{N => R#{clock := maps:get(clock, R) + 1}};
step({flush, N}, S, Mode) ->
    case maps:get(N, S) of
        #{queue := []} ->
            S;
        #{queue := [Cast | Rest], clock := C} = R ->
            {Entry, C1} = broadcast_entry(N, Cast, C, Mode),
            S1 = S#{N => R#{queue := Rest, clock := C1}},
            lists:foldl(
                fun(P, Acc) -> push(P, #{?KEY => Entry}, Acc) end,
                S1,
                ?NODES -- [N]
            )
    end;
step({deliver, N}, S, _Mode) ->
    case maps:get(N, S) of
        #{inbox := []} -> S;
        #{inbox := [D | Rest]} = R -> ingest(N, D, S#{N => R#{inbox := Rest}})
    end;
%% A partition: everything in flight to N is lost.
step({cut, N}, S, _Mode) ->
    R = maps:get(N, S),
    S#{N => R#{inbox := []}};
step({lose, N}, S, _Mode) ->
    case maps:get(N, S) of
        #{inbox := []} -> S;
        #{inbox := [_ | Rest]} = R -> S#{N => R#{inbox := Rest}}
    end.

%% The fixed path gossips the entry it stored; the old path minted a
%% second HLC in the replica process (barrel_p2p_replica handle_cast).
broadcast_entry(_N, {add, _V, Entry}, C, Mode) when Mode =/= double_stamp -> {Entry, C};
broadcast_entry(_N, {remove, Entry}, C, Mode) when Mode =/= double_stamp -> {Entry, C};
broadcast_entry(N, {add, V, _}, C, double_stamp) -> {{value, V, #{{N, ts(C + 1)} => true}}, C + 1};
broadcast_entry(_N, {remove, _}, C, double_stamp) -> {{tombstone, ts(C + 1)}, C + 1}.

%% Flush every queue, then deliver whatever is still in flight.
drain(S, Mode) ->
    S1 = lists:foldl(
        fun(N, Acc) -> flush_all(N, Acc, Mode) end,
        S,
        ?NODES
    ),
    lists:foldl(fun deliver_all/2, S1, ?NODES).

flush_all(N, S, Mode) ->
    case maps:get(queue, maps:get(N, S)) of
        [] -> S;
        _ -> flush_all(N, step({flush, N}, S, Mode), Mode)
    end.

deliver_all(N, S) ->
    case maps:get(inbox, maps:get(N, S)) of
        [] -> S;
        _ -> deliver_all(N, step({deliver, N}, S, fixed))
    end.

%% peer_up full sync after the partition. `owner': each node sends its
%% own keys (registry/leader send their local map; only n1 writes here).
%% `full': every node sends its whole map, repeated like anti-entropy.
heal(S, owner, Mode) ->
    sync_round(S, [{n1, P} || P <- ?NODES -- [n1]], owner, Mode);
heal(S, full, Mode) ->
    Pairs = [{A, B} || A <- ?NODES, B <- ?NODES, A =/= B],
    lists:foldl(fun(_, Acc) -> sync_round(Acc, Pairs, full, Mode) end, S, lists:seq(1, 3)).

sync_round(S, Pairs, Scope, Mode) ->
    lists:foldl(
        fun({From, To}, Acc) ->
            Snap = snapshot(From, Scope, Acc),
            case sendable(Snap, Mode) of
                true -> ingest(To, Snap, Acc);
                false -> Acc
            end
        end,
        S,
        Pairs
    ).

snapshot(N, owner, S) when N =:= n1 -> maps:get(map, maps:get(N, S));
snapshot(_N, owner, _S) -> #{};
snapshot(N, full, S) -> maps:get(map, maps:get(N, S)).

%% replica_full_sync_snapshot/1 used ormap:is_empty/1, which ignores
%% tombstones, so a map holding only tombstones was never sent.
sendable(Snap, skip_tombstone_snapshot) -> not barrel_p2p_ormap:is_empty(Snap);
sendable(Snap, _Mode) -> map_size(Snap) > 0.

push(N, Delta, S) ->
    R = maps:get(N, S),
    S#{N => R#{inbox := maps:get(inbox, R) ++ [Delta]}}.

ingest(N, Incoming, S) ->
    #{map := M, clock := C} = R = maps:get(N, S),
    Accepted = barrel_p2p_crdt_wire:accept(Incoming, fun(_) -> true end),
    note_tomb(N, S#{
        N => R#{
            map := barrel_p2p_ormap:merge(M, Accepted),
            clock := max(C, map_clock(Accepted))
        }
    }).

%%====================================================================
%% Helpers
%%====================================================================

ts(T) -> #timestamp{wall_time = T, logical = 0}.

entry(M) ->
    {ok, E} = barrel_p2p_ormap:get_entry(?KEY, M),
    E.

map_clock(M) ->
    lists:max([0 | [entry_wall(E) || E <- maps:values(M)]]).

entry_wall({tombstone, #timestamp{wall_time = W}}) -> W;
entry_wall({value, _, Dots}) -> lists:max([W || {_, #timestamp{wall_time = W}} <- maps:keys(Dots)]).

note_tomb(N, S) ->
    R = maps:get(N, S),
    case barrel_p2p_ormap:get_entry(?KEY, maps:get(map, R)) of
        {ok, {tombstone, #timestamp{wall_time = W}}} ->
            S#{N => R#{tomb := max(W, maps:get(tomb, R))}};
        _ ->
            S
    end.

no_stale_value(S) ->
    lists:all(
        fun(N) ->
            #{map := M, tomb := T} = maps:get(N, S),
            case barrel_p2p_ormap:get_entry(?KEY, M) of
                {ok, {value, _, _} = E} -> entry_wall(E) >= T;
                _ -> true
            end
        end,
        ?NODES
    ).

visible(N, S) ->
    barrel_p2p_ormap:get(?KEY, maps:get(map, maps:get(N, S))).

%% The writer's last operation: its last add's value, or not_found.
intent(Ops) ->
    lists:foldl(
        fun
            ({add, _, V}, _) -> {ok, V};
            ({remove, _}, _) -> not_found;
            (_, Acc) -> Acc
        end,
        not_found,
        Ops
    ).
