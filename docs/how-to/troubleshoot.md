# Troubleshooting

A table per category, ordered by how often we see each symptom in
practice. Every row gives a likely cause and a place to look.

The structure of every cell: what you see, what is probably
happening, and the code or configuration to inspect. Where the
fix is simple, it is included; where it requires a runbook, the
relevant doc is linked.

## A node fails to boot

| Symptom                                                            | Likely cause                                                        | What to do                                                                                                                |
|--------------------------------------------------------------------|---------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `Protocol 'quic': register/listen error: {credentials,no_credentials}` | TLS material missing, listener cannot find a cert/key             | Check `data/quic/node.crt` and `data/quic/node.key` exist and are readable. Run `priv/bin/barrel_p2p_gen_cert.sh` to generate by hand. |
| `barrel_p2p_dist: cert ensure failed: <reason>`                      | Cert directory is not writable                                      | Confirm `auth_key_dir` / `quic_cert_dir` point to a writable path. Check disk quota.                                       |
| Boot fails with `{barrel_p2p_dist, auth_enabled_without_callback}`   | `barrel_p2p.auth_enabled = true` but the projected `auth_callback` is `undefined` (you set it explicitly) | This is fail-safe behaviour. Either set `auth_enabled = false` or do not override the auth callback.                       |
| `Failed to initialize keypair: <reason>`                           | Cannot write to `auth_key_dir`                                      | Verify filesystem permissions and free space.                                                                              |
| `{error, keypair_mismatch}` on load                                | Identity rotation crashed mid-flight; `node.pub` does not derive from `node.key` | Restore from the most recent `data/keys/backups/<ts>/` or regenerate with `barrel_p2p_rotate:rotate_identity/0`.            |

## A peer cannot connect

| Symptom                                                            | Likely cause                                                                  | What to do                                                                                                                                  |
|--------------------------------------------------------------------|-------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `Key mismatch for node <peer> - existing key differs from presented key` | A peer's identity rotated, or someone is impersonating it                | If you just rotated keys, delete the stale pin and let TOFU re-pin (`barrel_p2p_dist_keys:delete_key/1`). Otherwise treat as a security event. |
| `{auth_rejected, untrusted_key}`                                   | Strict mode, no pin for this peer                                             | Provision the peer's public key (`barrel_p2p_dist_keys:store_key/2`) or switch to TOFU.                                                       |
| `auth_stream_timeout`                                              | The handshake did not complete within `auth_handshake_timeout` (default 10s) | Inspect the network between peers. Raise the timeout if the link is genuinely slow.                                                          |
| `{auth_rejected, signature_invalid}`                               | Wrong private key in use, or clock skew beyond the wall-time window           | Verify the keypair on disk derives correctly (`barrel_p2p_dist_auth:load_keypair/1`); check `auth_timestamp_window` and NTP.                  |
| `{error, unexpected_auth_ok}`                                      | A server sent AUTH_OK but the client did not have the target in its own `cookie_only_nodes` | Cookie-only is symmetric: both ends must list the peer. Either provision the whitelist on both sides or remove `cookie_only_nodes`.       |
| `Pid ! Msg` returns immediately but the peer never receives        | Dist channel silently closed (reaped, or remote `nodedown`)                   | Check `erlang:nodes/0` on both sides; check the `barrel_p2p.dist_gc.reap` rate; resend (auto-connect will reopen).                              |

## A new node cannot find the cluster

| Symptom                                                                                 | Likely cause                                                              | What to do                                                                                                                  |
|-----------------------------------------------------------------------------------------|---------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| `barrel_p2p:active_view/0` always empty                                                   | Discovery chain returns nothing for the contact nodes                     | Inspect each backend in `barrel_p2p.discovery_backends`. The file backend needs a shared directory; the DNS backend needs records. |
| `barrel_p2p_discovery_dns: no records for <host>` in the log                              | DNS records missing                                                       | Confirm the zone publishes records for the host portion of every node atom.                                                  |
| File-based discovery: peer not visible to other hosts                                   | Discovery directory is local to each host                                 | Mount a shared volume; use rsync/NFS; or switch to the DNS backend.                                                           |
| `[barrel_p2p_app] no listen port found; skipping discovery publish`                        | The QUIC listener did not bind, or the node is not running `-proto_dist barrel_p2p` | Confirm the listener bound (`netstat -unlp \| grep beam`). Confirm `-proto_dist barrel_p2p` in your boot args.                       |

