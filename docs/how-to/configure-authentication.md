# Authentication

Barrel P2P authenticates every dist connection with Ed25519
signatures. The authentication runs after the QUIC TLS handshake
and before Erlang's dist handshake, so two nodes that have not
proved possession of the right private key never reach the cookie
exchange.

This document covers what the protocol does, how trust works in
practice, and how you operate a cluster (provisioning, rotation,
recovery).

## Why a second layer of identity

The QUIC TLS handshake gives us an encrypted transport, but the
certificate is self-signed. There is no certificate authority
barrel_p2p expects you to trust, and a fresh node generates its own
TLS material on first boot. So the TLS layer establishes a secure
channel, but it does not say *who* is on the other side.

The Ed25519 layer adds that. Each node has a long-lived Ed25519
keypair stored on disk. The public key is the node's identity;
the private key is what the node uses to prove that identity.
Across cert rotation, across reboots, across TLS material
regeneration, the Ed25519 keypair persists. Peers trust each
other by pinning each other's public key under the node atom.

The cluster also retains the standard Erlang dist cookie. With
Ed25519 enabled, the cookie is a defense-in-depth layer; with
Ed25519 disabled (which we do not recommend in production), it is
the only authentication that remains.

## The handshake

When two nodes connect, immediately after the QUIC TLS handshake
finishes, each side opens one unidirectional QUIC stream toward
the other. The four streams (two per side, one for sending, one
for receiving) carry the auth protocol:

```
Node A (client)                          Node B (server)
      |                                        |
      |--HELLO(node_A, pubkey_A)-------------->|
      |<-HELLO(node_B, pubkey_B)---------------|
      |                                        |
      |--CHALLENGE(nonce_A, wall_ts_A)-------->|
      |<-CHALLENGE(nonce_B, wall_ts_B)---------|
      |                                        |
      |--RESPONSE(sig over nonce_B,ts_B,pub_A)>|
      |<-RESPONSE(sig over nonce_A,ts_A,pub_B)-|
      |                                        |
      |--OK----------------------------------->|
      |<-OK------------------------------------|
                    |
                    v
           Erlang dist handshake
```

Two design points are worth knowing.

**The signed message includes the responder's own public key.**
A signature over `<<nonce, timestamp, responder_pubkey>>` is bound
to the identity the responder claims. A signature from peer X
cannot be replayed against peer Y to impersonate X, because the
message X signs is different from the one Y would.

**The window check uses monotonic time.** The wall timestamp goes
on the wire so peers can sanity-check each other's clocks, but the
responder's own duration check uses `erlang:monotonic_time/1`. An
NTP step during the handshake will not cause a spurious failure.

## Trust modes

The interesting decision happens on the server side after HELLO:
"have I seen this peer before, and does the key it just presented
match the one I have on file?"

| Scenario                | TOFU mode                            | Strict mode                |
|-------------------------|--------------------------------------|----------------------------|
| No pin recorded         | accept, pin the presented key        | reject (`untrusted_key`)   |
| Pin matches presented   | accept                               | accept                     |
| Pin differs from presented | reject (`key_mismatch`)           | reject (`key_mismatch`)    |

The "pin differs" case is rejected **in both modes**. TOFU does
not silently re-pin, no matter what mode the peer is in. Once a
peer is recorded, you have to remove the pin explicitly before a
different key for the same node atom can be accepted.

### TOFU (default)

```erlang
{barrel_p2p, [
    {auth_enabled, true},
    {auth_trust_mode, tofu}
]}
```

TOFU is the right default for most clusters. Joining a node is
zero-configuration, and the first-contact window is small in
practice: a malicious peer would have to outrace a legitimate one
to the first handshake. In a controlled environment, that
window is acceptable; the trade-off is operational simplicity.

The same property powers SSH's `known_hosts` model.

### Strict

```erlang
{barrel_p2p, [
    {auth_enabled, true},
    {auth_trust_mode, strict}
]}
```

Strict mode never auto-pins. Every peer the cluster needs to
accept must already have its public key on disk under
`data/keys/trusted/<node-atom>.pub`. This rules out the
first-contact window entirely; the price is that you must
provision keys before nodes can connect.

Strict mode is the right choice for clusters spanning untrusted
network segments, for compliance-driven environments, or any
context where the operator does not want a TOFU window to exist.

## Where credentials live on disk

```
data/keys/
├── node.pub                      # 32 bytes, the node's Ed25519 public key
├── node.key                      # 32 bytes, the private key (chmod 0600)
└── trusted/
    ├── node1@host1.pub           # 32 bytes, raw public key
    ├── node2@host2.pub
    └── ...
```

The file format is the raw 32-byte public key. No PEM headers, no
base64. This matches the on-the-wire shape; the cluster does not
have a separate "import" step beyond placing the file.

A few invariants the runtime preserves:

- The private key file is created with mode 0600. The helper that
  writes secret material (`barrel_p2p_file:write_secure/2`) chmods
  the temporary file *before* any plaintext bytes are written, so
  a co-tenant cannot race the write.
