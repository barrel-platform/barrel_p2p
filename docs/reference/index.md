# Reference

Authoritative material: API surfaces, full configuration lists,
architectural details, comparison with adjacent projects.

## In this section

- [API overview](api-overview.md) — every public function in
  `barrel_p2p.erl`, grouped by subsystem, with stability tier.
- [Configuration](configuration.md) — every key under
  `{barrel_p2p, [...]}` in sys.config, with default, type, and
  one-line purpose.
- [Architecture](architecture.md) — the full supervision tree,
  protocol-level details that did not fit in the concept pages,
  and pointers into the source code.
- [Comparison with Partisan](comparison-with-partisan.md) —
  side-by-side feature matrix, when to pick which library.
- [The replicated substrate](replicated-substrate.md) — the
  low-level `barrel_p2p_replica` behaviour and `barrel_p2p_crdt_wire`,
  for custom merge beyond `barrel_p2p_map`.

## Related

- The [Concepts](../concepts/index.md) section explains the same
  systems with a teaching focus rather than a reference focus.
- The [How-to guides](../how-to/index.md) are task-focused
  recipes.
