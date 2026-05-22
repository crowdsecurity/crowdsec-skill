---
verified:
  - date: 2026-05-22
    version: "1.7.8"
    env: systemd
    notes: "appsec-configs/rules list+inspect, metrics rules table; fixed eval-time claim"
---

# AppSec — Configure

Canonical docs: <https://docs.crowdsec.net/docs/next/appsec/configuration> · rule management <https://docs.crowdsec.net/docs/next/appsec/configuration_rule_management> · hooks <https://docs.crowdsec.net/docs/next/appsec/hooks> · alerts & scenarios <https://docs.crowdsec.net/docs/next/appsec/alerts_and_scenarios> · API validation <https://docs.crowdsec.net/docs/next/appsec/api_validation>

This page covers everything you can change once AppSec is *deployed* (see [deploy.md](./deploy.md) for standing it up). Rule **authoring** is out of scope — see SKILL.md.

## The two files that matter

| File | Lives in | What it controls |
|---|---|---|
| `acquis.d/appsec.yaml` (or whichever you named it) | `/etc/crowdsec/acquis.d/` | Listener address, which appsec-configs are loaded, labels for out-of-band events. |
| `appsec-configs/<name>.yaml` | `/etc/crowdsec/appsec-configs/` (hub) and `/etc/crowdsec/appsec-configs/_custom/` (yours) | Which rules apply, inband vs out-of-band, default remediation, blocked-response shaping. |

### Acquisition file

```yaml
source: appsec
listen_addr: 127.0.0.1:7422
appsec_config: crowdsecurity/virtual-patching     # or a list
labels:
  type: appsec
```

Multiple configs on the same listener — note the **plural key** `appsec_configs`. Using `appsec_config:` with a list is a fatal at startup (`cannot unmarshal []interface {} into Go struct field`).

```yaml
source: appsec
listen_addr: 127.0.0.1:7422
appsec_configs:                       # plural — list form
  - crowdsecurity/virtual-patching    # inband CVE patches
  - crowdsecurity/crs                 # out-of-band CRS → scenarios
labels:
  type: appsec
```

**Watch for duplicate rule ids.** If two configs reference the same underlying appsec-rules (e.g. both include `base-config` or `vpatch-*`), the engine fails to start with `failed to compile the directive "secrule": duplicated rule id 100`. Pick configs whose rule sets do not overlap, or compose your own `_custom/` config that loads each rule once. The hub `crowdsecurity/appsec-default` config already bundles `vpatch-*`, `generic-*`, `experimental-*`, and the test rule — usually enough on its own.

### appsec-config file

Hub-shipped configs are read-only — make changes in a `_custom/` override or a brand-new file. Minimum shape:

```yaml
name: yourorg/your-appsec
default_remediation: ban         # ban | captcha | allow
inband_rules:
  - crowdsecurity/base-config
  - crowdsecurity/vpatch-*       # globs are expanded by the engine
outofband_rules:
  - crowdsecurity/crs-*
bouncer_blocked_http_code: 403   # what the bouncer is told to return
user_blocked_http_code: 403      # what the end user sees (some bouncers expose both)
bouncer_passthrough_http_code: 200
```

`default_remediation` is the verdict for any rule that doesn't set its own. Per-rule overrides happen in the rules themselves (out of scope) or via the rule-management table below.

## Reload behaviour

`systemctl reload crowdsec` is enough for everything in this page:

- New / changed appsec-config
- Acquisition file edits
- Adding or removing appsec-rules

`systemctl restart crowdsec` is only needed when the engine binary itself was upgraded. The AppSec listener comes back up within 1–2 seconds of reload; poll the port if scripting it.

## Inband vs out-of-band

The decision matrix lives in [overview.md](./overview.md) § When to use what
(what each mode blocks, when an alert/decision is produced, visibility).
Deployment-specific guidance:

**Recommended split for a new deployment:** start everything **out-of-band**
for two or three days to bound the false-positive rate, then promote noisy /
clearly malicious rules to inband.

## Rule management

```bash
cscli appsec-rules list                       # what's installed
cscli appsec-rules list -a                    # the entire hub catalogue
cscli appsec-rules inspect <name>             # the rule body + which configs reference it
cscli appsec-rules install <name>             # add one or more
cscli appsec-rules upgrade <name>             # match hub head
cscli appsec-rules remove <name>              # unenrol; leaves the file unless --purge
```

