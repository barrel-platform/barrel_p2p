---------------------------- MODULE ORMapMerge ----------------------------
(***************************************************************************)
(* The OR-Map entry merge of barrel_p2p_ormap, transcribed clause for     *)
(* clause from merge_entry/2, dot_compare/2, max_dot/1 and max_hlc/1.     *)
(*                                                                         *)
(* An HLC is abstracted as a natural number. A dot is <<Node, HLC>>, with  *)
(* Node a natural number so the node tiebreak of dot_compare/2 is a plain  *)
(* integer comparison. Every entry is a record with the same fields so    *)
(* TLC can compare any two of them:                                        *)
(*   t = "none"  absent key                                               *)
(*   t = "v"     {value, V, Dots}: payload v, non-empty dot set d          *)
(*   t = "x"     {tombstone, HLC}: removal time ts                         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

None == [t |-> "none", v |-> "", d |-> {}, ts |-> 0]
Val(v, D) == [t |-> "v", v |-> v, d |-> D, ts |-> 0]
Tomb(ts) == [t |-> "x", v |-> "", d |-> {}, ts |-> ts]

\* dot_compare/2: HLC first, then the node as a deterministic tiebreak.
DotGT(a, b) == a[2] > b[2] \/ (a[2] = b[2] /\ a[1] > b[1])

\* max_dot/1 and max_hlc/1 over a non-empty dot set.
MaxDot(D) == CHOOSE x \in D : \A y \in D : y = x \/ DotGT(x, y)
MaxHlc(D) == CHOOSE h \in {x[2] : x \in D} : \A y \in D : y[2] =< h

\* The greatest HLC an entry carries (0 for an absent key).
TsOf(e) == IF e.t = "v" THEN MaxHlc(e.d) ELSE IF e.t = "x" THEN e.ts ELSE 0

\* normalize/1: a value keeps only its newest dot. Entries from older
\* nodes may carry the full dot history.
Normalize(e) == IF e.t = "v" THEN Val(e.v, {MaxDot(e.d)}) ELSE e

\* merge_entry/2.
MergeEntry(e1, e2) ==
    IF e1.t = "none" THEN Normalize(e2)
    ELSE IF e2.t = "none" THEN Normalize(e1)
    ELSE IF e1.t = "v" /\ e2.t = "v" THEN
        IF DotGT(MaxDot(e1.d), MaxDot(e2.d))
            THEN Val(e1.v, {MaxDot(e1.d)})
            ELSE Val(e2.v, {MaxDot(e2.d)})
    ELSE IF e1.t = "x" /\ e2.t = "x" THEN
        IF e1.ts > e2.ts THEN e1 ELSE e2
    ELSE IF e1.t = "x" THEN
        IF e1.ts > MaxHlc(e2.d) THEN e1 ELSE Normalize(e2)
    ELSE
        IF e2.ts > MaxHlc(e1.d) THEN e2 ELSE Normalize(e1)
=============================================================================
