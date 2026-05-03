# Circuits

A circuit is a chain of QUIC user streams spliced together at one or
more intermediate hops on top of the existing per-peer dist
connections. Mycelium uses them to give applications stream-shaped
channels between cluster nodes that are not in each other's active
view, with byte-perfect resume across hop failure and automatic
shortest/fastest path selection.

## When to use

- **Reach a cluster node that is not directly connected.** You can
  pass an explicit path or let mycelium pick the lowest-RTT route.
- **Multiplex many independent streams between two nodes.** A
  single-hop circuit (`open(Peer)`) is just a stream over the
  existing dist connection; no new QUIC handshake.
- **Survive an intermediate hop disappearing.** When a relay's link
  goes down, the circuit migrates to another path automatically and
  no bytes are lost.

## When not to use

- For NAT/firewall traversal: out of scope. See
  [external-relay.md](external-relay.md) for how to wire an external
  tunnel adapter.
- When you need raw `quic_dist` user streams without circuit
  framing: open them via `mycelium_streams:open(Tag, Node)` with your
  own tag (any binary not starting with `<<"mycelium:">>`).

## API

```erlang
%% Auto-route: lowest-RTT path picked via mycelium_router.
{ok, CRef} = mycelium_circuit:open(Target).

%% Explicit path (intermediate hops only; target excluded).
{ok, CRef} = mycelium_circuit:open(Target, [Hop1, Hop2]).

%% Options.
{ok, CRef} = mycelium_circuit:open(Target, #{
    path => [Hop1],     %% or omit to auto-route
    repath => true,     %% migrate on hop failure (default true)
    max_hops => 4,      %% router probe budget
    timeout => 200      %% probe collection timeout (ms)
}).

ok = mycelium_circuit:send(CRef, <<"hello">>).
ok = mycelium_circuit:close(CRef).
```

The same calls are exposed on the `mycelium` module as
`circuit_open/1,2`, `circuit_send/2`, `circuit_close/1`,
`circuit_listen/0,1`, `circuit_unlisten/0,1`.

## Owner mailbox

Both initiator and destination receive these messages:

```erlang
{circuit, CRef, {opened, InitiatorNode}}      %% destination only
{circuit, CRef, {data, Data}}
{circuit, CRef, {migrating, OldPath}}         %% before re-route attempt
{circuit, CRef, {migrated, NewPath, EstRtt}}  %% after successful resume
{circuit, CRef, {migration_failed, Reason}}   %% no alternate path / timeout
{circuit, CRef, closed}                        %% peer FIN or terminal failure
```

Destination side:

```erlang
ok = mycelium_circuit:listen().
receive
    {circuit, CRef, {opened, From}} ->
        loop(CRef, From)
end.

loop(CRef, From) ->
    receive
        {circuit, CRef, {data, Data}} ->
            mycelium_circuit:send(CRef, [<<"echo:">>, Data]),
            loop(CRef, From);
        {circuit, CRef, closed} ->
            ok
    end.
```

## Architecture

Five internal modules:

- **`mycelium_streams`** — single user-stream acceptor per peer.
  Demuxes incoming streams by their leading `<<TagLen:8, Tag>>`
  preamble and hands ownership to the registered handler. Apps
  register their own tags via
  `mycelium_streams:register_acceptor/2` and open via
  `mycelium_streams:open/2`. Circuits use the reserved tag
  `<<"mycelium:circuit">>`.
- **`mycelium_circuit_proto`** — wire format for the five circuit
  frames: CREATE, RESUME, DATA, ACK, FIN.
- **`mycelium_circuit_link`** — pure-data windowed reliability
  state. Holds tx/rx sequence numbers, unacked-frame buffer for
  retransmit, and ack-pacing counters. 48-bit frame seqs;
  cumulative ACKs.
- **`mycelium_circuit_relay`** — singleton acceptor for circuit
  traffic. On CREATE: spawns a destination or relay pipe based on
  remaining path. On RESUME: looks up the existing destination
  pipe by circuit id and `attach_inbound`s the new stream.