Disabling a rule the appsec-config still references will trip `unable to load inband rule <name>` on the next reload. To silence a specific rule **without** removing it, move it to `outofband_rules` (downgrades severity) or set `action: log` on the rule via a `_custom/` override (shadow mode).

## Hooks

Hooks let you mutate the request, add context, or short-circuit evaluation. They fire at three phases:

| Phase | When | Typical use |
|---|---|---|
| `on_load` | Once at startup. | Hydrate variables, compile regex caches. |
| `pre_eval` | Before any rule runs against a request. | Inject custom variables from request headers, classify the request, decide if rules should evaluate at all. |
| `on_match` | After a rule has matched but before the verdict is returned. | Change the action (`ban` → `captcha`), set a custom HTTP response, append context for scenarios. |
| `post_eval` | After all rules have evaluated. | Log enrichment; rarely modifies the verdict. |

Hooks are written in the `expr` language. They are deterministic and must not perform I/O. Errors in hooks bubble to the agent log and (for `pre_eval` / `on_match`) can drop or duplicate a request — test thoroughly with `cscli explain` (where supported) before enabling in production.

## Alerts and scenarios from AppSec

Out-of-band rules emit events with `labels.type: appsec` and matching scenario fields. The hub ships scenarios that consume these — for instance, `crowdsecurity/appsec-virtual-patching` and `crowdsecurity/appsec-crs` aggregate matches into bucketed alerts. Confirm they're installed:

```bash
cscli scenarios list | grep appsec
```

If they aren't installed, out-of-band matches go nowhere — no alert, no decision. Install the collection that pairs with your appsec-config (`crowdsecurity/appsec-virtual-patching` collection ships its own scenarios).

## API validation

AppSec can validate request bodies against schemas (JSON Schema, OpenAPI). Configured per-rule or via a dedicated appsec-config that references schema files. See <https://docs.crowdsec.net/docs/next/appsec/api_validation>. Schema authoring is out of this skill's scope, but **enabling / installing** the validators is plain hub installation:

```bash
sudo cscli appsec-rules install crowdsecurity/api-validation-<...>
```

## Blocked-response shaping

| Field on appsec-config | Effect |
|---|---|
| `bouncer_blocked_http_code` | HTTP status the bouncer is told to return when AppSec blocks. Typical: `403`. |
| `bouncer_passthrough_http_code` | Status when AppSec allows. Typical: `200`. Some bouncers ignore this and just pass the original request through. |
| `user_blocked_http_code` | Status the end user sees — only honoured by bouncers that distinguish bouncer-status from user-status. |
| `bouncer_blocked_http_body` (where supported) | Custom body returned to the user. |

For captcha responses, configuration lives on the **bouncer** (captcha provider keys, redirect URLs), not on AppSec. AppSec only signals "captcha" as a verdict.

## Performance levers

- `request_body_limit` (engine config) caps how much of the request body AppSec processes — defaults are usually fine; raise for APIs with large legitimate payloads, lower for static-only fronts.
- Rule load order is automatic; per-rule **trigger counts** appear in `cscli metrics show appsec` once you generate traffic (the Rules Metrics table) — useful for spotting hot rules, though `cscli` does not report per-rule eval time.
- Inband evaluation adds latency on the request path. Out-of-band is asynchronous and does not.
- Move expensive rules (large regex, body inspection) to out-of-band if latency matters more than per-request blocking.

Benchmark methodology and reference numbers: <https://docs.crowdsec.net/docs/next/appsec/benchmark>.

## Per-environment specifics

| Env | Config delivery |
|---|---|
| **systemd / bare-metal** | Edit files in `/etc/crowdsec/`. `systemctl reload crowdsec`. |
| **Docker / compose** | Mount the appsec-configs and acquisition file from host volumes, or bake them into a custom image. `docker compose exec crowdsec cscli ...` for hub installs. `docker compose restart crowdsec` to pick up acquisition changes if the image doesn't include a reload signal handler. |
| **Kubernetes / Helm** | Most fields are values on the chart (`appsec.config`, `appsec.listen_addr`). For ad-hoc additions use a ConfigMap mounted into `/etc/crowdsec/appsec-configs/_custom/`. `helm upgrade --reset-then-reuse-values` to apply. |
