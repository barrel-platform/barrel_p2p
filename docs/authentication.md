# Authentication

Mycelium uses Ed25519 public-key cryptography to authenticate peer connections. This prevents unauthorized nodes from joining the cluster and protects against man-in-the-middle attacks.

## Overview

When two nodes connect, they perform a challenge-response handshake:

```
Node A (initiator)                    Node B (acceptor)
       │                                     │
       ├─── HELLO(pubkey_A, node_A) ────────►│
       │                                     │
       │◄── HELLO(pubkey_B, node_B) ─────────┤
       │                                     │
       ├─── CHALLENGE(nonce_A) ─────────────►│
       │                                     │
       │◄── CHALLENGE(nonce_B) ──────────────┤
       │                                     │
       ├─── RESPONSE(sign(nonce_B)) ────────►│
       │                                     │
       │◄── RESPONSE(sign(nonce_A)) ─────────┤
       │                                     │
       ├─── OK ─────────────────────────────►│
       │                                     │
                   Authenticated
```

Each node proves it owns the private key corresponding to its public key by signing the peer's challenge.

## Trust Modes

Mycelium supports two trust modes:

### TOFU (Trust On First Use) - Default

In TOFU mode, keys are automatically trusted on first contact:

1. Node A connects to Node B for the first time
2. Node B stores Node A's public key
3. Future connections from Node A must use the same key
4. If a different key is presented, connection is rejected

```erlang
{mycelium, [
    {auth_enabled, true},
    {auth_trust_mode, tofu}  %% Default
]}
```

**Pros:**
- Zero configuration required
- Easy cluster bootstrap
- Similar to SSH's known_hosts

**Cons:**
- First connection is vulnerable to MITM
- No pre-verification of node identity

### Strict Mode

In strict mode, all peer keys must be pre-registered:

```erlang
{mycelium, [
    {auth_enabled, true},
    {auth_trust_mode, strict}
]}
```

Unknown nodes are rejected with `untrusted_key` error.

**Pros:**
- No trust-on-first-use vulnerability
- Full control over cluster membership
- Required for high-security environments

**Cons:**
- Requires key distribution infrastructure
- More operational overhead

## Key Storage

Keys are stored in the `auth_key_dir` directory (default: `data/keys/`):

```
data/keys/
├── node.key          # This node's private key (32 bytes)
├── node.pub          # This node's public key (32 bytes)
└── trusted/          # Trusted peer public keys
    ├── node1@host1.pub
    ├── node2@host2.pub
    └── node3@host3.pub
```

### Key Generation

Keys are auto-generated on first start:

```erlang
%% Keys generated automatically when mycelium starts
%% Stored in data/keys/node.key and data/keys/node.pub
```

To manually generate a keypair:

```erlang
{PubKey, PrivKey} = mycelium_dist_auth:generate_keypair().
%% PubKey = <<32 bytes>>
%% PrivKey = <<32 bytes>>
```

### Exporting Your Public Key

To share your node's public key with other nodes:

```erlang
%% Get public key as binary
{ok, PubKey} = mycelium_dist_auth:get_public_key().

%% Display as hex for manual sharing
io:format("~s~n", [binary:encode_hex(PubKey)]).

%% Or copy the file directly
%% data/keys/node.pub
```

## Key Provisioning (Strict Mode)

### Method 1: File-Based Provisioning

Place peer public keys in the `trusted/` directory before starting:

```bash
# On node1, copy node2's public key
mkdir -p data/keys/trusted
cp /secure/transfer/node2@host2.pub data/keys/trusted/

# File must be named: <nodename>.pub
# Contents: 32-byte raw public key
```

Keys are loaded on startup from `data/keys/trusted/*.pub`.

### Method 2: Runtime Registration

Register keys programmatically:

```erlang
%% Get peer's public key (from secure channel)
PeerPubKey = <<...32 bytes...>>.

%% Register permanently (persisted to disk)
ok = mycelium_dist_keys:store_key('node2@host2', PeerPubKey).

%% Verify registration
{ok, PeerPubKey} = mycelium_dist_keys:lookup_key('node2@host2').
```

### Method 3: Provisioning Script

Create a provisioning script for cluster setup:

```erlang
#!/usr/bin/env escript
%% provision_keys.escript

main([KeyDir, NodeList]) ->
    Nodes = string:tokens(NodeList, ","),
    lists:foreach(fun(NodeStr) ->
        Node = list_to_atom(NodeStr),
        PubKeyFile = NodeStr ++ ".pub",
        case file:read_file(PubKeyFile) of
            {ok, PubKey} when byte_size(PubKey) =:= 32 ->
                TrustedFile = filename:join([KeyDir, "trusted", PubKeyFile]),
                ok = filelib:ensure_dir(TrustedFile),
                ok = file:write_file(TrustedFile, PubKey),
                io:format("Registered ~s~n", [NodeStr]);
            _ ->
                io:format("Failed to read ~s~n", [PubKeyFile])
        end
    end, Nodes).
```

