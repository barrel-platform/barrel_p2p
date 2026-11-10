---------------------------- MODULE MergeLattice ----------------------------
(***************************************************************************)
(* Exhaustive check that MergeEntry is a join-semilattice operation       *)
(* (commutative, associative, idempotent) over every entry built from a   *)
(* small dot universe.                                                     *)
(*                                                                         *)
(* Well-formedness: in barrel_p2p a dot names exactly one write, so a     *)
(* value entry's payload is the payload of its greatest dot. DotValue      *)
(* fixes that dot -> payload mapping; merge never inspects payloads, so    *)
(* any fixed mapping gives the same verdict.                               *)
(***************************************************************************)
EXTENDS ORMapMerge

CONSTANTS LNodes, LClock

Dots == LNodes \X LClock
DotValue(dot) == IF (dot[1] + dot[2]) % 2 = 0 THEN "a" ELSE "b"

Entries ==
    {None}
    \cup {Tomb(ts) : ts \in LClock}
    \cup {Val(DotValue(MaxDot(D)), D) : D \in SUBSET Dots \ {{}}}

Commutative ==
    \A a, b \in Entries : MergeEntry(a, b) = MergeEntry(b, a)

Idempotent ==
    \A a \in Entries : MergeEntry(a, a) = a

\* Strict associativity does NOT hold: a tombstone that beats a value drops
\* that value's dots, so (T+V1)+V2 keeps only V2's dots while T+(V1+V2)
\* keeps both. MergeLattice_strict.cfg checks this law and is expected to
\* fail. The extra dots never change a merge decision (MaxDot/MaxHlc only
\* read the greatest dot); only barrel_p2p_map's owned_only_by/3 prune
\* reads the full dot set.
Associative ==
    \A a, b, c \in Entries :
        MergeEntry(MergeEntry(a, b), c) = MergeEntry(a, MergeEntry(b, c))

\* What merge decisions and readers observe: kind, payload, greatest dot
\* (or tombstone time).
Canon(e) ==
    IF e.t = "v" THEN [t |-> "v", v |-> e.v, top |-> MaxDot(e.d), ts |-> 0]
    ELSE [t |-> e.t, v |-> "", top |-> <<0, 0>>, ts |-> e.ts]

AssociativeObservable ==
    \A a, b, c \in Entries :
        Canon(MergeEntry(MergeEntry(a, b), c)) = Canon(MergeEntry(a, MergeEntry(b, c)))

\* Closure: merging well-formed entries yields a well-formed entry.
Closed ==
    \A a, b \in Entries : MergeEntry(a, b) \in Entries

VARIABLE done
Init == done = FALSE
Next == UNCHANGED done
=============================================================================
