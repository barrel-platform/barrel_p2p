---------------------------- MODULE MergeLattice ----------------------------
(***************************************************************************)
(* Exhaustive check that MergeEntry is a join-semilattice operation       *)
(* (commutative, associative, idempotent) over every entry the current    *)
(* code can produce from a small dot universe: a value carries exactly   *)
(* one dot, its newest write.                                             *)
(*                                                                         *)
(* Legacy entries (several dots, as sent by 0.1.x nodes) are checked to   *)
(* merge into current entries and to keep merge commutative and           *)
(* associative, so mixed-version clusters still converge.                 *)
(*                                                                         *)
(* Well-formedness: a dot names exactly one write, so a value's payload   *)
(* is the payload of its newest dot. DotValue fixes that mapping; merge    *)
(* never inspects payloads, so any fixed mapping gives the same verdict.  *)
(***************************************************************************)
EXTENDS ORMapMerge

CONSTANTS LNodes, LClock

Dots == LNodes \X LClock
DotValue(dot) == IF (dot[1] + dot[2]) % 2 = 0 THEN "a" ELSE "b"

Entries ==
    {None}
    \cup {Tomb(ts) : ts \in LClock}
    \cup {Val(DotValue(dot), {dot}) : dot \in Dots}

Legacy ==
    {Val(DotValue(MaxDot(D)), D) : D \in SUBSET Dots \ {{}}}

Commutative ==
    \A a, b \in Entries : MergeEntry(a, b) = MergeEntry(b, a)

Idempotent ==
    \A a \in Entries : MergeEntry(a, a) = a

Associative ==
    \A a, b, c \in Entries :
        MergeEntry(MergeEntry(a, b), c) = MergeEntry(a, MergeEntry(b, c))

\* Closure: merging current entries yields a current entry.
Closed ==
    \A a, b \in Entries : MergeEntry(a, b) \in Entries

\* Mixed versions: anything merged with a legacy entry is a current entry,
\* and merge stays commutative and associative across both kinds.
LegacyNormalized ==
    \A a \in Legacy, b \in Entries \cup Legacy : MergeEntry(a, b) \in Entries

LegacyCommutative ==
    \A a, b \in Entries \cup Legacy : MergeEntry(a, b) = MergeEntry(b, a)

LegacyAssociative ==
    \A a, b, c \in Entries \cup Legacy :
        MergeEntry(MergeEntry(a, b), c) = MergeEntry(a, MergeEntry(b, c))

VARIABLE done
Init == done = FALSE
Next == UNCHANGED done
=============================================================================
