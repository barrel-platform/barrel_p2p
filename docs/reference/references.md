# References

This page lists the papers, RFCs and books barrel_p2p builds on, grouped by
the part of the system they describe. Use it to read the original design
behind a component, or to check how barrel_p2p departs from it. Each entry
says what barrel_p2p takes from the work and where it is used.

## Membership and broadcast

**HyParView.** João Leitão, José Pereira, Luís Rodrigues. *HyParView: a
membership protocol for reliable gossip-based broadcast.* DSN 2007.
A small active view of TCP-like links plus a larger passive view refreshed
by shuffles. `barrel_p2p_hyparview` implements it; the defaults
(`active_size` 5, `passive_size` 30, `arwl` 6, `prwl` 3) follow the paper.
See [Cluster membership](../concepts/cluster-membership.md).

**Plumtree.** João Leitão, José Pereira, Luís Rodrigues. *Epidemic
Broadcast Trees.* SRDS 2007.
Eager push along a spanning tree, lazy `ihave` announcements to the other
peers, `graft` and `prune` to repair and trim the tree.
`barrel_p2p_plumtree` implements it over the HyParView active view. See
[Gossip broadcast](../concepts/gossip-broadcast.md).

**Anti-entropy.** Alan Demers, Dan Greene, Carl Hauser, Wes Irish, John
Larson, Scott Shenker, Howard Sturgis, Dan Swinehart, Doug Terry.
*Epidemic Algorithms for Replicated Database Maintenance.* PODC 1987.
Rumor mongering plus periodic full-state exchange with a random peer, and
the first treatment of death certificates (tombstones) and their expiry.
The periodic pull in `barrel_p2p_replica` and tombstone GC follow it. See
[Replication protocol](replication-protocol.md).

**Partisan.** Christopher S. Meiklejohn, Heather Miller, Peter Alvaro.
*PARTISAN: Scaling the Distributed Actor Runtime.* USENIX ATC 2019.
An alternative distribution layer for Erlang that also uses HyParView. See
[Comparison with Partisan](comparison-with-partisan.md).

## Time

**Logical clocks.** Leslie Lamport. *Time, Clocks, and the Ordering of
Events in a Distributed System.* Communications of the ACM 21(7), 1978.
Happened-before and logical clocks; the ordering every timestamp here
respects.

**Hybrid logical clocks.** Sandeep S. Kulkarni, Murat Demirbas, Deepak
Madappa, Bharadwaj Avva, Marcelo Leone. *Logical Physical Clocks.*
OPODIS 2014.
Timestamps that respect causality and stay close to wall-clock time.
`barrel_p2p_hlc` wraps the `hlc` library that implements it. See [Hybrid
logical clocks](../concepts/hybrid-logical-clocks.md).

## Replicated data

**Last write wins.** Paul R. Johnson, Robert H. Thomas. *The Maintenance
of Duplicate Databases.* RFC 677, 1975.
Timestamped updates where the newest one wins (the Thomas write rule). The
value-versus-value rule of `barrel_p2p_ormap` is this rule with a dot as the
timestamp.

**CRDTs.** Marc Shapiro, Nuno Preguiça, Carlos Baquero, Marek Zawirski.
*Conflict-free Replicated Data Types.* SSS 2011.
State-based replicas converge when merge is a join-semilattice
(commutative, associative, idempotent). `barrel_p2p_ormap`'s merge is one;
`spec/tla/MergeLattice.tla` checks it. See
[Verification](../concepts/verification.md).

**OR-Set.** Annette Bieniusa, Marek Zawirski, Nuno Preguiça, Marc Shapiro,
Carlos Baquero, Valter Balegas, Sérgio Duarte. *An Optimized Conflict-free
Replicated Set.* arXiv:1210.3368, 2012.
Observed-remove semantics with dots. barrel_p2p borrows the dot naming but
not the semantics: a remove here is a timestamped tombstone, so a concurrent
add with an older timestamp loses (last write wins), where an OR-Set would
keep it.

