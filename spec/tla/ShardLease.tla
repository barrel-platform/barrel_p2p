---------------------------- MODULE ShardLease ----------------------------
(***************************************************************************)
(* barrel_p2p_shard leases between two healthy nodes whose clocks differ. *)
(*                                                                         *)
(* Each node heartbeats every HB on its own clock and stamps the lease    *)
(* with that clock. A receiver accepts a lease unless it is more than     *)
(* Skew ahead of its own clock, and considers the sender alive while      *)
(* `own clock - lease =< TTL'. Gossip takes up to Delay. Time is in whole *)
(* seconds; node 1's clock is real time, node 2's runs Ahead - Behind    *)
(* seconds off it.                                                         *)
(*                                                                         *)
(* Partition ownership is rendezvous hashing over the nodes each one      *)
(* considers alive. For a partition node 2 ranks first on, node 1 owns it *)
(* only if it considers node 2 dead; node 2 always owns it. So "node 1    *)
(* considers node 2 dead" means two owners, and a reminder on that        *)
(* partition fires on both.                                               *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS HB, TTL, Skew, Delay, Ahead, Behind, Horizon

Offset == Ahead - Behind

Nodes == {1, 2}
Clock(n, t) == IF n = 1 THEN t ELSE t + Offset
Other(n) == 3 - n
NoLease == -1000

VARIABLES
    t,          \* real time
    lastHb,     \* node -> real time of its last heartbeat (-1: none)
    lease,      \* node -> node -> latest accepted lease (NoLease: none)
    net         \* in flight: [from, to, emit, due]

vars == <<t, lastHb, lease, net>>

Init ==
    /\ t = 0
    /\ lastHb = [n \in Nodes |-> -1]
    /\ lease = [n \in Nodes |-> [m \in Nodes |-> NoLease]]
    /\ net = {}

\* do_heartbeat/1: renew our own lease and gossip it.
Heartbeat(n) ==
    /\ lastHb[n] = -1 \/ t >= lastHb[n] + HB
    /\ lastHb[n] = -1 => t = 0
    /\ lastHb' = [lastHb EXCEPT ![n] = t]
    /\ lease' = [lease EXCEPT ![n][n] = Clock(n, t)]
    /\ \E d \in 0..Delay :
        net' = net \cup {[from |-> n, to |-> Other(n), emit |-> Clock(n, t), due |-> t + d]}
    /\ UNCHANGED t

\* merge_delta: reject a lease too far ahead, keep the newest.
Deliver(m) ==
    /\ m \in net /\ m.due = t
    /\ net' = net \ {m}
    /\ lease' = IF m.emit =< Clock(m.to, t) + Skew /\ m.emit > lease[m.to][m.from]
                THEN [lease EXCEPT ![m.to][m.from] = m.emit]
                ELSE lease
    /\ UNCHANGED <<t, lastHb>>

\* Time advances once every due heartbeat and delivery has happened.
Tick ==
    /\ t < Horizon
    /\ \A n \in Nodes : lastHb[n] # -1 /\ t < lastHb[n] + HB
    /\ \A m \in net : m.due > t
    /\ t' = t + 1
    /\ UNCHANGED <<lastHb, lease, net>>

Next == Tick \/ \E n \in Nodes : Heartbeat(n) \/ \E m \in net : Deliver(m)

Spec == Init /\ [][Next]_vars

Alive(m, n) == lease[m][n] # NoLease /\ Clock(m, t) - lease[m][n] =< TTL

\* After the first heartbeats have arrived, each node keeps seeing the
\* other alive, so no partition has two owners.
SingleOwner == t >= HB + Delay => \A n \in Nodes : Alive(n, Other(n))
=============================================================================
