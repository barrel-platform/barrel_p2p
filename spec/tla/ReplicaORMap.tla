---------------------------- MODULE ReplicaORMap ----------------------------
(***************************************************************************)
(* barrel_p2p_replica driving a gossiped barrel_p2p_ormap, modelled from   *)
(* the code (not an idealised CRDT).                                       *)
(*                                                                         *)
(* Per node: one OR-Map, one HLC (shared by the owner process and the      *)
(* replica process, like the barrel_p2p_hlc server), and a FIFO queue of   *)
(* broadcast casts the replica process has not handled yet. The owner      *)
(* stamps a write locally; the replica process later turns the queued      *)
(* cast into a delta (barrel_p2p_replica:handle_cast/2).                   *)
(*                                                                         *)
(* Network: deltas ride Plumtree, so they reach any node connected to the  *)
(* sender through the HyParView links (one relay hop is enough for 3      *)
(* nodes); a delta with no path can be lost. Full-sync snapshots are       *)
(* direct dist messages and need a direct link. Taking a link down drops   *)
(* what is in flight on it.                                                *)
(*                                                                         *)
(* A run ends with Heal: every link comes up (peer_up full sync on the     *)
(* links that were down), queued casts drain, messages are delivered, and  *)
(* anti-entropy runs when the consumer has it. QuiescentConverged then     *)
(* asks that every node shows the same visible map.                       *)
(***************************************************************************)
EXTENDS ORMapMerge, Naturals, FiniteSets, Sequences

