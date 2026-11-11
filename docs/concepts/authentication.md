# Authentication

Barrel P2P authenticates every dist connection with Ed25519
mutual signatures. The authentication runs after the QUIC TLS
handshake and before Erlang's dist handshake; two peers that
have not proved possession of the right private key never
reach the cookie exchange.

This page is the **concept**: what the protocol does and why
the shape is the way it is. For operational tasks
(provisioning, rotation, cookie-only peers), see
[configure authentication](../how-to/configure-authentication.md).

## Why a second identity layer

The QUIC TLS handshake gives us an encrypted transport. The
certificate is self-signed: there is no authority barrel_p2p
expects you to trust, and a fresh node generates its own TLS
material on first boot. So the TLS layer establishes a secure
channel, but it does not say *who* is on the other side.

The Ed25519 layer adds that. Each node has a long-lived
Ed25519 keypair stored on disk. The public key is the node's
identity; the private key is what the node uses to prove that
identity.

Across cert rotation, across reboots, across TLS material
regeneration, the Ed25519 keypair persists. Peers trust each
other by pinning each other's public keys under the node atom.

The cluster also retains the standard Erlang dist cookie. With
Ed25519 enabled (the default), the cookie is
defense-in-depth; with Ed25519 disabled, it is the only
authentication that remains.

## The handshake

When two nodes connect, immediately after the QUIC TLS
handshake finishes, each side opens one unidirectional QUIC
stream toward the other and writes its half of the protocol on
it (protocol version 3):

```
Node A (client, dialed B)                Node B (server)
      |                                        |
      |--HELLO(v3, node_A, pubkey_A)---------->|
      |<-HELLO(v3, node_B, pubkey_B)-----------|  A checks node_B = B
      |                                        |
      |--CHALLENGE(nonce_A, wall_ts_A)-------->|
      |<-CHALLENGE(nonce_B, wall_ts_B)---------|
      |                                        |
      |--RESPONSE(sig_A over transcript)------>|
      |<-RESPONSE(sig_B over transcript)-------|
      |<-OK------------------------------------|
                    |
                    v
           Erlang dist handshake
```

Only the server sends OK. A peer that refuses sends FAIL with a
reason instead.

**Each signature covers the whole handshake.** Both sides sign
the same transcript, differing only in the role byte:

```
"barrel_p2p-dist-auth-v3" | role | client_name | server_name |
client_pubkey | server_pubkey | nonce_A | nonce_B | channel_binding
```

- The **role** stops a server's signature from being replayed as
  a client's. Without it, an attacker could make a node sign its
  own challenge and accept "itself".
- **Both names and both keys** bind the signature to who is
  talking to whom.
- **Both nonces** bind it to this handshake. They are fresh
  random values, so an old signature never verifies again.
- The **channel binding** is the SHA-256 of the server's QUIC TLS
  certificate. The client takes it from the certificate it
  observed (`quic:peercert/1`), the server from its own listener
  certificate. A relay that terminates two TLS legs sees two
  different certificates, so a relayed signature fails. A stolen
  Ed25519 key alone does not let an attacker sit in the middle.

**The authenticated name is the node you dialed.** The client
refuses a server whose HELLO names a node other than the one it
dialed (`auth_identity_mismatch`), before sending anything signed.
A key trusted for some other node cannot stand in for the target.

On the server side, the authenticated name must also be the name
the peer then uses in the Erlang dist handshake. That check runs
in `quic_dist` and needs a quic release that supports
`{ok, {authenticated_node, Node}}` from the auth callback. Until
barrel_p2p depends on it, a peer holding a key the server accepts
can authenticate under that key's name and announce another name
to `dist_util`. Use strict mode and keep every node key private
until then.

**The window check uses monotonic time.** The wall timestamp
goes on the wire so peers can sanity-check each other's clocks,
but it is not signed: freshness comes from the nonces. The
duration check uses `erlang:monotonic_time/1`, so an NTP step
during the handshake does not cause a spurious failure.