## Cluster membership instability

| Symptom                                                            | Likely cause                                                          | What to do                                                                                                            |
|--------------------------------------------------------------------|-----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| Nodes oscillate in and out of the active view                      | Network instability or `max_fail_count` too low                       | Inspect `barrel_p2p.hyparview.peer_down` by `reason`. Tune `max_fail_count`, `base_backoff_ms`.                          |
| Active view grows past `active_size`                               | Should not happen post-decoupling; HyParView caps the active view itself | Confirm the running build. `barrel_p2p:active_view/0` should never exceed `active_size`; `erlang:nodes/0` may legitimately be larger. |
| `peer_up`/`peer_down` events arrive in unexpected orders            | Multiple shuffles interleaving                                         | Order is best-effort; consume both events and treat them as state transitions, not strict sequences.                  |

## Discovery and ports

| Symptom                                                            | Likely cause                                                          | What to do                                                                                                            |
|--------------------------------------------------------------------|-----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| Connection refused on the dist port                                | Firewall, or `listen_port` not what you think                          | `netstat -unlp \| grep beam` shows the actual port; check container or host firewall rules.                            |
| A new container cannot reach existing peers                        | docker-compose discovery shares no state between containers            | Provide a static topology (see `docker/cluster-topology.config` in the project), or share a volume for the file backend. |

## Idle dist-channel GC

| Symptom                                                            | Likely cause                                                          | What to do                                                                                                            |
|--------------------------------------------------------------------|-----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `barrel_p2p.dist_gc.reap` rate is high                               | Application opens dist channels faster than GC's `min_age`             | Raise `dist_gc_min_age_ms` so transient sends do not get reaped mid-conversation.                                      |
| Streams on a non-active peer keep disappearing                     | Stream owners are short-lived pids; GC sees no live owner             | Pin a long-lived owner pid for any stream you expect to outlive the call that opened it.                                |
| GC never reaps anything                                            | Every peer is in active view or carries a live stream                  | This is correct behaviour; no action needed.                                                                          |

## Cookies and Erlang dist handshake

| Symptom                                                            | Likely cause                                                          | What to do                                                                                                            |
|--------------------------------------------------------------------|-----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| `{exit, normal}` immediately after dist handshake start            | Cookie mismatch                                                       | Set `barrel_p2p.dist_cookie` to the same value on every node; `barrel_p2p_app` applies it at start.                        |
| Peer "connects" but `nodes/0` shows only the local node            | Proto_dist mismatch or cookie mismatch                                 | Confirm both sides have `-proto_dist barrel_p2p` and the same cookie atom.                                              |

## Metrics absent or zero

| Symptom                                                            | Likely cause                                                          | What to do                                                                                                            |
|--------------------------------------------------------------------|-----------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|
| No `barrel_p2p.*` instruments in the exporter                        | `instrument` not started, or no exporter wired                         | `application:which_applications/0` must show `instrument`. Confirm the exporter (Prometheus/OTLP/live) is started.    |
| Counters present but always zero                                   | The code path never fired on this run                                  | Cross-check the seam in the relevant module (`barrel_p2p_hyparview_events`, `barrel_p2p_dist_auth_stream`, `barrel_p2p_plumtree`, `barrel_p2p_dist_gc`). |
| `dist.auth.attempts{outcome=fail}` rising                          | Something rejected the handshake (key, cookie, clock, mode)            | Skim the recent log for `key_mismatch`, `untrusted_key`, `signature_invalid`, `auth_stream_timeout`.                  |

## When to look at logs vs metrics

- **Metrics** are good for "is something happening at the wrong
  rate". Use them for paging, dashboards, capacity planning.
- **Logs** are good for "what was the specific reason". The auth
  rejection log lines carry the node atom and (for key mismatch)
  the fingerprints; the discovery log lines carry the host that
  failed to resolve.

Both layers share a vocabulary; if you see `key_mismatch` in a
log, expect the `dist.auth.attempts{outcome=fail}` counter to
have moved at the same time.
