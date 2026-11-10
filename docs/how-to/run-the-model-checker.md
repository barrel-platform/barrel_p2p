# Run the model checker

This guide shows how to model-check barrel_p2p's replication with TLC, and
how to read a failure. You need it when you change `barrel_p2p_replica`,
`barrel_p2p_ormap`, or how a consumer writes, syncs or prunes. What the
models prove is in [Verification](../concepts/verification.md).

## Run every model

You need Java 11 or later. The script downloads a pinned `tla2tools.jar`
on first use, checks its SHA-256 and caches it in `~/.cache/barrel_p2p/tla`.

```bash
spec/tla/check.sh
```

```text
ok    MergeLattice             pass                                1 states    6s
ok    MergeLattice_strict      fail:Associative                    ? states    5s
ok    MC_registry              pass                           207734 states    3s
ok    MC_registry_stamp        fail:QuiescentConverged         95673 states    2s
...
```

Each model has an expected verdict. `pass` models must find no error.
`fail:<Invariant>` models reproduce a known bug and must break exactly that
invariant. The script exits non-zero when any verdict differs, and prints
the end of TLC's output for that model. CI runs it on every push.

## Run one model

```bash
spec/tla/check.sh MC_map
```

To see a full counterexample trace, run TLC directly:

```bash
cd spec/tla
java -cp ~/.cache/barrel_p2p/tla/tla2tools-1.7.4.jar tlc2.TLC \
    -workers auto -config MC_registry_stamp.cfg ReplicaORMap.tla
```

TLC prints the states that lead to the violation, one action per step
(`LocalAdd`, `Broadcast`, `Deliver`, `LinkDown`, `Heal`, ...). Each action
is named after the code path it models.

## Change the model with the code

1. Change the matching action in `spec/tla/ReplicaORMap.tla`, or the merge
   in `ORMapMerge.tla`, when you change the code it mirrors. Each action's
   comment names the Erlang function it models.
2. To model a new consumer, add a `MC_<name>.cfg`. Set its constants
   (`SingleWriter`, `OwnOnlySnapshot`, `PruneMode`, `AE`) to match the
   consumer's callbacks.
3. Add the model to the `models` list in `spec/tla/check.sh` with its
   expected verdict.
4. Replay any new counterexample in
   `test/barrel_p2p_replica_convergence_prop_tests.erl`, so `rebar3 eunit`
   catches it too.

## Notes

- Bounds are set in each `.cfg` (`MaxClock`, `MaxWrites`, `MaxFlips`).
  Raising one by a single step can multiply the state count tenfold or
  more. Raise them locally to explore, and keep the CI models under a
  minute.
- TLC stores its state files in a temporary directory that the script
  removes when it finishes.