The protocol is checked with Tamarin; see
[Verification](verification.md#authentication).

## Trust modes

The interesting decision happens on the server side after
HELLO: "have I seen this peer before, and does the key it just
presented match the one I have on file?"

| Scenario                    | TOFU mode                             | Strict mode                |
|-----------------------------|---------------------------------------|----------------------------|
| No pin recorded             | Accept, pin the presented key         | Reject (`untrusted_key`)   |
| Pin matches presented key   | Accept                                | Accept                     |
| Pin differs from presented  | Reject (`key_mismatch`)               | Reject (`key_mismatch`)    |

The "pin differs" case is rejected **in both modes**. TOFU does
not silently re-pin, no matter what mode the peer is in. Once
a peer is recorded, you must remove the pin explicitly before
a different key for the same node atom can be accepted.

The trade-off:

- **TOFU** is zero-configuration. Joining a node is one
  command, the first contact pins both sides. Operational
  simplicity. The first contact is theoretically vulnerable to
  an active attacker who outraces the legitimate peer; in
  controlled environments that window is acceptable.
- **Strict** never auto-pins. Every peer must already have its
  public key on disk under
  `data/keys/trusted/<node-atom>.pub`. No first-contact
  window. The price is that you must provision keys before
  nodes can connect.

The same TOFU model powers SSH's `known_hosts`.

## What lives on disk

```
data/keys/
├── node.pub                      # 32 bytes, the node's Ed25519 public key
├── node.key                      # 32 bytes, the private key (chmod 0600)
└── trusted/
    ├── node1@host1.pub           # 32 bytes, raw public key
    ├── node2@host2.pub
    └── ...
```

The file format is the raw 32-byte public key. No PEM headers,
no base64. This matches the on-the-wire shape; the cluster
does not have a separate "import" step beyond placing the
file.

A few invariants the runtime preserves:

- The private key file is created with mode 0600. The helper
  that writes secret material (`barrel_p2p_file:write_secure/2`)
  chmods the temporary file *before* any plaintext bytes are
  written, so a co-tenant cannot race the write.
- Writes go through a temp file and rename, so a crash
  mid-write never leaves a half-written pin that the next boot
  would silently drop.
- The keypair is consistency-checked on load: the public key
  on disk must derive from the private key on disk. If they
  disagree (because a previous rotation crashed mid-flight),
  the load returns `{error, keypair_mismatch}` and the node
  refuses to start until the operator decides which side is
  correct.

For provisioning, rotation, and the cookie-only escape hatch,
see [configure authentication](../how-to/configure-authentication.md).

## Cookie-only peers

A small whitelist of node-atom patterns can bypass the Ed25519
handshake on the strength of the Erlang dist cookie alone:

```erlang
{barrel_p2p, [
    {cookie_only_nodes, ['probe@*', 'monitor@trusted.example']}
]}.
```

This is meant for one specific case: short-lived probes (an
`erl_call`-style helper, a monitoring agent) that cannot carry
an Ed25519 keypair and that you trust on cookie grounds.

The check is **symmetric**. If the cluster runs without this
whitelist on the *client* side, the client refuses an
unsolicited `AUTH_OK` from a server even if the server thinks
the client is in its own cookie_only list. Both ends must list
the peer for the short-circuit to apply.

## Configuration

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

    %% Handshake budget. The full Ed25519 round trip must
    %% complete within this many milliseconds; otherwise the
    %% connection is closed.
    {auth_handshake_timeout, 10000},

    %% Acceptable skew (per direction) between the local clock
    %% and the peer's wall-clock timestamps in the CHALLENGE.
    %% The local handshake duration check uses monotonic time;
    %% this controls the cross-host sanity check.
    {auth_timestamp_window, 30000},

    %% Short-circuit whitelist. Each entry is a node-atom
    %% pattern with optional `*` wildcards.
    {cookie_only_nodes, []}
]}.
```

## API

The relevant entry points. The public ones from `barrel_p2p.erl`
are minimal because most authentication is automatic; the
inspection and provisioning lives in `barrel_p2p_dist_keys` and
`barrel_p2p_dist_auth`.

```erlang
%% Inspect or pin keys.
barrel_p2p_dist_keys:store_key(Node, PubKey) -> ok.
barrel_p2p_dist_keys:store_key_if_new(Node, PubKey) -> ok.
barrel_p2p_dist_keys:lookup_pin(Node) -> not_pinned | {pinned, PubKey}.
barrel_p2p_dist_keys:delete_key(Node) -> ok.
barrel_p2p_dist_keys:list_trusted() -> [#peer_key{}].
barrel_p2p_dist_keys:set_trust_mode(tofu | strict) -> ok.
barrel_p2p_dist_keys:get_trust_mode() -> tofu | strict.
barrel_p2p_dist_keys:fingerprint(PubKey) -> binary().  %% SHA-256

%% Identity.
barrel_p2p_dist_auth:ensure_keypair() -> ok.
barrel_p2p_dist_auth:get_public_key() -> {ok, binary()}.
barrel_p2p_dist_auth:is_cookie_only_allowed(Node) -> boolean().

%% Rotation.
barrel_p2p_rotate:rotate_identity() -> {ok, Info}.
barrel_p2p_rotate:rotate_cert() -> {ok, Info}.
```

## Related

- [Configure authentication](../how-to/configure-authentication.md)
  is the operational guide (TOFU vs strict, provisioning,
  rotation, cookie-only).
- [Dist channel](dist-channel.md) explains where the Ed25519
  handshake fits in the larger boot flow.
- [Run in production](../how-to/run-in-production.md) covers
  ports, secrets, and the operational checklist that includes
  authentication.
