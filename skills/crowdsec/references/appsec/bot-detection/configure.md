---
verified:
  - date: 2026-08-31
    version: "1.8.0"
    env: systemd
    notes: "challenge: block via overlay — master_secret silences the warning, cookie_ttl 2h applied; difficulty levels + invalid-level error"
---

# Tune the challenge runtime

Canonical docs: <https://docs.crowdsec.net/docs/next/appsec/bot_detection/configuration>

The `challenge:` block is a **top-level key in any appsec-config** (a sibling of `name:` and
`inband:`, not nested under them). Every loaded appsec-config contributes, merged field by
field with last-non-nil winning — so never edit the hub files. Ship a small overlay instead:

```yaml
# /etc/crowdsec/appsec-configs/mycorp-overlay.yaml
name: mycorp/appsec-bot-challenge-overlay

challenge:
  master_secret: "efb7789044ed092ae90c139848be7687652920064dccc40db1eeb926a8050930"
  cookie_ttl: 2h
```

and list it by name in `appsec_configs:` — the `crowdsecurity/appsec-bot-*` glob will not
pick up your namespace ([./deploy.md](./deploy.md) § 2).

## Keys

| Key | Default | What it does |
|---|---|---|
| `master_secret` | random, ephemeral | Root of every derived signing key and the cookie-sealing key. Hex ≥64 chars (preferred) or a passphrase ≥32 bytes. |
| `key_rotation_interval` | `5m` | How often the per-epoch signing key advances. Minimum 30s. |
| `max_live_epochs` | `3` | Past epochs still accepted, so a rotation does not invalidate in-flight submissions. A client has `(max_live_epochs + 1) × key_rotation_interval` to solve. |
| `cookie_ttl` | `12h` | Success-cookie lifetime. Sealed under a separate long-lived key, so key rotation does **not** invalidate issued cookies. |
| `crypto_obfuscation_pool_size` | `1` | Distinct obfuscations of the per-epoch key module, for per-visitor variance. Costs roughly 5s CPU per variant per rotation. |
| `max_cookie_size` | `4096` | Byte cap on the sealed cookie, enforced on seal and open. Bounds an over-allocation DoS. Raise only for non-browser clients. |
| `spent_set_max_entries` | `1000000` | Replay-protection LRU — a solved challenge cannot be submitted twice. |
| `log_level` | inherits global | Verbosity of the challenge runtime only. See [./troubleshoot.md](./troubleshoot.md) § 8. |

Confirm what actually took effect — the runtime logs its resolved settings at startup:

```
level=info msg="WAF challenge runtime initialized" cookie_ttl=2h0m0s crypto_pool_size=1 max_cookie_len=4096 module=challenge pow_difficulty=20 rotation_interval=5m0s
```

## Multi-instance — the one that bites

With no `master_secret`, each instance generates a random one at startup and every instance
rejects the others' cookies, so clients re-challenge on every request that lands on a
different node. Restarts have the same effect on a single node. The engine warns:

```
level=warning msg="no master secret configured for the WAF challenge runtime; generated an ephemeral random secret. Distributed (multi-WAF) deployments MUST configure a shared master_secret in the appsec config; single-instance deployments will see outstanding challenge cookies invalidated on restart." module=challenge
```

Behind a load balancer, or on more than one AppSec instance, set it — and set
`key_rotation_interval` and `max_live_epochs` identically everywhere, since keys derive from
both.

```bash
openssl rand -hex 32
```

Rotating the secret: roll the new value out to **every** instance inside one `cookie_ttl`
window, then restart each. During the rollout, clients holding old cookies are challenged
once more; they are not blocked.

| Change | Invalidates |
|---|---|
| `master_secret` | Issued cookies **and** in-flight challenges |
| `key_rotation_interval`, `max_live_epochs` | In-flight challenges only |
| `cookie_ttl` | Nothing — applies to newly issued cookies |
| `crypto_obfuscation_pool_size` | Nothing — applies at the next rotation tick |

Treat the secret as a credential: a Kubernetes `Secret` projected into the log-processor's
appsec-config, or a Docker secret / bind-mounted file — not a value committed next to the
manifest. The appsec-config itself is a plain file at
`/etc/crowdsec/appsec-configs/` (systemd), a mounted path in the same directory (docker), or
an entry in the log-processor ConfigMap (k8s).

## Difficulty

Proof-of-work cost in leading zero bits. Calibrated for a low-end 2-core phone; a desktop is
roughly 20× faster.

| Level | Bits | Low-end mobile | Desktop |
|---|---|---|---|
| `disabled` | 0 | instant | instant |
| `low` | 18 | ~0.5s | ~0.03s |
| `medium` **(default)** | 20 | ~2s | ~0.10s |
| `high` | 22 | ~8s | ~0.41s |
| `impossible` | 256 | never solvable — a deliberate hard block, rejected server-side with no reason leaked |

There is no `challenge:` key for the default level. Set it per request from a hook —
`SetChallengeDifficulty("high")` in `pre_eval` or `on_challenge`
([./customize.md](./customize.md)). An unknown level is not a startup error; it fails per
request at runtime and the request is still challenged at the default:

```
level=error msg="unable to apply appsec pre_eval[inband] expr: unknown challenge difficulty \"extreme\" (expected disabled, low, medium, high, or impossible)"
```

Raising difficulty is a poor bot deterrent on its own — a determined scraper has more CPU
than a phone. Use it to slow down abuse of a specific expensive route, and rely on
fingerprint scoring to actually identify bots.