- Writes go through a tmp file and rename, so a crash mid-write
  never leaves a half-written pin that the next boot would
  silently drop.
- The keypair is consistency-checked on load: the public key on
  disk must derive from the private key on disk. If they
  disagree (because a previous rotation crashed mid-flight), the
  load returns `{error, keypair_mismatch}` and the node refuses
  to start until the operator decides which side is correct.

## Provisioning

### TOFU: nothing to do

In TOFU mode you do not provision anything. Start the cluster;
the first handshake of each pair pins both sides.

### Strict: distribute public keys ahead of time

The minimum to get a strict cluster up is to copy every node's
public key to every other node's `trusted/` directory.

Step 1: generate each node's keypair (the simplest way is to
boot once and stop):

```bash
erl -sname node1 -eval 'application:ensure_all_started(barrel_p2p), init:stop().'
```

Step 2: collect the public keys:

```bash
scp node1:data/keys/node.pub  /tmp/keys/node1@host1.pub
scp node2:data/keys/node.pub  /tmp/keys/node2@host2.pub
scp node3:data/keys/node.pub  /tmp/keys/node3@host3.pub
```

Step 3: distribute each public key to every other node:

```bash
for node in node1 node2 node3; do
    scp /tmp/keys/*.pub $node:data/keys/trusted/
done
```

Step 4: flip the mode on every node:

```erlang
{barrel_p2p, [{auth_trust_mode, strict}]}
```

After this, the cluster will accept only the listed peers. Adding
a new node means provisioning *its* public key on every existing
node and provisioning *theirs* in its `trusted/` directory.

### Runtime registration

If running an automation tool, you can place keys without
restarting:

```erlang
PeerPubKey = <<...32 bytes...>>,
ok = barrel_p2p_dist_keys:store_key('node@host', PeerPubKey).
```

`store_key/2` writes the file atomically; the runtime is happy to
pick up the new pin without a restart on the receiving side.

### Provisioning script

The same pattern as a small escript:

```erlang
#!/usr/bin/env escript
%% provision_keys.escript: read NodeName.pub files into a trust dir.
main([KeyDir | Nodes]) ->
    lists:foreach(
        fun(NodeStr) ->
            Path = NodeStr ++ ".pub",
            case file:read_file(Path) of
                {ok, PubKey} when byte_size(PubKey) =:= 32 ->
                    Target = filename:join([KeyDir, "trusted", Path]),
                    ok = filelib:ensure_dir(Target),
                    ok = file:write_file(Target, PubKey),
                    io:format("provisioned ~s~n", [NodeStr]);
                _ ->
                    io:format("skipped ~s (bad size)~n", [NodeStr])
            end
        end,
        Nodes
    ).
```

## Key rotation

Two rotations to keep distinct:

- **Identity rotation** (Ed25519 keypair). Takes effect on the
  next handshake; no restart required on the rotating node.
  Peers must accept the new identity (either via TOFU or by
  having the new public key provisioned).
- **Certificate rotation** (QUIC TLS material). Requires a node
  restart for the listener to load the new credentials.

Both are wrapped by `barrel_p2p_rotate`:

```erlang
{ok, Info} = barrel_p2p_rotate:rotate_identity().
%% Info = #{key_file := PrivPath,
%%          cert_file := PubPath,
%%          backup_dir := BackupPath,
%%          restart_required := false}

{ok, Info} = barrel_p2p_rotate:rotate_cert().
%% Info#{restart_required := true}
```

Each call atomically writes the new material and moves the old
material to `<dir>/backups/<UTC-timestamp>/`. The backup directory
is what you copy back if you decide to roll back.

### Identity rotation runbook

```erlang
{ok, _} = barrel_p2p_rotate:rotate_identity().
```

The new public key takes effect on the next handshake. What you
do next depends on the peer side's trust mode:

- **TOFU peers** will see the new identity, notice that they have
  no pin for this node atom (because the old pin was removed when
  the operator chose to rotate), and pin the new key. Existing
  trust entries pointing at the *old* key remain in the peer's
  store until you clean them out, which means rolling back to the
  old identity would still succeed; if that is not what you want,
  also delete the old pin on every peer.
- **Strict peers** will reject the new identity until you have
  provisioned the new public key on each of them. The rotation
  log line includes the new fingerprint; record it.

### Certificate rotation runbook

A cert rotation requires a node restart. The recommended order
per node:

1. `barrel_p2p:leave/0` so peers move you to passive view
   immediately.
2. `barrel_p2p_rotate:rotate_cert/0`.
3. `application:stop(barrel_p2p)` then `init:stop/0`.
4. Bring the node back up; the listener loads the new cert.

Peers will see one `peer_down` event and re-establish on next
demand. The Ed25519 identity is independent of the cert; it is
not affected.

### Rollback

The backup directory keeps the previous `node.crt`/`node.key`
(for cert rotation) or `node.pub`/`node.key` (for identity
rotation). Copy them back over the active files manually. For
cert rotations, restart the node after the swap.

## Inspecting state

