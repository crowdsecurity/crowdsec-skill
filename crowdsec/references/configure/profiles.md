# Configure — Profiles (decisions, durations, simulation)

Canonical docs: <https://docs.crowdsec.net/docs/next/local_api/profiles> · post-install profiles <https://docs.crowdsec.net/docs/next/getting_started/post_installation/profiles>

A scenario firing produces an **alert**. Whether that alert becomes a **decision** (a ban,
captcha, etc.) is decided by `profiles.yaml`, evaluated at LAPI. This is the layer that
answers the #2 support question: *"I see alerts but nothing gets banned."*

## Alert → decision flow

1. A scenario overflows → LAPI receives an **alert**.
2. LAPI walks `profiles.yaml` **top to bottom**. For each profile whose `filters` match the
   alert, it emits that profile's `decisions`.
3. `on_success: break` stops after the first matching profile (the default). Without it,
   later profiles can also match and stack decisions.
4. The decision is written — **unless** the target is allowlisted (silently dropped) or
   simulation is on (written but flagged, not enforced).

### Why an alert produces no ban

| Cause | How to confirm |
|---|---|
| Target is allowlisted (incl. loopback `127.0.0.1` via `crowdsecurity/whitelists`) | Alert exists, `decisions` column empty. `cscli allowlists check <ip>`. See [allowlists.md](./allowlists.md). |
| Simulation mode on (global or per-scenario) | `cscli simulation status`; decision shows `(simul)` action |
| No profile `filters` match the alert | The alert's scope/value doesn't satisfy any filter expression |
| AppSec out-of-band rule | Alert `kind: waf` with empty `decisions` — it's asynchronous, not an inline block (see [../appsec/troubleshoot.md](../appsec/troubleshoot.md)) |
| Filter expression typo | Silent no-op — the expr just never matches |

## `profiles.yaml` structure

Default `/etc/crowdsec/profiles.yaml` (two profiles, IP and Range), trimmed:

```yaml
name: default_ip_remediation
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
 - type: ban
   duration: 4h
# duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 4)
# notifications:
#   - slack_default
on_success: break
---
name: default_range_remediation
filters:
 - Alert.Remediation == true && Alert.GetScope() == "Range"
decisions:
 - type: ban
   duration: 4h
on_success: break
```

| Key | Meaning |
|---|---|
| `name` | Identifier (appears in logs). |
| `filters` | List of [expr](https://docs.crowdsec.net/docs/next/expr/intro) expressions against the `Alert` object. Any one matching makes the profile apply. |
| `decisions` | What to emit: `type` + `duration` (and optional `scope`). |
| `duration` | Static TTL — `4h`, `30m`, `168h`, etc. |
| `duration_expr` | Dynamic TTL (expr). Overrides `duration`. Used for escalation. |
| `on_success` | `break` (stop here) or omit (keep evaluating later profiles). |
| `notifications` | Plugin names to fire (see [notifications.md](./notifications.md)). |

### Decision types

| `type` | Effect | Notes |
|---|---|---|
| `ban` | Block the IP/range | The default; every bouncer enforces it. |
| `captcha` | Serve a challenge | Only **web-server / AppSec bouncers** can render captcha; a firewall bouncer can't and treats it as no-op. Needs captcha provider config. |
| `throttle` | Rate-limit | Bouncer-dependent support. |

### Escalation with `duration_expr`

Longer bans for repeat offenders — uncomment in the default profile:

```yaml
duration_expr: Sprintf('%dh', (GetDecisionsCount(Alert.GetValue()) + 1) * 4)
```

First offense → 4h, second → 8h, and so on. `GetDecisionsCount` queries prior decisions for
that value.

## Simulation mode — safe rollout

Simulation lets scenarios fire and decisions be recorded **without enforcing them** — ideal
for tuning before going live.

```bash
sudo cscli simulation status            # global simulation: disabled
sudo cscli simulation enable --global   # all scenarios simulated (note: bare 'enable' just prints help)
sudo cscli simulation enable crowdsecurity/ssh-bf   # one scenario only
sudo cscli simulation disable --global
sudo systemctl reload crowdsec          # REQUIRED — the toggle is read at load
```

Under simulation, the decision still appears in the list but the action is prefixed
`(simul)` and **no bouncer enforces it**:

```
| ID | ... |          Reason           |   Action   | ... |
| 5  | ... | crowdsecurity/ssh-slow-bf | (simul)ban | ... |
```

## Verify a profile change

```bash
sudo cscli simulation status                      # know your baseline first
# edit /etc/crowdsec/profiles.yaml
sudo crowdsec -t                                  # validate — silent + exit 0 = OK
sudo systemctl reload crowdsec
# trigger the scenario (or, to test plumbing only, add a manual decision):
sudo cscli decisions add --ip 203.0.113.77 --duration 4h --reason test
sudo cscli decisions list                          # confirm Action + expiration match the profile
sudo cscli decisions delete --ip 203.0.113.77
```

To confirm the *type/duration a real alert yields*, feed the scenario and read the decision
row — `Action` (e.g. `ban`) and `expiration` (e.g. `3h59m54s` for a 4h ban) reflect the
profile that matched.

## Pitfalls

- **`cscli profiles list` does not exist** (through at least v1.7.8). Read the file:
  `sudo cat /etc/crowdsec/profiles.yaml`.
- **Filter typos are silent.** A misspelled field or `==`/`=` slip just never matches — no
  error, no decision. Test against a known-firing scenario.
- **Profile order + `on_success: break`.** The first matching profile with `break` wins;
  put narrower profiles above broader ones.
- **Reload required.** Editing `profiles.yaml` or toggling simulation does nothing until
  `systemctl reload crowdsec` (or container recreate / `helm upgrade`).
- **Allowlist beats profile.** Even a perfect filter match is dropped at write time if the
  target is allowlisted. To exempt IPs, use an [allowlist](./allowlists.md), not a profile
  filter expression.
- **`captcha` needs a capable bouncer.** A firewall bouncer can't render a challenge — use a
  web-server/AppSec bouncer for captcha decisions.

## Per-environment notes

| Env | What changes |
|---|---|
| **systemd / bare-metal** | Edit `/etc/crowdsec/profiles.yaml`, `crowdsec -t`, `systemctl reload crowdsec`. |
| **Docker / compose** | Bind-mount `profiles.yaml` from the host (`./profiles.yaml:/etc/crowdsec/profiles.yaml`). Recreate or send a reload to apply. cscli via `docker exec <name> cscli ...`. |
| **Kubernetes / Helm** | Provide `profiles.yaml` via the chart's config values / a mounted ConfigMap; `helm upgrade --reset-then-reuse-values`. cscli via `kubectl exec -n <ns> <lapi-pod> -- cscli ...`. |
