---------------------------- MODULE Plumtree ----------------------------
(***************************************************************************)
(* barrel_p2p_plumtree as coded, for two broadcasts from one origin over  *)
(* a HyParView overlay: the first trims the tree (PRUNE turns links lazy), *)
(* the second then relies on IHAVE / GRAFT repair over the lazy links.    *)
(*                                                                         *)
(* Each node keeps eager and lazy peer sets. The origin delivers locally,  *)
(* sends GOSSIP to its eager peers and IHAVE to its lazy ones. A node that *)
(* gets GOSSIP for the first time delivers and forwards the same way; a   *)
(* duplicate GOSSIP gets PRUNE back (the sender becomes lazy). A node that *)
(* hears IHAVE for a message it lacks waits, then sends GRAFT; the peer    *)
(* answers with GOSSIP and becomes eager.                                  *)
(*                                                                         *)
(* Links leave the overlay two ways. Evict: a HyParView drop; peer_down    *)
(* reaches both nodes, the dist channel stays up, so messages already on   *)
(* the wire still arrive. Fail: the channel goes down too and in-flight    *)
(* messages are lost. Plumtree hears peer_down from the events process,    *)
(* not over the channel, so a message can arrive after the peer_down.      *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    Nodes,
    Origin,
    Links,          \* initial overlay: a set of {a, b}
    MaxFaults,
    FixAnnouncers,  \* remember every announcer and retry GRAFT through the
                    \*   next one (the code keeps the first and grafts once)
    FixEagerInView, \* only peers in the overlay become eager (the code adds
                    \*   any GOSSIP or GRAFT sender)
    FixReliableSend \* sends block on a busy channel instead of dropping
                    \*   (the code sends with `nosuspend' and ignores a drop)

VARIABLES
    link,       \* current overlay links
    chan,       \* dist channels up (a link implies a channel)
    eager, lazy,
    view,       \* node -> peers Plumtree believes are in the overlay
    has,        \* message -> nodes that delivered it
    sent,       \* messages the origin broadcast
    ann,        \* node -> message -> FIFO of announcers (IHAVE senders)
    net,        \* <<from, to>> -> FIFO of <<kind, message>>
    events,     \* node -> FIFO of peer_down notifications not handled yet
    faults

vars == <<link, chan, eager, lazy, view, has, sent, ann, net, events, faults>>

Pairs == Nodes \X Nodes
Nbrs(L, n) == {m \in Nodes : {n, m} \in L}

Msgs == {1, 2}

Put(w, from, tos, kind, m) ==
    [p \in Pairs |-> IF p[1] = from /\ p[2] \in tos THEN Append(w[p], <<kind, m>>) ELSE w[p]]

Init ==
    /\ link = Links
    /\ chan = Links
    /\ eager = [n \in Nodes |-> Nbrs(Links, n)]   \* init: eager = active view
    /\ lazy = [n \in Nodes |-> {}]
    /\ view = [n \in Nodes |-> Nbrs(Links, n)]
    /\ has = [m \in Msgs |-> {}]
    /\ sent = {}
    /\ ann = [n \in Nodes |-> [m \in Msgs |-> <<>>]]
    /\ net = [p \in Pairs |-> <<>>]
    /\ events = [n \in Nodes |-> <<>>]
    /\ faults = 0

\* Message 2 is broadcast once message 1 has settled, so its tree is trimmed.
Broadcast(m) ==
    /\ m \notin sent
    /\ m = 2 => (1 \in sent /\ \A p \in Pairs : net[p] = <<>>)
    /\ sent' = sent \cup {m}
    /\ has' = [has EXCEPT ![m] = @ \cup {Origin}]
    /\ net' = Put(Put(net, Origin, eager[Origin], "gossip", m), Origin, lazy[Origin], "ihave", m)
    /\ UNCHANGED <<link, chan, eager, lazy, view, ann, events, faults>>

\* ensure_eager/2
MakeEager(n, s, E, Lz) ==
    IF FixEagerInView /\ s \notin view[n] THEN <<E, Lz>>
    ELSE <<E \cup {s}, Lz \ {s}>>

\* The oldest message from s reaches n.
Receive(s, n) ==
    /\ net[<<s, n>>] # <<>>
    /\ {s, n} \in chan
    /\ LET k == Head(net[<<s, n>>])[1]
           m == Head(net[<<s, n>>])[2]
           w == [net EXCEPT ![<<s, n>>] = Tail(@)]
       IN
       CASE k = "gossip" ->
            IF n \in has[m] THEN
                \* duplicate: PRUNE back, the sender becomes lazy there
                /\ net' = Put(w, n, {s}, "prune", m)
                /\ UNCHANGED <<eager, lazy, has, ann>>
            ELSE
                LET E == eager[n] \ {s}
                    Lz == lazy[n] \ {s}
                    r == MakeEager(n, s, eager[n], lazy[n])
                IN /\ has' = [has EXCEPT ![m] = @ \cup {n}]
                   /\ ann' = [ann EXCEPT ![n][m] = <<>>]
                   /\ net' = Put(Put(w, n, E, "gossip", m), n, Lz, "ihave", m)
                   /\ eager' = [eager EXCEPT ![n] = r[1]]
                   /\ lazy' = [lazy EXCEPT ![n] = r[2]]
         [] k = "ihave" ->
            /\ ann' = IF n \in has[m] THEN ann
                      ELSE IF FixAnnouncers
                           THEN (IF \E i \in 1..Len(ann[n][m]) : ann[n][m][i] = s THEN ann
                                 ELSE [ann EXCEPT ![n][m] = Append(@, s)])
                           ELSE (IF ann[n][m] = <<>> THEN [ann EXCEPT ![n][m] = <<s>>] ELSE ann)
            /\ net' = w
            /\ UNCHANGED <<eager, lazy, has>>
         [] k = "graft" ->
            LET r == MakeEager(n, s, eager[n], lazy[n]) IN
            /\ eager' = [eager EXCEPT ![n] = r[1]]
            /\ lazy' = [lazy EXCEPT ![n] = r[2]]
            /\ net' = IF n \in has[m] THEN Put(w, n, {s}, "gossip", m) ELSE w
            /\ UNCHANGED <<has, ann>>
         [] k = "prune" ->
            /\ eager' = [eager EXCEPT ![n] = @ \ {s}]
            /\ lazy' = [lazy EXCEPT ![n] = IF s \in eager[n] THEN @ \cup {s} ELSE @]
            /\ net' = w
            /\ UNCHANGED <<has, ann>>
    /\ UNCHANGED <<link, chan, view, sent, events, faults>>

\* The IHAVE timer fires: GRAFT the oldest announcer. The code then forgets
\* every announcer; with the fix the rest stay queued for the next timeout.
GraftTimeout(n, m) ==
    /\ n \notin has[m] /\ ann[n][m] # <<>>
    /\ net' = Put(net, n, {Head(ann[n][m])}, "graft", m)
    /\ ann' = [ann EXCEPT ![n][m] = IF FixAnnouncers THEN Tail(@) ELSE <<>>]
    /\ UNCHANGED <<link, chan, eager, lazy, view, has, sent, events, faults>>

\* A message on a channel that is down is lost; so is one dropped by
\* `nosuspend' on a busy channel (a fault, unless sends are reliable).
Lose(a, b) ==
    /\ net[<<a, b>>] # <<>>
    /\ {a, b} \notin chan \/ (faults < MaxFaults /\ ~FixReliableSend)
    /\ net' = [net EXCEPT ![<<a, b>>] = Tail(@)]
    /\ faults' = IF {a, b} \notin chan THEN faults ELSE faults + 1
    /\ UNCHANGED <<link, chan, eager, lazy, view, has, sent, ann, events>>

DownEvents(a, b) == [events EXCEPT ![a] = Append(@, b), ![b] = Append(@, a)]

\* HyParView evicts a link: peer_down on both ends, the channel stays up.
Evict(a, b) ==
    /\ {a, b} \in link /\ faults < MaxFaults
    /\ link' = link \ {{a, b}}
    /\ events' = DownEvents(a, b)
    /\ faults' = faults + 1
    /\ UNCHANGED <<chan, eager, lazy, view, has, sent, ann, net>>

\* A link fails: the channel goes down with it.
Fail(a, b) ==
    /\ {a, b} \in link /\ faults < MaxFaults
    /\ link' = link \ {{a, b}}
    /\ chan' = chan \ {{a, b}}
    /\ events' = DownEvents(a, b)
    /\ faults' = faults + 1
    /\ UNCHANGED <<eager, lazy, view, has, sent, ann, net>>

\* Plumtree handles peer_down: drop the peer from both sets.
PeerDown(n) ==
    /\ events[n] # <<>>
    /\ LET d == Head(events[n]) IN
       /\ eager' = [eager EXCEPT ![n] = @ \ {d}]
       /\ lazy' = [lazy EXCEPT ![n] = @ \ {d}]
       /\ view' = [view EXCEPT ![n] = @ \ {d}]
       /\ events' = [events EXCEPT ![n] = Tail(@)]
    /\ UNCHANGED <<link, chan, has, sent, ann, net, faults>>

Next ==
    \/ \E m \in Msgs : Broadcast(m)
    \/ \E a, b \in Nodes : Receive(a, b) \/ Lose(a, b) \/ Evict(a, b) \/ Fail(a, b)
    \/ \E n \in Nodes : PeerDown(n) \/ \E m \in Msgs : GraftTimeout(n, m)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
RECURSIVE Reach(_, _)
Reach(S, k) == IF k = 0 THEN S ELSE Reach(S \cup UNION {Nbrs(link, x) : x \in S}, k - 1)

Quiescent ==
    /\ sent = Msgs
    /\ \A p \in Pairs : net[p] = <<>>
    /\ \A n \in Nodes : events[n] = <<>>
    /\ \A n \in Nodes, m \in Msgs : n \in has[m] \/ ann[n][m] = <<>>

\* Every node still connected to the origin through the overlay delivered
\* the second message (the first is sent before any repair can matter).
DeliveredAtQuiescence ==
    Quiescent => Reach({Origin}, Cardinality(Nodes)) \subseteq has[2]

\* Plumtree only gossips eagerly to peers in the overlay.
EagerInView == (\A n \in Nodes : events[n] = <<>>) => \A n \in Nodes : eager[n] \subseteq Nbrs(link, n)
=============================================================================