```erlang
%% This node's identity.
{ok, MyPub} = barrel_p2p_dist_auth:get_public_key().
barrel_p2p_dist_keys:fingerprint(MyPub).        %% SHA-256 of the pubkey

%% All pinned peers.
barrel_p2p_dist_keys:list_trusted().

%% A specific peer's pinned key, if any.
barrel_p2p_dist_keys:lookup_pin('peer@host').
%% => not_pinned | {pinned, <<32 bytes>>}

%% Current trust mode.
barrel_p2p_dist_keys:get_trust_mode().
%% => tofu | strict
```

## Cookie-only peers

A small escape hatch: `cookie_only_nodes` is a list of node-atom
patterns that are exempt from the Ed25519 handshake. They get
through on the strength of the dist cookie alone.

```erlang
{barrel_p2p, [
    {cookie_only_nodes, ['probe@*', 'monitor@trusted.example']}
]}
```

Patterns support `*` as a wildcard on either the name or host
half of the atom. This is meant for one specific case:
short-lived probes (an `erl_call`-style helper, a monitoring
agent) that cannot carry an Ed25519 keypair and that you trust
on cookie grounds.

The check is symmetric. If the cluster runs without this
whitelist on the *client* side, the client refuses an unsolicited
`AUTH_OK` from a server even if the server thinks the client is
in its own cookie_only list. Both ends must list the peer for the
short-circuit to apply.

## API reference

### `barrel_p2p_dist_keys`

| Function                  | Purpose                                       |
|---------------------------|-----------------------------------------------|
| `store_key/2`             | Pin a peer's public key (permanent).         |
| `store_key_if_new/2`      | Pin only if no pin exists; TOFU primitive.    |
| `lookup_pin/1`            | `not_pinned` or `{pinned, Key}`.              |
| `lookup_key/1`            | `{ok, Key}` or `{error, not_found}` (legacy). |
| `is_trusted/2`            | `true` if the presented key matches the pin. |
| `delete_key/1`            | Remove a pin from the store.                  |
| `list_trusted/0`          | All current pins.                             |
| `set_trust_mode/1`        | Switch between `tofu` and `strict` at runtime.|
| `get_trust_mode/0`        | Current trust mode.                           |
| `fingerprint/1`           | SHA-256 of a public key, for logs.           |

### `barrel_p2p_dist_auth`

| Function                  | Purpose                                       |
|---------------------------|-----------------------------------------------|
| `ensure_keypair/0`        | Generate the local keypair if missing.        |
| `get_public_key/0`        | Read `node.pub`.                              |
| `get_private_key/0`       | Read `node.key`.                              |
| `is_cookie_only_allowed/1`| Check the `cookie_only_nodes` whitelist.      |
| `validate_peer_ts/1`      | Wall-clock skew sanity check (defense-in-depth). |

### `barrel_p2p_rotate`

| Function             | Purpose                                            |
|----------------------|----------------------------------------------------|
| `rotate_identity/0,1`| Replace the Ed25519 keypair. No restart needed.    |
| `rotate_cert/0,1`    | Replace the QUIC TLS material. Restart required.   |

## Configuration reference

```erlang
{barrel_p2p, [
    %% Master switch. Defaults to true. Setting this to false in
    %% production removes the Ed25519 layer; the dist cookie
    %% becomes the only authentication. Do not do this.
    {auth_enabled, true},

    %% Trust mode: tofu | strict.
    {auth_trust_mode, tofu},

    %% Directory holding the local keypair and the trust store.
    {auth_key_dir, "data/keys"},

    %% Handshake budget. The full Ed25519 round-trip must complete
    %% within this many milliseconds; otherwise the connection is
    %% closed.
    {auth_handshake_timeout, 10000},

    %% Acceptable skew (per direction) between the local clock
    %% and the peer's wall-clock timestamps in the CHALLENGE.
    %% The local handshake duration check uses monotonic time;
    %% this controls the cross-host sanity check.
    {auth_timestamp_window, 30000},

    %% Short-circuit list. Each entry is a node-atom pattern with
    %% optional `*` wildcards.
    {cookie_only_nodes, []}
]}.
```

## Security notes

- **Keep `node.key` mode 0600.** Barrel P2P writes new keys this
  way; if you copy files in from elsewhere, verify the
  permissions.
- **Use strict mode when the network is hostile.** TOFU's
  first-contact window is small but not zero. If your cluster
  spans untrusted networks, provision keys before nodes meet.
- **Treat `key_mismatch` as a security event.** The log line
  identifies the peer and the fingerprints involved. A legitimate
  rotation produces the line on every peer until the new pin is
  in place; an unexpected occurrence is worth investigating.
- **Keep clocks roughly synchronised.** The wall-time
  cross-check is 30 seconds wide by default. NTP-level
  synchronisation is sufficient; you do not need millisecond
  precision.
- **Rotate the dist cookie.** The default cookie `barrel_p2p` is a
  placeholder. Set `dist_cookie` to a high-entropy value in any
  environment where you would not be comfortable disabling Ed25519.