**Delta-state CRDTs.** Paulo Sérgio Almeida, Ali Shoker, Carlos Baquero.
*Delta State Replicated Data Types.* Journal of Parallel and Distributed
Computing 111, 2018.
Shipping small deltas that merge like full states. The `{delta, _, _}`
broadcast is a one-key delta of this kind; full syncs ship the whole state.

**Verified convergence.** Victor B. F. Gomes, Martin Kleppmann, Dominic P.
Mulligan, Alastair R. Beresford. *Verifying Strong Eventual Consistency in
Distributed Systems.* OOPSLA 2017.
A machine-checked proof of convergence for several CRDTs over an
unreliable network model. barrel_p2p's TLA+ model checks a bounded version
of the same property for its own protocol.

## Placement

**Rendezvous hashing.** David G. Thaler, Chinya V. Ravishankar. *Using
Name-Based Mappings to Increase Hit Rates.* IEEE/ACM Transactions on
Networking 6(1), 1998.
Highest random weight hashing: each key goes to the node with the highest
hash of key and node. `barrel_p2p_shard` uses it. See [Sharded
placement](../concepts/sharded-placement.md).

**Fencing tokens.** Martin Kleppmann. *How to do distributed locking.*
2016, martin.kleppmann.com.
A monotonically increasing token that lets a resource reject a stale
leader. `barrel_p2p_leader` publishes one per election. See [Leader
election](../concepts/leader-election.md).

## Transport and authentication

**QUIC.** Jana Iyengar, Martin Thomson (eds.). *QUIC: A UDP-Based
Multiplexed and Secure Transport.* RFC 9000, 2021. Martin Thomson, Sean
Turner (eds.). *Using TLS to Secure QUIC.* RFC 9001, 2021.
The distribution carrier. See [Dist channel](../concepts/dist-channel.md).

**Ed25519.** Daniel J. Bernstein, Niels Duif, Tanja Lange, Peter Schwabe,
Bo-Yin Yang. *High-speed high-security signatures.* Journal of
Cryptographic Engineering 2(2), 2012. Simon Josefsson, Ilari Liusvaara.
*Edwards-Curve Digital Signature Algorithm (EdDSA).* RFC 8032, 2017.
Node identity keys and the mutual handshake signatures. See
[Authentication](../concepts/authentication.md).

**Channel binding.** Jeff Altman, Nicolas Williams, Larry Zhu. *Channel
Bindings for TLS.* RFC 5929, 2010.
The `tls-server-end-point` binding: the handshake signs the SHA-256 of the
server's TLS certificate, so a signature cannot be replayed over another
connection.

## Verification

**TLA+.** Leslie Lamport. *Specifying Systems: The TLA+ Language and Tools
for Hardware and Software Engineers.* Addison-Wesley, 2002.
The specification language of `spec/tla`.

**TLC.** Yuan Yu, Panagiotis Manolios, Leslie Lamport. *Model Checking
TLA+ Specifications.* CHARME 1999.
The explicit-state model checker `spec/tla/check.sh` runs.

**TLA+ in industry.** Chris Newcombe, Tim Rath, Fan Zhang, Bogdan
Munteanu, Marc Brooker, Michael Deardeuff. *How Amazon Web Services Uses
Formal Methods.* Communications of the ACM 58(4), 2015.
The case for model-checking the design of a replicated system at small
bounds, which is how `spec/tla` is used.

**Property-based testing.** Koen Claessen, John Hughes. *QuickCheck: A
Lightweight Tool for Random Testing of Haskell Programs.* ICFP 2000.
Manolis Papadakis, Konstantinos Sagonas. *A PropEr Integration of Types
and Function Specifications with Property-Based Testing.* Erlang Workshop
2011.
The PropEr suites, including the multi-replica convergence simulation.