- **`mycelium_circuit_pipe`** — per-circuit gen_server in three
  roles. *Initiator* drives migration via
  `mycelium_router:find_path/2`. *Destination* waits for a
  RESUME-bearing fresh inbound stream during migration. *Relay*
  splices bytes between two streams.

Path selection uses `mycelium_path_stats:srtt/1` (a one-line
wrapper over `quic:get_path_stats/1`) and
`mycelium_router:find_path/2`, which probes candidate next-hops in
parallel and caches results in a dedicated ETS table for 30
seconds.

## Wire format

Each circuit stream begins with the `mycelium_streams` tag preamble
`<<16, "mycelium:circuit">>`, followed by frames:

```
CREATE  <<1, IdLen, Id, InitLen:16, Init, PathLen, [NameLen:16, Name]*>>
RESUME  <<2, IdLen, Id, RxNextSeq:48, PathLen, [NameLen:16, Name]*>>
DATA    <<3, Seq:48, Len:32, Payload>>
ACK     <<4, CumulativeSeq:48>>
FIN     <<5, Seq:48>>
```

Both DATA and FIN consume one sequence number; ACK is cumulative
and covers any frame type with `Seq <= CumulativeSeq`.

## Migration semantics

When the initiator's stream to its first hop closes unexpectedly:

1. The pipe emits `{migrating, OldPath}` to the owner.
2. It calls `mycelium_router:find_path(Target, #{exclude => [DeadHop]})`.
3. It opens a fresh stream to the new first hop via
   `mycelium_streams:open(<<"mycelium:circuit">>, NewFirstHop)`.
4. It writes `FRAME_RESUME(Id, MyRxNextSeq, NewRemainingPath)`.
5. Each relay along the new path treats RESUME like CREATE for
   routing: pops the path head, opens its downstream, rewrites
   RESUME with the tail. Relays keep no per-circuit state.
6. The destination pipe receives RESUME on a fresh inbound stream
   (mediated by the relay's circuit-id map), prunes its own
   tx-unacked buffer to peer's RxNextSeq, replays remaining
   DATA/FIN frames in order, and writes its own
   `FRAME_RESUME(Id, MyRxNextSeq, [])` back upstream.
7. The initiator does the symmetric prune+replay on receiving the
   destination's RESUME.
8. Both sides emit `{migrated, NewPath, EstRtt}` and resume normal
   traffic.

Bytes in flight at the moment of failure are not lost: every
DATA/FIN sits in the sender's unacked buffer until the peer
cumulative-ACKs it, so the resume cursor exchange tells each side
exactly where to pick up.

## Path observability

`mycelium_path_stats:summary(Node)` returns the per-connection
metrics that upstream `quic:get_path_stats/1` exposes:

```erlang
#{
    srtt => 1234,            %% smoothed RTT, microseconds
    latest_rtt => 1500,
    min_rtt => 1000,
    rtt_var => 100,
    cwnd => 14600,           %% congestion window, bytes
    bytes_in_flight => 0,
    in_recovery => false,
    congested => false
}
```

`mycelium_router:find_path/2` uses `srtt/1` to rank candidates.
Since QUIC SRTT is round-trip on the forward edge, summing per-hop
srtts is an order-preserving proxy for total path latency.

## Caveats

- **Path selection is best-effort.** `find_path` probes peers
  reachable in one hop today; multi-hop probing recursion is a
  follow-up. For 3+ hop paths in non-trivial topologies, pass an
  explicit `path` option.
- **Migration drops in-flight bytes only on terminal failure.** If
  the alternate path also dies during the resume handshake, the
  pipe emits `migration_failed` and `closed`; the app sees
  whatever was acknowledged before the first failure plus loss of
  in-flight bytes from that point.
- **One handler per tag.** `mycelium_streams:register_acceptor/2`
  is exclusive per tag; if you need multiple consumers, fan out
  inside your handler.
