# AppSec — Troubleshoot

Canonical docs: <https://docs.crowdsec.net/docs/next/appsec/troubleshooting> · FAQ <https://docs.crowdsec.net/docs/next/appsec/faq> · benchmark <https://docs.crowdsec.net/docs/next/appsec/benchmark>

Commands below are written for **bare-metal** (`sudo cscli …`). In docker, prefix with `docker exec <name>`; in k8s, `kubectl exec -n <ns> <pod> --`.

Run [`scripts/diagnose.sh`](../../scripts/diagnose.sh) first — it includes the AppSec metrics table, the appsec acquisition source, and recent log lines, which together cover most of what's below. Then narrow with the headings here.

## 1. Engine refuses to start (or reload fails) after enabling AppSec

Symptom in `journalctl -u crowdsec` / `/var/log/crowdsec.log`:

```
FATAL crowdsec init: while loading acquisition config:
  /etc/crowdsec/acquis.d/appsec.yaml: datasource of type appsec:
  unable to build appsec_config: unable to load inband rule <name> :
  no appsec-rules found for pattern <name>
```

**Cause:** the appsec-config references rules that aren't installed. Installing an appsec-config does **not** auto-install its rules.

**Fix:** read the config, install every rule it lists. Note that the config can use globs (`crowdsecurity/vpatch-*`) but `cscli appsec-rules install` does NOT expand them — enumerate yourself:

```bash
sudo cat /etc/crowdsec/appsec-configs/crowdsecurity/<config>.yaml
# read inband_rules and outofband_rules sections

cscli appsec-rules list -a -o raw \
    | awk -F, '/^crowdsecurity\/vpatch-/ {print $1}' \
    | xargs sudo cscli appsec-rules install
```

Other variants of this error:

| Message fragment | Cause |
|---|---|
| `unable to build appsec_config: no such file` | Typo in `appsec_config:` value, or the config wasn't installed. `cscli appsec-configs list` to confirm. |
| `bind: address already in use` | Another service has `listen_addr`. Pick a different port or stop the conflicting process. |
| `bind: permission denied` | `listen_addr` is a privileged port (<1024) and the agent isn't running as root. Use a high port. |

## 2. `cscli metrics show appsec` shows an empty Engine table

The acquisition loaded but the listener isn't up.

Check, in order:

```bash
sudo ss -lntp | grep :7422
sudo tail -n 50 /var/log/crowdsec.log | grep -i appsec
```

The startup log should contain `Appsec listening on <addr>` and `Appsec Runner ready to process event`. If those lines are absent, the acquisition file did not load — check it's in `/etc/crowdsec/acquis.d/` and has `source: appsec`.

The listener takes 1–2 s to come up after `systemctl reload crowdsec` returns; poll for the port rather than rely on a fixed sleep.

## 3. Bouncer gets 401 from AppSec

The bouncer's `X-Crowdsec-Appsec-Api-Key` doesn't match any registered bouncer's key.

```bash
cscli bouncers list                    # is the bouncer present?
cscli bouncers add <name>              # if missing — outputs a key
cscli bouncers prune                   # removes stale entries
```

Bouncer keys for LAPI **and** AppSec are the same key (the same `cscli bouncers add` invocation produces it). Rotating the key requires `cscli bouncers delete <name>` then `add` again, and updating the bouncer config on the consumer side.

## 4. Bouncer reaches AppSec but nothing is blocked

The request shape doesn't match any installed rule. Diagnose:

```bash
sudo cscli metrics show appsec
```

If the **Engine** counter for "Processed" is incrementing but "Blocked" is not, the request is reaching AppSec but no rule matched. Options:

1. Confirm the rule you expected to match is **installed and enabled**:

   ```bash
   cscli appsec-rules inspect crowdsecurity/<name>
   ```

2. Confirm the rule is referenced by the **active** appsec-config (or any config loaded on this listener):

   ```bash
   cscli appsec-configs inspect crowdsecurity/<config>
   ```

3. Confirm the rule is **inband**, not out-of-band — out-of-band matches do not return 403. Check the appsec-config's `inband_rules` vs `outofband_rules`.

4. Reproduce the request directly against AppSec with `curl` (see [deploy.md](./deploy.md) recipe) — eliminates the bouncer as a variable.

## 5. AppSec blocks happen in metrics but `cscli alerts list` and `cscli decisions list` look wrong

Two separate things confuse people here. Pull them apart:

### 5a. Alerts list is empty *right after* a block

The block has happened; the alert is in flight. AppSec inband matches produce alerts of `kind: waf`, but they are pushed in batches (several-second signal-push interval, visible in the agent log as `Signal push: N signals to push`). Wait 10 s and re-query:

