# Authoring — scenarios

Canonical docs: format <https://docs.crowdsec.net/docs/next/log_processor/scenarios/format> · create <https://docs.crowdsec.net/docs/next/log_processor/scenarios/create> · taxonomy <https://github.com/crowdsecurity/hub/tree/master/taxonomy>

## Skeleton

```yaml
type: leaky
name: alice/myservice-bf
description: "Detect myservice bruteforce"
filter: "evt.Meta.service == 'myservice' && evt.Meta.log_type == 'myservice_failed_auth'"
groupby: evt.Meta.source_ip
capacity: 5
leakspeed: 10s
blackhole: 1m
labels:
  service: myservice
  confidence: 3
  spoofable: 0
  classification:
    - attack.T1110
  behavior: "generic:bruteforce"
  label: "Myservice Bruteforce"
  remediation: true
```

Multiple scenarios in one file are separated by `---`; each document needs a `name` (hublint).

## Bucket types

| Type | Use | Required |
|---|---|---|
| `leaky` (222 in hub) | rate-based: bruteforce, scans | `capacity`, `leakspeed` |
| `trigger` (100) | one event is enough: CVE exploitation, honeypot | none; overflows on first event |
| `conditional` (10) | look back at the queue: impossible travel, success-after-failures | `condition`, `capacity: -1`, `leakspeed` |
| `counter` | count over `duration` | `capacity: -1`, `duration` |
| `bayesian` | combine weak signals | `bayesian_*`, `capacity: -1` |

## Thresholds — what reviewers check

- **`leakspeed` is "one event leaks every X"**, not "N events in X" (#1461).
  Overflow when more than `capacity` events are held.
- Common hub values: `capacity: 5, leakspeed: 10s` (68 scenarios), `5/1m`, `5/20s`.
  Bruteforce at `leakspeed: 2m` is too slow; `30s` can catch humans mistyping (#459).
  **Explain your capacity/leakspeed choice in the PR** (docs).
- **`blackhole`** only suppresses re-alerts from the same bucket; it is **not** the
  ban duration. Use `1m`–`5m` (166 and 100 scenarios); `4h`/`10h` get rejected (#1461, #1798).
  A `blackhole` without `groupby` blackholes everyone (#942).
- `distinct` (e.g. `evt.Meta.http_path`) to count unique values, e.g. probing.
- Large capacities hold events in memory: set `cache_size` (#918). Alerts keep
  only `cache_size` events — postoverflows see only those.
- Slow / very slow tiers must not overlap with the fast one, or one attacker
  triggers three alerts; follow the ssh model (bf → slow-bf → time-based-bf
  with `conditional` + median interval helpers) (#1696).

## Filter and grouping

- Filter on `log_type` **and** `service` when `log_type` could be generic (#1191).
- `groupby: evt.Meta.source_ip` (291 scenarios). Per-site grouping
  (`source_ip + '/' + target_fqdn`) splits buckets per vhost: fewer FPs on
  multi-site hosts but less sensitivity, and `Host` is client-controlled.
- User-enumeration variants: group by IP, `distinct` on the username, name them
  `…-user-enum` (#758, #333, #430).
- Use `Meta` fields in `condition`/`filter`, not `Unmarshaled` internals (#750).
- `reprocess: true` re-injects the **overflow** (one event of type OVFLW) into the
  pipeline for meta-scenarios; it can't multiply log events, and every overflow
  is also an alert.

## Labels (validated by the taxonomy CI)

| Label | Rule |
|---|---|
| `service` | product or protocol |
| `behavior` | must exist in `taxonomy/behaviors.json` (`http:bruteforce`, `http:exploit`, `http:scan`, `ssh:bruteforce`, `generic:bruteforce`, `generic:scan`, `smtp:spam`, …) |
| `classification` | `attack.Txxxx[.xxx]` (MITRE, validated against `mitre_attack.json`), `cve.CVE-YYYY-N`, `cwe.CWE-N`; must match the actual CVE (#983) |
| `confidence` | int 0–3: likelihood of **no** false positive (3 = 262 scenarios) |
| `spoofable` | int 0–3: 0 for TCP-based sources (312 scenarios) |
| `label` | short human name, consistent wording with existing items ("Myservice Bruteforce", "Myservice User Enumeration") (#325, #963) |
| `remediation` | `true` to ban; `false` for audit/info scenarios |
| `intent` | optional override; must be a valid intent from behaviors.json |
| `cti: false` | optional: audit-only, not threat intel |

Missing `behavior`/`spoofable`/`confidence`/`label` → taxonomy CI error comment.
Copy MITRE labels from a similar existing scenario (#862).

## Scope beyond IPs

`scope: {type: <name>, expression: <expr>}` for non-IP decisions (username,
range…). Reuse existing scope names for consistency (#684).

## Design judgment (why scenarios get rejected)

- Will it fire on legitimate traffic? Single-request triggers on paths that legit
  clients hit = FPs (#406, #245). Keep FP-prone scenarios out of default collections.
- Does it duplicate an existing scenario? (#1944, #1762)
- Is the signal consistent across deployments? (spam-score configurable → #830 closed)
- Is it bespoke to one deployment? → local config, not hub (#1870, #625).
- Don't modify default values of existing popular scenarios to fit your setup (#245).
