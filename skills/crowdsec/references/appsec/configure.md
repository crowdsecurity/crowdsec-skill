---
verified:
  - date: 2026-05-22
    version: "1.7.8"
    env: systemd
    notes: "appsec-configs/rules list+inspect, metrics rules table; fixed eval-time claim"
  - date: 2026-07-17
    version: "1.7.5-174-g66ab61fc-dirty"
    env: docker
    notes: "bot-detection/challenge config: challenge: block, SendChallenge/MatchKnownBot/ExemptFromChallenge/RejectSubmission hooks, on_challenge_submit phase, metrics"
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

Hooks let you mutate the request, add context, or short-circuit evaluation. They fire at up to six phases (the last two only exist for bot-detection/challenge mode, see below):

| Phase | When | Typical use |
|---|---|---|
| `on_load` | Once at startup. | Hydrate variables, compile regex caches. |
| `pre_eval` | Before any rule runs against a request. | Inject custom variables from request headers, classify the request, decide if rules should evaluate at all. |
| `on_match` | After a rule has matched but before the verdict is returned. | Change the action (`ban` → `captcha`), set a custom HTTP response, append context for scenarios. |
| `post_eval` | After all rules have evaluated. | Log enrichment; rarely modifies the verdict. Also where the bot-detection challenge gate lives — § Bot-detection / challenge mode below. |
| `on_challenge` | In-band only. A request carries an already-valid challenge cookie. | Branch on the decoded `fingerprint` object (e.g. force a re-challenge on a mismatch). |
| `on_challenge_submit` | In-band only. A client POSTs to `/crowdsec-internal/challenge/submit`, after crypto validation. | Reject a cryptographically-valid but suspicious submission (`fingerprint.IsBot()` → `RejectSubmission(...)`). |

Hooks are written in the `expr` language. They are deterministic and must not perform I/O. Errors in hooks bubble to the agent log and (for `pre_eval` / `on_match`) can drop or duplicate a request — test thoroughly with `cscli explain` (where supported) before enabling in production.

## Bot-detection / challenge mode (early feature)

**Not in a numbered release yet.** Engine support merged to crowdsec `master` after v1.7.8 (no
published canonical docs page as of this writing); the hub collection
(`crowdsecurity/appsec-bot-challenge`) is still an upstream `[do-not-merge]` PR
(`crowdsecurity/hub#1826`, branch `test-waf-challenge-mode-scenarios`) — install it via the
`hub_branch` override, see [../configure/hub.md](../configure/hub.md) § Pinning to a hub
branch. Only bouncers that understand the structured JSON challenge envelope can render it —
see [deploy.md](./deploy.md) § Bot-detection / challenge mode for the bouncer-side
requirement.

This serves visitors a lightweight proof-of-work + browser-fingerprint challenge instead of a
hard block, then lets solved, non-bot clients through. Configuration lives in a top-level
`challenge:` block on an appsec-config — combines field-by-field with other loaded configs,
same as any other appsec-config field:

```yaml
challenge:
  master_secret: "<64-char hex, or ≥32-byte passphrase>"   # unset = random, single-instance only
  key_rotation_interval: 5m    # min 30s; must match across instances in HA
  max_live_epochs: 3           # past epochs still accepted (slow clients)
  cookie_ttl: 12h              # independent of key rotation
```

Leaving `master_secret` unset is fine on a single instance (a random secret is generated at
startup, invalidating outstanding cookies on every restart). Running more than one AppSec
instance requires setting `master_secret` and `key_rotation_interval` identically on all of
them, or cookies minted by one are rejected by the others.

### The core gate

The shipped `crowdsecurity/appsec-bot-challenge-simple` config challenges every in-band
request unconditionally — known-bot recognition is handled upstream by separate exemption
configs (below), not by this gate:

```yaml
inband:
  post_eval:
    - filter: "true"
      apply:
        - SendChallenge()
  on_challenge_submit:
    - filter: "fingerprint.IsBot()"
      apply:
        - RejectSubmission("known bot (fast bot detection)")
```

### Known-bot exemption

Nine opt-in `crowdsecurity/appsec-bot-challenge-exclude-*` configs (search engines, AI
crawlers, social, monitoring, plus path-based ones for crawler files/feeds/webhooks/static/API
routes) ship with the collection. Each runs a `pre_eval` hook matching a verified bot against a
downloaded datafile, then flags the request so the core gate's `SendChallenge()` becomes a
no-op for it — no cookie minted, re-evaluated every request:

```yaml
inband:
  pre_eval:
    - filter: 'MatchKnownBot(req.RemoteAddr, req.UserAgent(), req.URL.Path, "legit_bots/googlebot.json")'
      apply:
        - ExemptFromChallenge("googlebot")
```

`MatchKnownBot` requires network verification (exact IP, CIDR range, or forward-confirmed
reverse DNS) in addition to the User-Agent match — a spoofed UA alone never exempts a request.
To recognize your own bot, write a datafile (newline-delimited JSON, one entry per line) and
declare it under the config's `data:` block:

```yaml
data:
  - dest_file: my-bots.json
    type: bots
    source_url: https://example.test/my-bots.json   # cwhub-downloaded; for a local-only file,
                                                       # bind-mount it into place instead and any
                                                       # source_url value is fine — it's never
                                                       # fetched if the file already exists
```

```json
{"name":"my-internal-probe","user_agent":"MyProbe/1\.0","ranges":["10.0.0.0/8"]}
```

At least one of `ips`/`ranges`/`rdns` is required per entry — a User-Agent-only definition is
rejected at load time (trivially spoofable).

### Challenge-related hook functions

| Function | Phase(s) | Effect |
|---|---|---|
| `SendChallenge()` | `post_eval`, `on_challenge` only | Serves the challenge for this request. No-op if the request already carries a valid cookie or was flagged exempt. |
| `MatchKnownBot(ip, ua, path, datafile...)` | any | `true` if the request matches a bot datafile entry (UA + path preconditions, then IP/range/rDNS verification). |
| `ExemptFromChallenge(reason)` | any | Flags the request exempt for `SendChallenge()`. Re-evaluated every request — mints no cookie. |
| `GrantChallengeCookie(reason, ttl?)` | any | Mints a real challenge cookie without a solve — persists across requests until `ttl` (default `cookie_ttl`) expires. |
| `RejectSubmission(reason)` | `on_challenge_submit` only | Rejects an otherwise crypto-valid submission. |
| `DumpFingerprint(label)` | any (fingerprint must be populated) | Writes the decoded fingerprint as JSONL to `<datadir>/fingerprint_dumps/crowdsec_fp_dump_<label>.jsonl` — for offline tuning of your own bot rules. |

`fingerprint.IsBot()` (bool) and `fingerprint.BotSignalCount()` (int) are the two most useful
fields on the `fingerprint` object exposed to `on_challenge`/`on_challenge_submit`.

### Verify

```bash
cscli metrics show appsec   # "Bot Detection Metrics" table: Requested/Submitted/Solved/Granted/
                             # Exempt/Protocol Failures/Submissions Rejected/Cookies Invalid,
                             # plus a per-reason "Bot Detection — Exempted" breakdown
```

A plain request to a challenged route returns `200` with an HTML challenge page and
`user_cookies`/`user_headers` in AppSec's JSON envelope — **not** a bare `403` — so test through
a bouncer that understands the envelope (see deploy.md), not with raw curl against `:7422`
expecting a block/allow status code.

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
