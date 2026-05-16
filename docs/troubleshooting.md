# Troubleshooting

Symptoms an operator sees, and where to look. Each row cites the log
callsite that emits the message; grep your logs for the quoted text.

## Boot failures

| Symptom                                                  | Likely cause                                         | Where to look                                                 |
|----------------------------------------------------------|------------------------------------------------------|---------------------------------------------------------------|
| `mycelium_dist: cert ensure failed: <reason>`            | TLS material cannot be generated or read on disk     | `src/mycelium_dist.erl` `ensure_cert/0`. Check `quic_cert_dir` env points to a writable path; check disk permissions on `node.crt` / `node.key`. |
| `{boot_failed, {exit_status, 1}}` under `peer:start`     | code path not propagated to the new VM               | Pass `-pa` flags from `code:get_path()` explicitly when calling `peer:start`. |
| Cluster refuses to start with `{credentials, no_credentials}` | Cert pair missing and lazy generation disabled  | Run `priv/bin/mycelium_gen_cert.sh` manually, or check `mycelium_quic_cert:ensure_cert/1` is reachable from the boot path. |
| `[mycelium_app] no listen port found; skipping discovery publish` | quic_dist listener hasn't bound yet, or app started without `-proto_dist mycelium` | Confirm the listener actually came up. The discovery publish is best-effort; this is benign on a transient race but persistent appearance indicates the dist module is wrong. |

## Authentication

| Symptom                                                  | Likely cause                                         | Where to look                                                 |
|----------------------------------------------------------|------------------------------------------------------|---------------------------------------------------------------|
| `Failed to initialize keypair: <reason>`                 | `~/.mycelium/keys` (or configured `key_dir`) unwritable | `src/mycelium_dist_keys.erl:127`. Check filesystem permissions and disk space. |
| `Key mismatch for node <peer> - existing key differs from presented key` | Peer's Ed25519 identity changed (rotation or attack) | `src/mycelium_dist_keys.erl:172`. If you just rotated keys on the peer, remove the stale entry from the local trust store and let TOFU re-pin it. Otherwise treat as a security event. |
| `{auth_rejected, untrusted_key}`                         | Strict trust mode and no pinned key for peer         | Set `auth_trust_mode=tofu` to allow first-contact pinning, or pin the key explicitly via `mycelium_dist_keys:store_key/3`. |
| `auth_stream_timeout`                                    | Peer didn't complete the handshake within the window | Bump `auth_handshake_timeout` (default 10000ms), or check for network loss / peer overload. |
| `{auth_rejected, signature_invalid}`                     | Wrong private key in use, or replay-window mismatch  | Verify the key on disk matches the published pub key; check `auth_timestamp_window` is in sync with peer clock. |

## Cluster membership

| Symptom                                                  | Likely cause                                         | Where to look                                                 |
|----------------------------------------------------------|------------------------------------------------------|---------------------------------------------------------------|
| `mycelium:active_view()` always empty                    | Discovery chain can't resolve other nodes            | Inspect `mycelium_discovery:lookup/1` output. The file backend needs all nodes to share the discovery dir; the DNS backend needs records to exist. |
| `Pid ! Msg` returns immediately but peer never receives  | Dist connection silently dropped or peer down        | Check `erlang:nodes()` on both sides and the metric `mycelium.dist_gc.reap` rate. A reaped peer needs a fresh `Pid ! Msg` to re-open the channel. |
| Active view grows beyond `active_size`                   | Stale entries from before the decoupling fix         | Expected post-fix: HyParView treats `active_view` as protocol membership only. `erlang:nodes()` can legitimately be larger; `mycelium_dist_gc` keeps it bounded. |
| Nodes oscillate in and out of the active view            | Network instability or `max_fail_count` too low      | Tune `max_fail_count`, `base_backoff_ms`, `passive_max_age_ms`. Watch `mycelium.hyparview.peer_down` by `reason`. |

## Discovery

| Symptom                                                  | Likely cause                                         | Where to look                                                 |
|----------------------------------------------------------|------------------------------------------------------|---------------------------------------------------------------|
| `mycelium_discovery_file:register/3` crashes on string input | (Fixed in 0.2.x.) Backend used to require atom only | Already accepts atom, binary, and string. If you still see this, you are on an old build. |
| `mycelium_discovery_dns: no records for <host>`          | DNS SRV/A records missing                            | `src/mycelium_discovery.erl:69` warning. Confirm the zone publishes records for the host portion of every node name. |
| File-based discovery: peer not found                     | Discovery dir not shared across hosts                | All cluster nodes must read and write the same directory. On Kubernetes use a shared volume; on bare metal use NFS or rsync. |

## Idle dist GC

| Symptom                                                  | Likely cause                                         | Where to look                                                 |
|----------------------------------------------------------|------------------------------------------------------|---------------------------------------------------------------|
| `mycelium.dist_gc.reap` rate consistently high           | App opens dist channels faster than GC's min-age     | Raise `dist_gc_min_age_ms` so transient sends don't get reaped mid-conversation. |
| Streams on a non-active peer keep disappearing           | App used short-lived processes to own streams        | Pin a long-lived owner pid; the GC won't reap channels with live streams, but it can't see a stream owned by a dead process. |
| GC never reaps anything                                  | Every peer is either active-view or carries streams  | This is correct behavior. Confirm by checking the predicate in `src/mycelium_dist_gc.erl:132`. |

## Cookie / dist handshake

| Symptom                                                  | Likely cause                                         | Where to look                                                 |
|----------------------------------------------------------|------------------------------------------------------|---------------------------------------------------------------|
| `{exit, normal}` immediately after dist handshake start  | Cookie mismatch                                      | Set `mycelium.dist_cookie` consistently across the cluster; `mycelium_app:init_dist_cookie/0` applies the env to every node. |
| Peer connects but `nodes()` shows only itself            | Cookie or proto_dist mismatch                        | Confirm both sides use `-proto_dist mycelium` and the same cookie atom. |

## Metrics absent

| Symptom                                                  | Likely cause                                         | Where to look                                                 |
|----------------------------------------------------------|------------------------------------------------------|---------------------------------------------------------------|
| No `mycelium.*` instruments visible in exporter          | `instrument` app not started, or no exporter wired   | `application:which_applications()` must show `instrument`. Confirm the exporter (`instrument_prometheus`, OTLP, or `instrument_live`) is started. |
| Counters present but always zero                         | Code path didn't fire on this run                    | Check `mycelium_metrics` callsites and the corresponding seam in `src/mycelium_hyparview_events.erl`, `mycelium_dist_auth_stream.erl`, `mycelium_plumtree.erl`, `mycelium_dist_gc.erl`. |