```bash
cscli alerts list -l 50           # kind=waf alerts will appear once pushed
cscli alerts inspect <id>         # confirm Kind=waf, Remediation=false
```

### 5b. Alerts exist but `cscli decisions list` shows no ban for those IPs

By design — inband alerts have `Remediation: false` and the default
`profiles.yaml` only acts on `Remediation: true`. The 403 was already enforced.
Background: [overview.md](./overview.md) § Terminology / inband rule.

If you do want to ban IPs that hit inband AppSec rules:

1. Add a profile that matches `kind == "waf"`:
   ```yaml
   name: ban_on_waf_match
   filters:
     - Alert.Scenario startsWith "crowdsecurity/vpatch-" && Alert.GetScope() == "Ip"
   decisions:
     - type: ban
       duration: 1h
   on_success: break
   ```
   Place it **before** `default_ip_remediation` in `profiles.yaml`. Note this is aggressive — one matched request → 1h ban.

2. Or, use **out-of-band** rules instead — they go through the regular scenarios pipeline and produce `Remediation: true` alerts that the default profile bans. Switch `crowdsecurity/crs-inband` for `crowdsecurity/crs` (out-of-band version), or add a second appsec-config. Also install the matching scenarios collection (e.g. `crowdsecurity/appsec-virtual-patching` ships its own scenarios):

   ```bash
   cscli scenarios list | grep appsec
   ```

   If no AppSec scenarios are installed, out-of-band events have nowhere to aggregate.

## 6. False positives — block on legitimate traffic

Order of fixes from cheapest to most invasive:

1. **Path exclusion** in the appsec-config (`exclude_path:` field, where supported) — silences a rule for specific URL prefixes.
2. **Per-rule disable** via `_custom/` override of the appsec-config. Re-list `inband_rules` minus the offender.
3. **Promote the rule to out-of-band** — converts an immediate block into an alert-only signal, which you can then whitelist or escalate.
4. **Shadow mode** — set the rule's action to `log` in a `_custom/` rule override, then evaluate hit volume before re-enabling `block`. Authoring rule overrides is on the boundary of this skill's scope; check [the canonical rule-management docs](https://docs.crowdsec.net/docs/next/appsec/configuration_rule_management) for the override syntax.

Do **not** whitelist by client IP at the scenarios layer for inband false-positives — scenarios-layer whitelists and **allowlists** (see [../configure/allowlists.md](../configure/allowlists.md)) only affect *decisions*. The inband 403 fires before any decision is written, so neither tool helps with inband false positives. Fix at the appsec-config.

## 7. Captcha doesn't appear (only 403 / blank page)

AppSec returns the *verdict* (`captcha`); the bouncer is responsible for rendering it. Causes:

- Bouncer has no captcha provider configured (hCaptcha / reCAPTCHA / Turnstile keys missing).
- `bouncer_blocked_http_code` and `bouncer_passthrough_http_code` in the appsec-config mismatch what the bouncer expects.
- Bouncer is in a mode that downgrades captcha to ban (some bouncers do this when no captcha provider is set).

Inspect the bouncer's own log for `captcha` lines; it should announce when it's falling back.

## 8. High AppSec latency / CPU

```bash
sudo cscli metrics show appsec
```

Per-rule eval time shows up in the rules table. Suspects:

- **Expensive regex** in a rule body — move to out-of-band, or replace with a cheaper match.
- **Large request bodies** — raise / lower `request_body_limit` in the engine config; the default is conservative.
- **Too many rules loaded** — `cscli appsec-rules list | wc -l`. Curate the set; ship only what your traffic actually needs.

Reference numbers: <https://docs.crowdsec.net/docs/next/appsec/benchmark>.

## 9. Metrics not flowing to Prometheus

AppSec metrics ride on the engine's `/metrics` endpoint, same export as the rest of CrowdSec. If `cscli metrics show appsec` populates but Prometheus doesn't, the issue is on the Prometheus side (scrape config, network reachability, label drops). The engine doesn't have an AppSec-specific export toggle.

## 10. Console doesn't show AppSec events

Console reflects what LAPI sees, which is only the *out-of-band* events (those go through scenarios and produce alerts/decisions). Inband blocks never reach LAPI and so never reach Console. If Console visibility is the goal, you need out-of-band rules.

## Quick recovery — start over without losing the engine

If AppSec is broken badly enough that the agent won't start, the cheapest reset is:

```bash
# 1. Move the broken acquisition out of the way
sudo mv /etc/crowdsec/acquis.d/appsec.yaml /tmp/appsec.yaml.broken

# 2. Bring the engine back up
sudo systemctl restart crowdsec
sudo systemctl status crowdsec

# 3. Inspect the broken file at leisure, fix, restore
```

The rest of CrowdSec keeps running while AppSec is removed — log-based detection is unaffected.