CONSTANTS
    Nodes,          \* node ids, natural numbers (the dot tiebreak)
    Keys,
    Values,
    MaxClock,       \* bound on HLC values minted by writes and ticks
    MaxWrites,      \* bound on local writes in a behaviour
    MaxFlips,       \* bound on links taken down
    SingleWriter,   \* TRUE: each key has one writer, as in the registry
                    \*   and leader (key = {Name, node()})
    OwnOnlySnapshot,\* TRUE: a full sync sends only the sender's own keys
                    \*   (registry/leader send their local map)
    PruneMode,      \* "none" | "owner" (registry: drop the downed node's
                    \*   keys) | "dots" (map: drop values all of whose dots
                    \*   are the downed node's)
    AE,             \* periodic anti-entropy (map, reminder)
    SingleStamp,    \* TRUE: the delta is the entry stored locally
                    \*   (barrel_p2p_replica:broadcast_entry/3). FALSE: the
                    \*   0.1.x code, broadcast_update/2 minted a second HLC.
    SendTombstones  \* TRUE: any non-empty map is sent (map_size > 0).
                    \*   FALSE: the 0.1.x code, a snapshot with no live value
                    \*   was not sent (ormap:is_empty/1 ignores tombstones).

ASSUME Nodes \subseteq Nat /\ Cardinality(Nodes) =< 3
ASSUME PruneMode \in {"none", "owner", "dots"}

VARIABLES
    map,        \* node -> key -> entry
    clock,      \* node -> HLC
    queue,      \* node -> FIFO of queued broadcast casts
    msgs,       \* in-flight messages
    link,       \* node -> node -> BOOLEAN (symmetric HyParView link)
    phase,      \* "run" | "heal"
    writes,     \* writes so far
    flips,      \* links taken down so far
    aeDone,     \* anti-entropy pulls done since the last change (heal)
    seenTomb,   \* history: node -> key -> greatest tombstone time held
    intent      \* history: key -> [w: writers, last: last value written
                \*   or "none" after a remove]

vars == <<map, clock, queue, msgs, link, phase, writes, flips, aeDone, seenTomb, intent>>

Pairs == {p \in Nodes \X Nodes : p[1] # p[2]}
Owner(k) == CHOOSE n \in Nodes : \A m \in Nodes : n =< m
Max2(a, b) == IF a > b THEN a ELSE b
EmptyMap == [k \in Keys |-> None]
Delta(k, e) == [k2 \in Keys |-> IF k2 = k THEN e ELSE None]

MergeMap(m1, m2) == [k \in Keys |-> MergeEntry(m1[k], m2[k])]

MapClock(m) ==
    LET ts == {TsOf(m[k]) : k \in Keys} IN
        CHOOSE t \in ts : \A u \in ts : u =< t

Visible(n) == [k \in Keys |-> IF map[n][k].t = "v" THEN map[n][k].v ELSE "none"]

Snapshot(n) ==
    IF OwnOnlySnapshot
        THEN [k \in Keys |-> IF Owner(k) = n THEN map[n][k] ELSE None]
        ELSE map[n]

\* replica_full_sync_snapshot/1: `empty' unless the map has something to
\* send. Today's code uses ormap:is_empty/1, which ignores tombstones.
Sendable(m) ==
    IF SendTombstones
        THEN \E k \in Keys : m[k].t # "none"
        ELSE \E k \in Keys : m[k].t = "v"

Connected(a, b) ==
    link[a][b] \/ \E c \in Nodes : link[a][c] /\ link[c][b]

Deliverable(msg) ==
    IF msg.kind = "delta" THEN Connected(msg.from, msg.to)
    ELSE link[msg.from][msg.to]

SnapMsg(from, to) == [kind |-> "snap", from |-> from, to |-> to, m |-> Snapshot(from)]

SnapMsgs(ps) == {SnapMsg(p[1], p[2]) : p \in {q \in ps : Sendable(Snapshot(q[1]))}}

\* Merge an incoming map at node n (crdt_wire:ingest/3: absorb the clock,
\* then merge). Returns the updated records for map, clock and seenTomb.
Ingest(n, m) ==
    /\ map' = [map EXCEPT ![n] = MergeMap(map[n], m)]
    /\ clock' = [clock EXCEPT ![n] = Max2(clock[n], MapClock(m))]
    /\ seenTomb' = [seenTomb EXCEPT ![n] =
            [k \in Keys |-> IF MergeMap(map[n], m)[k].t = "x"
                                THEN Max2(seenTomb[n][k], MergeMap(map[n], m)[k].ts)
                                ELSE seenTomb[n][k]]]

-----------------------------------------------------------------------------
Init ==
    /\ map = [n \in Nodes |-> EmptyMap]
    /\ clock = [n \in Nodes |-> 0]
    /\ queue = [n \in Nodes |-> <<>>]
    /\ msgs = {}
    /\ link = [a \in Nodes |-> [b \in Nodes |-> a # b]]
    /\ phase = "run"
    /\ writes = 0
    /\ flips = 0
    /\ aeDone = {}
    /\ seenTomb = [n \in Nodes |-> [k \in Keys |-> 0]]
    /\ intent = [k \in Keys |-> [w |-> {}, last |-> "none"]]

CanWrite(n, k) == ~SingleWriter \/ Owner(k) = n

\* Wall clock advance between events.
Tick(n) ==
    /\ phase = "run"
    /\ clock[n] < MaxClock
    /\ clock' = [clock EXCEPT ![n] = clock[n] + 1]
    /\ UNCHANGED <<map, queue, msgs, link, phase, writes, flips, aeDone, seenTomb, intent>>

\* barrel_p2p_ormap:add/3 in the owner, then the broadcast cast.
\* Single-writer consumers only add when not already registered.
LocalAdd(n, k, v) ==
    /\ phase = "run"
    /\ writes < MaxWrites
    /\ clock[n] < MaxClock
    /\ CanWrite(n, k)
    /\ SingleWriter => map[n][k].t # "v"
    /\ LET t == clock[n] + 1
           dot == <<n, t>>
           old == map[n][k]
           new == IF old.t = "none" THEN Val(v, {dot})
                  ELSE IF old.t = "x" THEN (IF t > old.ts THEN Val(v, {dot}) ELSE old)
                  ELSE Val(v, {dot})
       IN /\ map' = [map EXCEPT ![n][k] = new]
          /\ clock' = [clock EXCEPT ![n] = t]
          /\ queue' = [queue EXCEPT ![n] = Append(@, [op |-> "add", k |-> k, v |-> v, e |-> new])]
    /\ writes' = writes + 1
    /\ intent' = [intent EXCEPT ![k] = [w |-> @.w \cup {n}, last |-> v]]
    /\ UNCHANGED <<msgs, link, phase, flips, aeDone, seenTomb>>

\* barrel_p2p_ormap:remove/2 in the owner, then the broadcast cast.
LocalRemove(n, k) ==
    /\ phase = "run"
    /\ writes < MaxWrites
    /\ clock[n] < MaxClock
    /\ CanWrite(n, k)
    /\ map[n][k].t = "v"
    /\ LET t == clock[n] + 1 IN
        /\ map' = [map EXCEPT ![n][k] = Tomb(t)]
        /\ clock' = [clock EXCEPT ![n] = t]
        /\ queue' = [queue EXCEPT ![n] = Append(@, [op |-> "remove", k |-> k, v |-> "", e |-> Tomb(t)])]
        /\ seenTomb' = [seenTomb EXCEPT ![n][k] = Max2(@, t)]
    /\ writes' = writes + 1
    /\ intent' = [intent EXCEPT ![k] = [w |-> @.w \cup {n}, last |-> "none"]]
    /\ UNCHANGED <<msgs, link, phase, flips, aeDone>>

\* The replica process handles the oldest queued cast and broadcasts it.
Broadcast(n) ==
    /\ queue[n] # <<>>
    /\ LET c == Head(queue[n])
           t == clock[n] + 1
           e == IF SingleStamp THEN c.e
                ELSE IF c.op = "add" THEN Val(c.v, {<<n, t>>}) ELSE Tomb(t)
       IN /\ clock' = IF SingleStamp THEN clock ELSE [clock EXCEPT ![n] = t]
          /\ msgs' = msgs \cup
                {[kind |-> "delta", from |-> n, to |-> m, m |-> Delta(c.k, e)] : m \in Nodes \ {n}}
    /\ queue' = [queue EXCEPT ![n] = Tail(@)]
    /\ UNCHANGED <<map, link, phase, writes, flips, aeDone, seenTomb, intent>>

\* A message arrives: replica_merge_delta / replica_apply_full_sync.
Deliver(msg) ==
    /\ msg \in msgs
    /\ Deliverable(msg)
    /\ msgs' = msgs \ {msg}
    /\ Ingest(msg.to, msg.m)
    /\ aeDone' = IF MergeMap(map[msg.to], msg.m) # map[msg.to] THEN {} ELSE aeDone
    /\ UNCHANGED <<queue, link, phase, writes, flips, intent>>

\* A Plumtree delta with no path to its target is lost.
Lose(msg) ==
    /\ phase = "run"
    /\ msg \in msgs
    /\ ~Deliverable(msg)
    /\ msgs' = msgs \ {msg}
    /\ UNCHANGED <<map, clock, queue, link, phase, writes, flips, aeDone, seenTomb, intent>>

PruneMap(m, gone) ==
    [k \in Keys |->
        CASE PruneMode = "owner" /\ Owner(k) = gone -> None
          [] PruneMode = "dots" /\ m[k].t = "v" /\ \A d \in m[k].d : d[1] = gone -> None
          [] OTHER -> m[k]]

\* peer_down on both ends: drop in-flight traffic on the link and prune.
LinkDown(a, b) ==
    /\ phase = "run"
    /\ a < b
    /\ link[a][b]
    /\ flips < MaxFlips
    /\ link' = [link EXCEPT ![a][b] = FALSE, ![b][a] = FALSE]
    /\ msgs' = {msg \in msgs : {msg.from, msg.to} # {a, b}}
    /\ map' = [map EXCEPT ![a] = PruneMap(@, b), ![b] = PruneMap(@, a)]
    \* A prune forgets the key on purpose; so does its tombstone history.
    /\ seenTomb' = [n \in Nodes |-> [k \in Keys |->
            IF n \in {a, b} /\ map'[n][k].t = "none" THEN 0 ELSE seenTomb[n][k]]]
    /\ flips' = flips + 1
    /\ UNCHANGED <<clock, queue, phase, writes, aeDone, intent>>

\* peer_up on both ends: each side pushes its snapshot (do_full_sync).
LinkUp(a, b) ==
    /\ phase = "run"
    /\ a < b
    /\ ~link[a][b]
    /\ link' = [link EXCEPT ![a][b] = TRUE, ![b][a] = TRUE]
    /\ msgs' = msgs \cup SnapMsgs({<<a, b>>, <<b, a>>})
    /\ UNCHANGED <<map, clock, queue, phase, writes, flips, aeDone, seenTomb, intent>>

\* End of the faulty run: all links up, peer_up sync on the ones that were down.
Heal ==
    /\ phase = "run"
    /\ phase' = "heal"
    /\ link' = [a \in Nodes |-> [b \in Nodes |-> a # b]]
    /\ msgs' = msgs \cup SnapMsgs({p \in Pairs : ~link[p[1]][p[2]]})
    /\ UNCHANGED <<map, clock, queue, writes, flips, aeDone, seenTomb, intent>>

\* Anti-entropy: a pulls b's snapshot (request_sync). Modelled once the
\* network is idle, and repeated until a full round changes nothing.
AntiEntropy(a, b) ==
    /\ AE
    /\ phase = "heal"
    /\ msgs = {}
    /\ \A n \in Nodes : queue[n] = <<>>
    /\ <<a, b>> \in Pairs \ aeDone
    /\ aeDone' = aeDone \cup {<<a, b>>}
    /\ msgs' = msgs \cup SnapMsgs({<<b, a>>})
    /\ UNCHANGED <<map, clock, queue, link, phase, writes, flips, seenTomb, intent>>

Next ==
    \/ \E n \in Nodes : Tick(n) \/ Broadcast(n)
    \/ \E n \in Nodes, k \in Keys, v \in Values : LocalAdd(n, k, v)
    \/ \E n \in Nodes, k \in Keys : LocalRemove(n, k)
    \/ \E msg \in msgs : Deliver(msg) \/ Lose(msg)
    \/ \E a, b \in Nodes : LinkDown(a, b) \/ LinkUp(a, b) \/ AntiEntropy(a, b)
    \/ Heal

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* Invariants

TypeOK ==
    /\ phase \in {"run", "heal"}
    /\ \A n \in Nodes : clock[n] \in Nat /\ \A k \in Keys : map[n][k].t \in {"none", "v", "x"}
    /\ writes =< MaxWrites /\ flips =< MaxFlips

\* A visible value never carries an HLC older than a tombstone the node
\* already held for that key: a stale add cannot resurrect a remove.
NoResurrection ==
    \A n \in Nodes, k \in Keys :
        map[n][k].t = "v" => MaxHlc(map[n][k].d) >= seenTomb[n][k]

Quiescent ==
    /\ phase = "heal"
    /\ msgs = {}
    /\ \A n \in Nodes : queue[n] = <<>>
    /\ AE => aeDone = Pairs

Converged == \A a, b \in Nodes : Visible(a) = Visible(b)

QuiescentConverged == Quiescent => Converged

\* A key with a single writer ends where that writer left it: its later
\* operations always beat its earlier ones, on every node. (With several
\* concurrent writers the LWW winner is arbitrary, so only convergence is
\* asked of them.)
WriterIntentKept ==
    Quiescent =>
        \A k \in Keys :
            Cardinality(intent[k].w) = 1 => \A n \in Nodes : Visible(n)[k] = intent[k].last
=============================================================================
