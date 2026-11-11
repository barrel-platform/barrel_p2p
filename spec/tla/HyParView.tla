---------------------------- MODULE HyParView ----------------------------
(***************************************************************************)
(* barrel_p2p_hyparview + barrel_p2p_bridge as coded.                      *)
(*                                                                         *)
(* Dist channels (`chan') are separate from the views: a HyParView         *)
(* disconnect leaves the channel up, and channels can drop on their own.   *)
(* Protocol messages use `noconnect': sent without a channel they vanish.  *)
(*                                                                         *)
(* Everything a node's HyParView server handles goes through its bridge   *)
(* process, so it is one FIFO per node (`inbox'): peer_connected (at once *)
(* when the channel already exists, after a dial otherwise, and only to   *)
(* the node that asked), peer_failed (both ends of a dropped channel),    *)
(* and arriving protocol messages.                                        *)
(*                                                                         *)
(* `up' is what each node's event subscribers (Plumtree, the replicas)    *)
(* believe the active view is, folded from peer_up / peer_down.           *)
(*                                                                         *)
(* Shuffle only refreshes passive views and is left out. Choices the code *)
(* makes at random (eviction victim, forward target, promotion candidate) *)
(* are nondeterministic here, a superset of what the code does.           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    Nodes,
    Seed,           \* the first node, already up
    ActiveSize,
    PassiveSize,
    ARWL,
    PRWL,
    MaxFaults,      \* failed dials, channel drops, crashes and leaves
    MaxMsgs,
    FixAcceptLink,  \* the dialer of an accepted forward-join tells the new
                    \*   peer, so the link exists on both ends
    FixLeaveEvents, \* leave emits peer_down for every active peer
    FixLeftRefuses  \* a node that left refuses NEIGHBOR and ignores JOIN,
                    \*   FORWARD_JOIN, connection reports and late replies;
                    \*   a refusal from an active peer drops the link

None == "none"

VARIABLES
    alive, joined,
    chan,           \* set of {a, b}: dist channel up
    dialing,        \* set of <<a, b>>: a's bridge is dialing b
    net,            \* <<from, to>> -> FIFO of protocol messages on the wire
                    \*   (dist delivers messages between two nodes in order)
    inbox,          \* node -> FIFO of bridge casts and arrived messages
    active, passive,
    pending,        \* node -> node -> None | "join" | "connect" | "nb_high" | "nb_low"
    up,             \* node -> event-derived view
    left,           \* nodes that called leave/0 (still running)
    faults

vars == <<alive, joined, chan, dialing, net, inbox, active, passive, pending, up, left, faults>>

Msg(t, from, to, prio, ttl, peer, acc) ==
    [type |-> t, from |-> from, to |-> to, prio |-> prio, ttl |-> ttl, peer |-> peer, acc |-> acc]

\* Bridge casts to n about peer t.
Cast(kind, n, t) == Msg(kind, t, n, None, 0, t, FALSE)

Chan(a, b) == {a, b} \in chan

\* barrel_p2p_protocol:send/2 with [noconnect].
Send(m) == IF Chan(m.from, m.to) THEN {m} ELSE {}

Pick(S) == CHOOSE x \in S : TRUE

Push(q, n, m) == [q EXCEPT ![n] = Append(@, m)]

Pairs == Nodes \X Nodes

\* Put messages on the wire. A handler sends at most one message per
\* channel, so the order within a step does not matter.
SendAll(w, S) ==
    [p \in Pairs |->
        IF \E m \in S : <<m.from, m.to>> = p
        THEN Append(w[p], CHOOSE m \in S : <<m.from, m.to>> = p)
        ELSE w[p]]

NetEmpty(w) == \A p \in Pairs : w[p] = <<>>

\* barrel_p2p_bridge:request_connect/1: an existing channel is reported at
\* once, otherwise the bridge dials.
RequestConnect(n, t, q, d) ==
    IF Chan(n, t) THEN [q |-> Push(q, n, Cast("pc", n, t)), d |-> d]
    ELSE [q |-> q, d |-> d \cup {<<n, t>>}]

\* add_to_passive/3: bounded, never self. A full passive view drops an
\* arbitrary member to make room.
AddPassive(n, p, P) ==
    IF p = n \/ p \in P THEN P
    ELSE IF Cardinality(P) < PassiveSize THEN P \cup {p}
    ELSE (P \ {Pick(P)}) \cup {p}

\* activate/2 + add_to_active_view/2: add p, evicting a member when full.
\* Returns n's new active, passive and up, and messages to send.
AddActive(n, p, A, P, U) ==
    IF p = n \/ p \in A THEN [a |-> A, p |-> P, u |-> U, out |-> {}]
    ELSE IF Cardinality(A) < ActiveSize
        THEN [a |-> A \cup {p}, p |-> P, u |-> U \cup {p}, out |-> {}]
    ELSE LET v == Pick(A) IN
         [a |-> (A \ {v}) \cup {p},
          p |-> AddPassive(n, v, P),
          u |-> (U \ {v}) \cup {p},
          out |-> Send(Msg("disconnect", n, v, None, 0, n, FALSE))]

\* maybe_promote_passive/1: below target, take a passive peer and dial it.
Promote(n, A, P, Pend, q, d) ==
    IF Cardinality(A) < ActiveSize /\ P # {}
    THEN LET c == Pick(P)
             r == RequestConnect(n, c, q, d)
         IN [p |-> P \ {c},
             pend |-> [Pend EXCEPT ![c] = IF A = {} THEN "nb_high" ELSE "nb_low"],
             q |-> r.q, d |-> r.d]
    ELSE [p |-> P, pend |-> Pend, q |-> q, d |-> d]

-----------------------------------------------------------------------------
Init ==
    /\ alive = Nodes
    /\ joined = {Seed}
    /\ chan = {}
    /\ dialing = {}
    /\ net = [p \in Pairs |-> <<>>]
    /\ inbox = [n \in Nodes |-> <<>>]
    /\ active = [n \in Nodes |-> {}]
    /\ passive = [n \in Nodes |-> {}]
    /\ pending = [n \in Nodes |-> [m \in Nodes |-> None]]
    /\ up = [n \in Nodes |-> {}]
    /\ left = {}
    /\ faults = 0

\* barrel_p2p:join/1 from a node not yet in the overlay, via a joined contact.
Join(n, c) ==
    /\ n \in alive /\ (n \notin joined \/ n \in left)
    /\ c \in (joined \cap alive) \ left /\ c # n
    /\ joined' = joined \cup {n}
    /\ left' = left \ {n}
    /\ pending' = [pending EXCEPT ![n][c] = "join"]
    /\ LET r == RequestConnect(n, c, inbox, dialing) IN inbox' = r.q /\ dialing' = r.d
    /\ UNCHANGED <<alive, chan, net, active, passive, up, faults>>

\* The bridge's dial completes: the channel is up, only the dialer is told.
DialOk(a, b) ==
    /\ <<a, b>> \in dialing /\ b \in alive
    /\ dialing' = dialing \ {<<a, b>>}
    /\ chan' = chan \cup {{a, b}}
    /\ inbox' = Push(inbox, a, Cast("pc", a, b))
    /\ UNCHANGED <<alive, joined, net, active, passive, pending, up, faults, left>>

\* A dial to a live node fails only as a fault; a dial to a dead one always does.
DialFail(a, b) ==
    /\ <<a, b>> \in dialing
    /\ b \in alive => faults < MaxFaults
    /\ dialing' = dialing \ {<<a, b>>}
    /\ inbox' = Push(inbox, a, Cast("pf", a, b))
    /\ faults' = IF b \in alive THEN faults + 1 ELSE faults
    /\ UNCHANGED <<alive, joined, chan, net, active, passive, pending, up, left>>

\* A channel drops (network, idle GC): both bridges see nodedown. Messages on
\* the wire between the two are lost.
ChanDown(a, b) ==
    /\ {a, b} \in chan /\ faults < MaxFaults
    /\ chan' = chan \ {{a, b}}
    /\ inbox' = [n \in Nodes |->
            IF n = a /\ a \in alive THEN Append(inbox[n], Cast("pf", a, b))
            ELSE IF n = b /\ b \in alive THEN Append(inbox[n], Cast("pf", b, a))
            ELSE inbox[n]]
    /\ net' = [net EXCEPT ![<<a, b>>] = <<>>, ![<<b, a>>] = <<>>]
    /\ faults' = faults + 1
    /\ UNCHANGED <<alive, joined, dialing, active, passive, pending, up, left>>

Crash(n) ==
    /\ n \in alive /\ n # Seed /\ faults < MaxFaults
    /\ alive' = alive \ {n}
    /\ chan' = {c \in chan : n \notin c}
    /\ inbox' = [x \in Nodes |->
            IF x = n THEN <<>>
            ELSE IF x \in alive /\ {x, n} \in chan THEN Append(inbox[x], Cast("pf", x, n))
            ELSE inbox[x]]
    /\ net' = [p \in Pairs |-> IF n \in {p[1], p[2]} THEN <<>> ELSE net[p]]
    /\ dialing' = {d \in dialing : d[1] # n}
    /\ faults' = faults + 1
    /\ UNCHANGED <<joined, active, passive, pending, up, left>>

\* barrel_p2p:leave/0: disconnect every active peer and clear both views.
\* The node then takes no further part (its channels stay up).
Leave(n) ==
    /\ n \in alive /\ n \in joined /\ n \notin left /\ n # Seed /\ faults < MaxFaults
    /\ net' = SendAll(net, UNION {Send(Msg("disconnect", n, x, None, 0, n, FALSE)) : x \in active[n]})
    /\ active' = [active EXCEPT ![n] = {}]
    /\ passive' = [passive EXCEPT ![n] = {}]
    /\ up' = IF FixLeaveEvents THEN [up EXCEPT ![n] = {}] ELSE up
    /\ pending' = [pending EXCEPT ![n] = [m \in Nodes |-> None]]
    /\ left' = left \cup {n}
    /\ faults' = faults + 1
    /\ UNCHANGED <<alive, joined, chan, dialing, inbox>>

\* The oldest message on a channel reaches its node's bridge, queued behind
\* earlier casts.
Arrive(a, b) ==
    /\ net[<<a, b>>] # <<>>
    /\ LET m == Head(net[<<a, b>>]) IN
       /\ net' = [net EXCEPT ![<<a, b>>] = Tail(@)]
       /\ inbox' = IF b \in alive THEN Push(inbox, b, m) ELSE inbox
    /\ UNCHANGED <<alive, joined, chan, dialing, active, passive, pending, up, faults, left>>

-----------------------------------------------------------------------------
(* Handlers: node n takes the oldest entry of its inbox. `q' is the inbox *)
(* with that entry removed; handlers that dial or promote extend it.      *)

\* A node that left: ignore, or refuse a NEIGHBOR.
HandleLeft(n) ==
    /\ n \in alive /\ inbox[n] # <<>>
    /\ LET m == Head(inbox[n]) IN
       /\ FixLeftRefuses /\ n \in left
       /\ m.type \in {"pc", "join", "forward_join", "neighbor_reply", "neighbor"}
       /\ inbox' = [inbox EXCEPT ![n] = Tail(@)]
       /\ net' = CASE m.type = "neighbor" ->
                      SendAll(net, Send(Msg("neighbor_reply", n, m.from, None, 0, n, FALSE)))
                   [] m.type = "join" ->
                      \* the joiner already added us: tell it to drop the link
                      SendAll(net, Send(Msg("disconnect", n, m.from, None, 0, n, FALSE)))
                   [] OTHER -> net
    /\ UNCHANGED <<alive, joined, chan, dialing, active, passive, pending, up, left, faults>>

Handle(n) ==
    /\ n \in alive /\ inbox[n] # <<>>
    /\ ~(FixLeftRefuses /\ n \in left /\ Head(inbox[n]).type \in {"pc", "join", "forward_join", "neighbor_reply", "neighbor"})
    /\ LET m == Head(inbox[n])
           s == m.from
           q == [inbox EXCEPT ![n] = Tail(@)]
       IN
       CASE m.type = "pc" ->
            \* peer_connected/2
            LET k == pending[n][s] IN
            IF k \in {"nb_high", "nb_low"} THEN
                \* send NEIGHBOR now that the channel is up; stay pending
                /\ net' = SendAll(net, Send(Msg("neighbor", n, s, IF k = "nb_high" THEN "high" ELSE "low", 0, n, FALSE)))
                /\ inbox' = q
                /\ UNCHANGED <<active, passive, pending, up, dialing, left>>
            ELSE IF k = None /\ FixLeftRefuses THEN
                \* a stale report (timed out, or cleared by leave): ignore
                /\ inbox' = q
                /\ UNCHANGED <<active, passive, pending, up, dialing, net, left>>
            ELSE
                LET r == AddActive(n, s, active[n], passive[n], up[n])
                    extra ==
                        CASE k = "join" -> Send(Msg("join", n, s, None, 0, n, FALSE))
                          [] k = "connect" /\ FixAcceptLink -> Send(Msg("neighbor", n, s, "high", 0, n, FALSE))
                          [] OTHER -> {}
                IN /\ active' = [active EXCEPT ![n] = r.a]
                   /\ passive' = [passive EXCEPT ![n] = r.p]
                   /\ up' = [up EXCEPT ![n] = r.u]
                   /\ pending' = [pending EXCEPT ![n][s] = None]
                   /\ net' = SendAll(net, r.out \cup extra)
                   /\ inbox' = q
                   /\ UNCHANGED <<dialing, left>>
         [] m.type = "pf" ->
            \* peer_failed/2 (handle_peer_removal/4, failed)
            IF s \in active[n] THEN
                LET A == active[n] \ {s}
                    r == Promote(n, A, passive[n], pending[n], q, dialing)
                IN /\ active' = [active EXCEPT ![n] = A]
                   /\ up' = [up EXCEPT ![n] = @ \ {s}]
                   /\ passive' = [passive EXCEPT ![n] = r.p]
                   /\ pending' = [pending EXCEPT ![n] = r.pend]
                   /\ inbox' = r.q /\ dialing' = r.d
                   /\ UNCHANGED net
            ELSE IF pending[n][s] \in {"nb_high", "nb_low"} THEN
                LET r == Promote(n, active[n], passive[n], [pending[n] EXCEPT ![s] = None], q, dialing)
                IN /\ passive' = [passive EXCEPT ![n] = r.p]
                   /\ pending' = [pending EXCEPT ![n] = r.pend]
                   /\ inbox' = r.q /\ dialing' = r.d
                   /\ UNCHANGED <<active, up, net, left>>
            ELSE
                /\ pending' = [pending EXCEPT ![n][s] = None]
                /\ inbox' = q
                /\ UNCHANGED <<active, passive, up, dialing, net, left>>
         [] m.type = "join" ->
            \* handle_join/2: add the sender, forward to every other active peer
            LET r == AddActive(n, s, active[n], passive[n], up[n])
                fwd == UNION {Send(Msg("forward_join", n, x, None, ARWL, s, FALSE)) : x \in r.a \ {s}}
            IN /\ active' = [active EXCEPT ![n] = r.a]
               /\ passive' = [passive EXCEPT ![n] = r.p]
               /\ up' = [up EXCEPT ![n] = r.u]
               /\ net' = SendAll(net, r.out \cup fwd)
               /\ inbox' = q
               /\ UNCHANGED <<pending, dialing, left>>
         [] m.type = "forward_join" ->
            LET np == m.peer IN
            IF np = n THEN
                /\ inbox' = q
                /\ UNCHANGED <<active, passive, up, pending, dialing, net, left>>
            ELSE IF m.ttl = 0 THEN
                /\ passive' = [passive EXCEPT ![n] = AddPassive(n, np, @)]
                /\ inbox' = q
                /\ UNCHANGED <<active, up, pending, dialing, net, left>>
            ELSE
                LET P1 == IF m.ttl = PRWL THEN AddPassive(n, np, passive[n]) ELSE passive[n] IN
                IF Cardinality(active[n]) < ActiveSize THEN
                    LET r == RequestConnect(n, np, q, dialing) IN
                    /\ passive' = [passive EXCEPT ![n] = P1]
                    /\ pending' = [pending EXCEPT ![n][np] = "connect"]
                    /\ inbox' = r.q /\ dialing' = r.d
                    /\ UNCHANGED <<active, up, net, left>>
                ELSE
                    LET targets == active[n] \ {s, np}
                        out == IF targets = {} THEN {}
                               ELSE Send(Msg("forward_join", n, Pick(targets), None, m.ttl - 1, np, FALSE))
                    IN /\ passive' = [passive EXCEPT ![n] = P1]
                       /\ net' = SendAll(net, out)
                       /\ inbox' = q
                       /\ UNCHANGED <<active, up, pending, dialing, left>>
         [] m.type = "disconnect" ->
            IF s \in active[n] THEN
                LET A == active[n] \ {s}
                    P1 == AddPassive(n, s, passive[n])
                    r == Promote(n, A, P1, pending[n], q, dialing)
                IN /\ active' = [active EXCEPT ![n] = A]
                   /\ up' = [up EXCEPT ![n] = @ \ {s}]
                   /\ passive' = [passive EXCEPT ![n] = r.p]
                   /\ pending' = [pending EXCEPT ![n] = r.pend]
                   /\ inbox' = r.q /\ dialing' = r.d
                   /\ UNCHANGED net
            ELSE
                /\ inbox' = q
                /\ UNCHANGED <<active, passive, up, pending, dialing, net, left>>
         [] m.type = "neighbor" ->
            LET acc == m.prio = "high" \/ Cardinality(active[n]) < ActiveSize
                       \/ (FixLeftRefuses /\ s \in active[n])
                reply == Send(Msg("neighbor_reply", n, s, None, 0, n, acc))
            IN IF acc THEN
                   LET r == AddActive(n, s, active[n], passive[n], up[n]) IN
                   /\ active' = [active EXCEPT ![n] = r.a]
                   /\ passive' = [passive EXCEPT ![n] = r.p]
                   /\ up' = [up EXCEPT ![n] = r.u]
                   /\ net' = SendAll(net, r.out \cup reply)
                   /\ inbox' = q
                   /\ UNCHANGED <<pending, dialing, left>>
               ELSE
                   /\ net' = SendAll(net, reply)
                   /\ inbox' = q
                   /\ UNCHANGED <<active, passive, up, pending, dialing, left>>
         [] m.type = "neighbor_reply" ->
            LET Pend == IF pending[n][s] \in {"nb_high", "nb_low"}
                        THEN [pending[n] EXCEPT ![s] = None] ELSE pending[n]
            IN IF m.acc /\ FixLeftRefuses /\ pending[n][s] \notin {"nb_high", "nb_low"} THEN
                   \* not a request we track: a confirmation if s is active,
                   \* otherwise late (evicted, timed out); tell s to drop it
                   /\ inbox' = q
                   /\ net' = IF s \in active[n] THEN net
                             ELSE SendAll(net, Send(Msg("disconnect", n, s, None, 0, n, FALSE)))
                   /\ passive' = IF s \in active[n] THEN passive
                                 ELSE [passive EXCEPT ![n] = AddPassive(n, s, @)]
                   /\ UNCHANGED <<active, up, pending, dialing, left>>
               ELSE IF m.acc THEN
                   LET r == AddActive(n, s, active[n], passive[n], up[n]) IN
                   /\ active' = [active EXCEPT ![n] = r.a]
                   /\ passive' = [passive EXCEPT ![n] = r.p]
                   /\ up' = [up EXCEPT ![n] = r.u]
                   /\ pending' = [pending EXCEPT ![n] = Pend]
                   /\ net' = SendAll(net, r.out)
                   /\ inbox' = q
                   /\ UNCHANGED <<dialing, left>>
               ELSE IF pending[n][s] \in {"nb_high", "nb_low"} /\ FixLeftRefuses /\ s \in active[n] THEN
                   \* linked meanwhile through another request: keep it
                   /\ pending' = [pending EXCEPT ![n] = Pend]
                   /\ inbox' = q
                   /\ UNCHANGED <<active, passive, up, dialing, net, left>>
               ELSE IF pending[n][s] \in {"nb_high", "nb_low"} THEN
                   \* our own request was refused: back to passive, try another
                   LET r == Promote(n, active[n], AddPassive(n, s, passive[n]), Pend, q, dialing) IN
                   /\ passive' = [passive EXCEPT ![n] = r.p]
                   /\ pending' = [pending EXCEPT ![n] = r.pend]
                   /\ inbox' = r.q /\ dialing' = r.d
                   /\ UNCHANGED <<active, up, net, left>>
               ELSE IF FixLeftRefuses /\ s \in active[n] THEN
                   \* a peer we added on our side does not keep the link
                   LET A == active[n] \ {s}
                       r == Promote(n, A, passive[n], pending[n], q, dialing)
                   IN /\ active' = [active EXCEPT ![n] = A]
                      /\ up' = [up EXCEPT ![n] = @ \ {s}]
                      /\ passive' = [passive EXCEPT ![n] = r.p]
                      /\ pending' = [pending EXCEPT ![n] = r.pend]
                      /\ inbox' = r.q /\ dialing' = r.d
                      /\ UNCHANGED <<net, left>>
               ELSE
                   /\ inbox' = q
                   /\ UNCHANGED <<active, passive, up, pending, dialing, net, left>>
    /\ UNCHANGED <<alive, joined, chan, faults, left>>

\* The 30 s pending backstop: no dial and no cast for that peer in flight.
\* Firing means a peer stalled for 30 s, so it counts as a fault.
PendingTimeout(n, t) ==
    /\ n \in alive /\ pending[n][t] # None /\ faults < MaxFaults
    /\ <<n, t>> \notin dialing
    /\ \A i \in 1..Len(inbox[n]) : inbox[n][i].type \in {"pc", "pf"} => inbox[n][i].from # t
    /\ pending' = [pending EXCEPT ![n][t] = None]
    /\ faults' = faults + 1
    /\ UNCHANGED <<alive, joined, chan, dialing, net, inbox, active, passive, up, left>>

Next ==
    \/ \E n, c \in Nodes : Join(n, c)
    \/ \E a, b \in Nodes : DialOk(a, b) \/ DialFail(a, b) \/ ChanDown(a, b) \/ PendingTimeout(a, b)
    \/ \E n \in Nodes : Crash(n) \/ Leave(n) \/ Handle(n) \/ HandleLeft(n)
    \/ \E a, b \in Nodes : Arrive(a, b)

Spec == Init /\ [][Next]_vars

StateBound ==
    /\ \A p \in Pairs : Len(net[p]) =< MaxMsgs
    /\ \A n \in Nodes : Len(inbox[n]) =< MaxMsgs

-----------------------------------------------------------------------------
\* Invariants

NoSelf == \A n \in Nodes : n \notin active[n] /\ n \notin passive[n]

ViewBounds ==
    \A n \in Nodes : Cardinality(active[n]) =< ActiveSize /\ Cardinality(passive[n]) =< PassiveSize

\* What subscribers believe is the active view, for every node still in the
\* overlay or that left it.
EventsMatchView == \A n \in joined : up[n] = active[n]

\* A node that left holds no active links.
LeftStaysOut == \A n \in left : active[n] = {}

Quiescent ==
    /\ NetEmpty(net) /\ dialing = {}
    /\ \A n \in Nodes : inbox[n] = <<>>
    /\ \A n, m \in Nodes : pending[n][m] = None

SymmetricAtQuiescence ==
    Quiescent =>
        \A a, b \in alive : (b \in active[a]) <=> (a \in active[b])

Links(x) == (active[x] \cup {y \in alive : x \in active[y]}) \cap alive

RECURSIVE Reach(_, _)
Reach(S, k) == IF k = 0 THEN S ELSE Reach(S \cup UNION {Links(x) : x \in S}, k - 1)

\* Without faults, the overlay ends up connected.
ConnectedAtQuiescence ==
    (Quiescent /\ joined = Nodes /\ faults = 0) =>
        \A x \in alive : Reach({x}, Cardinality(Nodes)) = alive
=============================================================================
