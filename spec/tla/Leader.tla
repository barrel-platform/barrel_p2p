---------------------------- MODULE Leader ----------------------------
(***************************************************************************)
(* barrel_p2p_leader as coded, for one election name.                      *)
(*                                                                         *)
(* The candidate set rides the replica layer (spec/tla/ReplicaORMap.tla), *)
(* abstracted here to what it guarantees: every node eventually sees each *)
(* add and remove, in any order, and a remove beats an add (tombstone).   *)
(* The leader is the lowest node id among the candidates a node knows      *)
(* (equal priorities). A node that becomes leader mints a fence: its HLC   *)
(* after absorbing the known high-water mark, then `now()'. Fences are     *)
(* gossiped (broadcast_custom) and every node keeps the highest it saw.   *)
(*                                                                         *)
(* A fencing resource accepts a token only if it is the highest seen, so   *)
(* the leader must hold the highest fence ever minted, or its writes are  *)
(* refused once a higher token has been used.                              *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Nodes,          \* node ids, natural numbers (lowest wins)
    MaxClock,
    FixRemint       \* a leader that learns a higher fence mints above it
                    \*   (the code only raises the high-water mark)

VARIABLES
    cand,       \* node -> candidate -> "none" | "in" | "out"
    campaigned, \* nodes that called lead/1
    resigned,   \* nodes that resigned
    clock,      \* node -> HLC (a natural number)
    high,       \* node -> highest fence seen (0: none)
    mine,       \* node -> its fence while it believes it leads (0: none)
    minted,     \* every fence ever minted
    net         \* in-flight: [kind, from, to, cand, fence]

vars == <<cand, campaigned, resigned, clock, high, mine, minted, net>>

Max(a, b) == IF a > b THEN a ELSE b
SetMax(S) == IF S = {} THEN 0 ELSE CHOOSE x \in S : \A y \in S : y =< x

Known(n) == {c \in Nodes : cand[n][c] = "in"}

Msg(k, from, to, c, f) == [kind |-> k, from |-> from, to |-> to, cand |-> c, fence |-> f]
ToAll(k, from, c, f) == {Msg(k, from, m, c, f) : m \in Nodes \ {from}}

Init ==
    /\ cand = [n \in Nodes |-> [c \in Nodes |-> "none"]]
    /\ campaigned = {}
    /\ resigned = {}
    /\ clock = [n \in Nodes |-> 0]
    /\ high = [n \in Nodes |-> 0]
    /\ mine = [n \in Nodes |-> 0]
    /\ minted = {}
    /\ net = {}

\* recompute_name/2 at n after its candidate view changed: become leader
\* (mint) or be revoked. Returns the new [clock, high, mine, out, minted].
Recompute(n, C, Camp) ==
    LET known == {c \in Nodes : C[c] = "in"}
        lead == IF known = {} THEN 0 ELSE CHOOSE c \in known : \A d \in known : c =< d
        isSelf == n \in Camp /\ n \notin resigned /\ lead = n
    IN IF isSelf /\ mine[n] = 0 THEN
           LET f == Max(clock[n], high[n]) + 1 IN
           [clock |-> f, high |-> Max(high[n], f), mine |-> f,
            out |-> ToAll("fence", n, 0, f), minted |-> minted \cup {f}]
       ELSE IF ~isSelf /\ mine[n] # 0 THEN
           [clock |-> clock[n], high |-> high[n], mine |-> 0, out |-> {}, minted |-> minted]
       ELSE
           [clock |-> clock[n], high |-> high[n], mine |-> mine[n], out |-> {}, minted |-> minted]

Apply(n, C, r, extra) ==
    /\ cand' = [cand EXCEPT ![n] = C]
    /\ clock' = [clock EXCEPT ![n] = r.clock]
    /\ high' = [high EXCEPT ![n] = r.high]
    /\ mine' = [mine EXCEPT ![n] = r.mine]
    /\ minted' = r.minted
    /\ net' = net \cup r.out \cup extra

\* Wall clock advance.
Tick(n) ==
    /\ clock[n] < MaxClock
    /\ clock' = [clock EXCEPT ![n] = @ + 1]
    /\ UNCHANGED <<cand, campaigned, resigned, high, mine, minted, net>>

\* lead/1
Campaign(n) ==
    /\ n \notin campaigned
    /\ campaigned' = campaigned \cup {n}
    /\ LET C == [cand[n] EXCEPT ![n] = "in"]
           r == Recompute(n, C, campaigned \cup {n})
       IN Apply(n, C, r, ToAll("add", n, n, 0))
    /\ UNCHANGED resigned

\* resign/1
Resign(n) ==
    /\ n \in campaigned /\ n \notin resigned
    /\ resigned' = resigned \cup {n}
    /\ cand' = [cand EXCEPT ![n][n] = "out"]
    /\ mine' = [mine EXCEPT ![n] = 0]
    /\ net' = net \cup ToAll("remove", n, n, 0)
    /\ UNCHANGED <<campaigned, clock, high, minted>>

Deliver(m) ==
    /\ m \in net
    /\ LET n == m.to IN
       CASE m.kind \in {"add", "remove"} ->
            LET C == [cand[n] EXCEPT ![m.cand] =
                        IF m.kind = "remove" \/ @ = "out" THEN "out" ELSE "in"]
                r == Recompute(n, C, campaigned)
            IN /\ cand' = [cand EXCEPT ![n] = C]
               /\ clock' = [clock EXCEPT ![n] = r.clock]
               /\ high' = [high EXCEPT ![n] = r.high]
               /\ mine' = [mine EXCEPT ![n] = r.mine]
               /\ minted' = r.minted
               /\ net' = (net \ {m}) \cup r.out
         [] m.kind = "fence" ->
            \* merge_fence/2: absorb the clock, raise the high-water mark
            LET c1 == Max(clock[n], m.fence)
                h1 == Max(high[n], m.fence)
                remint == FixRemint /\ mine[n] # 0 /\ m.fence > mine[n]
                f == Max(c1, h1) + 1
            IN /\ clock' = [clock EXCEPT ![n] = IF remint THEN f ELSE c1]
               /\ high' = [high EXCEPT ![n] = IF remint THEN f ELSE h1]
               /\ mine' = [mine EXCEPT ![n] = IF remint THEN f ELSE @]
               /\ minted' = IF remint THEN minted \cup {f} ELSE minted
               /\ net' = (net \ {m}) \cup (IF remint THEN ToAll("fence", n, 0, f) ELSE {})
               /\ UNCHANGED cand
    /\ UNCHANGED <<campaigned, resigned>>

Next ==
    \/ \E n \in Nodes : Tick(n) \/ Campaign(n) \/ Resign(n)
    \/ \E m \in net : Deliver(m)

Spec == Init /\ [][Next]_vars

\* While two nodes both believe they lead, each re-mints above the other's
\* fence until the candidate updates reach them; bound that for TLC.
FenceBound == \A n \in Nodes : clock[n] =< MaxClock + 3

-----------------------------------------------------------------------------
Quiescent == net = {}

Live == campaigned \ resigned

\* Everyone agrees on the leader once everything is delivered.
AgreementAtQuiescence ==
    Quiescent => \A a, b \in Nodes : Known(a) = Known(b)

\* The agreed leader holds the highest fence ever minted.
LeaderHoldsMaxFence ==
    (Quiescent /\ Live # {}) =>
        LET l == CHOOSE c \in Live : \A d \in Live : c =< d
        IN mine[l] = SetMax(minted)

\* Fences grow: every minted fence is distinct (a node never re-issues a
\* fence another leader already used).
=============================================================================