## API Reference

### mycelium_dist_keys

| Function | Description |
|----------|-------------|
| `store_key(Node, PubKey)` | Store a peer's public key (permanent) |
| `store_key_if_new(Node, PubKey)` | Store only if no key exists (TOFU) |
| `lookup_key(Node)` | Get stored public key for a node |
| `delete_key(Node)` | Remove a trusted key |
| `is_trusted(Node, PubKey)` | Check if key matches stored key |
| `list_trusted()` | List all trusted peer records |
| `set_trust_mode(Mode)` | Set trust mode (strict/tofu) at runtime |
| `get_trust_mode()` | Get current trust mode |

### mycelium_dist_auth

| Function | Description |
|----------|-------------|
| `ensure_keypair()` | Generate keypair if not exists |
| `get_public_key()` | Get this node's public key |
| `get_private_key()` | Get this node's private key |
| `generate_keypair()` | Generate new Ed25519 keypair |

## Configuration Reference

```erlang
{mycelium, [
    %% Enable/disable authentication (default: true)
    {auth_enabled, true},

    %% Trust mode: tofu | strict (default: tofu)
    {auth_trust_mode, tofu},

    %% Directory for keys (default: "data/keys")
    {auth_key_dir, "data/keys"}
]}
```

## Examples

### Example 1: TOFU Mode (Default)

No configuration needed. Nodes auto-trust on first connection:

```erlang
%% Node 1
1> application:ensure_all_started(mycelium).

%% Node 2 - joins and is automatically trusted
1> application:ensure_all_started(mycelium).
2> mycelium:join('node1@host1').
ok

%% Node 1 now has node2's key stored
3> mycelium_dist_keys:list_trusted().
[{peer_key, 'node2@host2', <<...>>, 1234567890, 1234567890, tofu}]
```

### Example 2: Strict Mode Setup

**Step 1: Generate keys on each node**

```bash
# On each node, start mycelium once to generate keys
erl -sname node1 -eval "application:ensure_all_started(mycelium), init:stop()."
```

**Step 2: Collect public keys**

```bash
# Copy public keys to a central location
scp node1:data/keys/node.pub /keys/node1@host1.pub
scp node2:data/keys/node.pub /keys/node2@host2.pub
scp node3:data/keys/node.pub /keys/node3@host3.pub
```

**Step 3: Distribute to all nodes**

```bash
# Each node needs all other nodes' keys
for node in node1 node2 node3; do
    scp /keys/*.pub $node:data/keys/trusted/
done
```

**Step 4: Configure strict mode**

```erlang
%% sys.config on all nodes
{mycelium, [
    {auth_trust_mode, strict}
]}
```

**Step 5: Start cluster**

```erlang
%% Nodes can now connect with pre-verified keys
mycelium:join('node1@host1').
```

### Example 3: Adding a New Node to Strict Cluster

```erlang
%% On new node: get public key
{ok, MyPubKey} = mycelium_dist_auth:get_public_key().
io:format("~s~n", [binary:encode_hex(MyPubKey)]).
%% Copy this to existing nodes

%% On existing nodes: register new node
NewPubKey = binary:decode_hex(<<"a1b2c3...">>).
mycelium_dist_keys:store_key('newnode@host', NewPubKey).

%% Now new node can join
mycelium:join('existingnode@host').
```

### Example 4: Key Rotation

```erlang
%% On node being rotated: generate new keypair
{NewPub, NewPriv} = mycelium_dist_auth:generate_keypair().
mycelium_dist_auth:save_keypair("data/keys", NewPub, NewPriv).

%% Distribute new public key to all peers
%% On each peer:
mycelium_dist_keys:delete_key('rotated@host').
mycelium_dist_keys:store_key('rotated@host', NewPubKey).

%% Restart rotated node
```

### Example 5: Runtime Mode Switch

```erlang
%% Start in TOFU mode for easy bootstrap
{mycelium, [{auth_trust_mode, tofu}]}

%% After cluster is established, switch to strict
mycelium_dist_keys:set_trust_mode(strict).

%% New nodes will now be rejected unless pre-registered
```

## Security Considerations

1. **Protect private keys** - `node.key` should have restrictive permissions (0600)

2. **Secure key distribution** - Use encrypted channels (SSH, TLS) when copying keys

3. **TOFU window** - In TOFU mode, the first connection is vulnerable. Consider:
   - Using strict mode in production
   - Manually verifying keys after TOFU establishment
   - Using out-of-band key verification

4. **Key mismatch warnings** - Always investigate `key_mismatch` errors:
   ```
   Key mismatch for node 'foo@bar' - existing key differs from presented key
   ```
   This could indicate a MITM attack or uncoordinated key rotation.

5. **Clock synchronization** - Challenge timestamps have a 30-second window. Ensure nodes have synchronized clocks (NTP).

## Disabling Authentication

For development/testing only:

```erlang
{mycelium, [
    {auth_enabled, false}
]}
```

This disables the challenge-response handshake entirely. **Never use in production.**
