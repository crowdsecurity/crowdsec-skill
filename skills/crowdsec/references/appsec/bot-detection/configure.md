---
verified:
  - date: 2026-08-31
    version: "1.8.0"
    env: systemd
    notes: "challenge: block via overlay — master_secret silences the warning, cookie_ttl 2h applied; difficulty levels + invalid-level error"
---

# Challenge runtime configuration

Canonical: <https://docs.crowdsec.net/docs/next/appsec/bot_detection/configuration>

`challenge:` is a **top-level key in any appsec-config** (sibling of `name:` and `inband:`).
Every loaded appsec-config contributes, merged field by field, last non-nil winning. Never edit
hub files — ship an overlay and list it by name in `appsec_configs:`
([./deploy.md](./deploy.md) § 2):

```yaml
# /etc/crowdsec/appsec-configs/mycorp-overlay.yaml
name: mycorp/appsec-bot-challenge-overlay

challenge:
  master_secret: "<64+ hex chars; generate with: openssl rand -hex 32>"
  cookie_ttl: 2h
```

| Key | Default | Purpose |
|---|---|---|
| `master_secret` | random, ephemeral | Root of every derived signing key and the cookie-sealing key. Hex ≥64 chars, or passphrase ≥32 bytes. |
| `key_rotation_interval` | `5m` | Per-epoch signing key advance. Minimum 30s. |
| `max_live_epochs` | `3` | Past epochs still accepted. A client has `(max_live_epochs + 1) × key_rotation_interval` to solve. |
| `cookie_ttl` | `12h` | Success-cookie lifetime. Sealed under a separate long-lived key, so key rotation does not invalidate issued cookies. |
| `crypto_obfuscation_pool_size` | `1` | Obfuscation variants of the per-epoch key module. ~5s CPU per variant per rotation. |
| `max_cookie_size` | `4096` | Byte cap on the sealed cookie, enforced on seal and open. Bounds an over-allocation DoS. |
| `spent_set_max_entries` | `1000000` | Replay-protection LRU — a solved challenge cannot be resubmitted. |
| `log_level` | inherits global | Challenge runtime only — [./troubleshoot.md](./troubleshoot.md) § 8. |

Resolved settings are logged at startup:

```
level=info msg="WAF challenge runtime initialized" cookie_ttl=2h0m0s crypto_pool_size=1 max_cookie_len=4096 module=challenge pow_difficulty=20 rotation_interval=5m0s
```

## Multi-instance

Without `master_secret`, each instance generates a random one at startup and rejects the
others' cookies, so clients re-challenge on every request landing elsewhere; restarts do the
same on a single node (the engine warns — see [./troubleshoot.md](./troubleshoot.md) § 4).
Behind a load balancer or on more than one AppSec instance, set it with `openssl rand -hex 32`,
and set `key_rotation_interval` and `max_live_epochs` identically everywhere, since keys derive
from both.

Rotation: roll the new value to every instance inside one `cookie_ttl` window, then restart
each. Clients holding old cookies are challenged once more, not blocked.

| Change | Invalidates |
|---|---|
| `master_secret` | Issued cookies **and** in-flight challenges |
| `key_rotation_interval`, `max_live_epochs` | In-flight challenges only |
| `cookie_ttl` | Nothing — applies to newly issued cookies |
| `crypto_obfuscation_pool_size` | Nothing — applies at the next rotation tick |

Treat the secret as a credential: a Kubernetes `Secret` projected into the log-processor's
appsec-config, or a Docker secret / bind-mounted file.

## Difficulty

PoW cost in leading zero bits, calibrated for a low-end 2-core phone; desktops are ~20× faster.

| Level | Bits | Low-end mobile | Desktop |
|---|---|---|---|
| `disabled` | 0 | instant | instant |
| `low` | 18 | ~0.5s | ~0.03s |
| `medium` **(default)** | 20 | ~2s | ~0.10s |
| `high` | 22 | ~8s | ~0.41s |
| `impossible` | 256 | never solvable — hard block, rejected server-side, no reason leaked | |

No `challenge:` key sets the default level; set it per request with
`SetChallengeDifficulty("high")` in `pre_eval` or `on_challenge`
([./customize.md](./customize.md)). An unknown level is a per-request runtime error, not a
startup failure, and the request is still challenged at the default:

```
level=error msg="unable to apply appsec pre_eval[inband] expr: unknown challenge difficulty \"extreme\" (expected disabled, low, medium, high, or impossible)"
```

Difficulty is a weak deterrent — a scraper has more CPU than a phone. Use it to slow abuse of a
specific expensive route; rely on fingerprint scoring to identify bots.
