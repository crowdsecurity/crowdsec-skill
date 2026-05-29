---
verified:
  - date: 2026-05-20
    version: "1.7.8"
    env: systemd
    notes: "allowlists add/check/list"
  - date: 2026-05-26
    version: "1.7.8"
    env: systemd
    notes: "parser whitelist via cscli explain --verbose (ignored by whitelist, private-IP); postoverflow via crowdsec -dsn ... -no-api replay (whitelisted-skip lines)"
---

# Configure — Allowlists, whitelist parsers, and postoverflows

Canonical docs: <https://docs.crowdsec.net/docs/next/local_api/centralized_allowlists/>

This page is the canonical reference for the three "don't act on this"
mechanisms. The bulk is about **allowlists** (where most operational work
happens); the comparison section below is the entry point when you don't yet
know which one you need.

## Suppression mechanisms

CrowdSec has three layers that can silence an event, alert, or decision.
Each lives at a different point in the pipeline:

```
log line ──► [parser stages s00→s01→s02-enrich]
                  │                │
                  │      ┌─ whitelist parser drops here (no event, no alert) ─┐
                  ▼      │                                                    │
              event ────►│                                                    │
                         ▼                                                    │
              scenario bucket fills ──► overflow                              │
                                          │                                   │
                                          │   ┌─ postoverflow drops here ─┐   │
                                          ▼   │   (no alert)              │   │
                                       alert ─┘                           │   │
                                          │                               │   │
                                          ▼                               │   │
                                  profile match ──► decision              │   │
                                                       │                  │   │
                                          ┌────────────┘                  │   │
                                          ▼                               │   │
                              ┌─ allowlist drops here ─┐                  │   │
                              │   (alert kept,         │                  │   │
                              │    decision suppressed)│                  │   │
                              └────────────────────────┘                  │   │
                                                                          │   │
       (CAPI / Console / imported blocklists also pass through allowlist) │   │
```

Compared:

| | Whitelist parser | Postoverflow | Allowlist |
|---|---|---|---|
| **Where in the pipeline** | parser stage `s02-enrich` | after scenario overflow, before alert | LAPI decision stage |
| **What is suppressed** | the event itself | the alert | the decision (ban/captcha/throttle) |
| **Visible in `cscli alerts list`?** | no | no | yes — the alert still exists |
| **Affects all scenarios?** | yes (event never reaches any bucket) | per-scenario (or specific filter) | yes (any decision targeting a matching IP) |
| **Affects CAPI / Console / imported blocklists?** | no (those don't go through parsers) | no | yes — all decisions evaluated against allowlists |
| **Affects AppSec inband 403?** | no | no | no — inband enforces per-request, before any decision |
| **Managed with** | `_custom/` files under `parsers/s02-enrich/`; `crowdsecurity/whitelists` ships enabled with RFC1918 ranges | `_custom/` files under `postoverflows/`; e.g. `crowdsecurity/seo-bots-whitelist` | `cscli allowlists ...` (local) or CrowdSec Console (fleet-wide) |

Picking the right one:

| Goal | Use |
|---|---|
| "Don't ever ban this IP, no matter what scenario fires." | **Allowlist** |
| "Stop bucket-fills from this IP — don't even count its events." | **Whitelist parser** |
| "Stop a specific scenario from alerting on this IP/pattern; keep others active." | **Postoverflow whitelist** |
| "Tell AppSec to skip rules for this client IP." | Path/IP exclusion in the **appsec-config** — *not* a suppression mechanism here. See [../appsec/configure.md](../appsec/configure.md). |

The rest of this page is about allowlists. Whitelist-parser and postoverflow
authoring is *content authoring* and out of scope for this skill — the canonical
docs cover the syntax: <https://docs.crowdsec.net/docs/next/whitelist/intro> and
<https://docs.crowdsec.net/docs/next/expr/postoverflows>.

## What allowlists do (and what they don't)

Allowlists prevent **decisions** from being applied to specific IPs / CIDR ranges. The engine evaluates allowlists at the LAPI when a profile would otherwise write a decision (ban, captcha, throttle), and silently drops it if the target IP matches. This includes decisions from **CAPI** (community blocklist), **Console blocklists**, **local scenarios**, and **third-party imports** — everything goes through the same gate.

## Where allowlists come from

| Source | Marked as | How to manage |
|---|---|---|
| **Local** | `Managed by Console: no` in `cscli allowlists list` | `cscli allowlists {create,add,remove,delete,import}` on this engine |
| **Console** | `Managed by Console: yes` | CrowdSec Console UI — pushes to every engine enrolled to your console account. Read-only from `cscli`. |

Console-managed allowlists are the recommended path for fleet-wide allowlists (office IPs, monitoring sources, CDN ranges). Local allowlists fit one-off cases.

> Console-managed allowlists reach the engine over the Console **management
> channel**, which is the `console_management` option — **off by default**.
> Enrolling alone is not enough: run `cscli console enable console_management`
> (then reload). See [../install/console.md](../install/console.md) §2.

## Recipes

Most operational tasks reduce to one of these.

### Allowlist your office permanently

```bash
sudo cscli allowlists create office -d "office and VPN egress"
sudo cscli allowlists add office 203.0.113.0/24 198.51.100.10 -d "HQ + WFH gateway"
```

No `--expiration` → entries never expire. The engine picks them up immediately, no reload needed.

### Allowlist a CDN range temporarily

```bash
sudo cscli allowlists create cdn -d "cloudflare front IPs"
sudo cscli allowlists add cdn 173.245.48.0/20 -e 720h -d "auto-expire after 30d so we re-check"
```

`-e 720h` = 30 days. Useful for tests or vendor-supplied ranges that change.

### Bulk import from a CSV (e.g. exported from another tool)

```csv
value,expiration,comment
203.0.113.0/24,,office
198.51.100.10,,vpn
10.0.0.0/8,,private
```

```bash
sudo cscli allowlists create migration
sudo cscli allowlists import migration -i ./allowlists.csv
```

### Verify an IP is covered

```bash
sudo cscli allowlists check 203.0.113.42
```

Tells you which allowlist(s) match, including Console-managed entries. This is the single most useful debugging command: when a user reports "I'm being blocked", `cscli allowlists check <their IP>` answers "yes, by allowlist <name>" or "no, nothing matches — your block is real".

### Remove an entry

```bash
sudo cscli allowlists remove office 203.0.113.99
```

### Delete an entire allowlist

```bash
sudo cscli allowlists delete cdn
```

Local only. Console-managed allowlists must be deleted in the Console UI.

## Interaction with active decisions

Adding an IP to an allowlist **does** delete existing decisions for that IP. The
`cscli allowlists add` reports it:

```bash
$ sudo cscli allowlists add office 203.0.113.42
added 1 values to allowlist office
1 decisions deleted by allowlists
```

So allowlisting both stops *new* decisions and clears *existing* ones in a single
step — no separate `cscli decisions delete` needed for the LAPI side. (Bouncers
that already pulled the decision may keep enforcing until their next poll; see
[When allowlists silently fail to apply](#when-allowlists-silently-fail-to-apply).)

Conversely, `cscli decisions add` **refuses** to ban an IP that is already
allowlisted:

```bash
$ sudo cscli decisions add -i 203.0.113.42 --duration 5m --reason "test ban"
Error: 203.0.113.42 is allowlisted by item 203.0.113.42 from office (...), use --bypass-allowlist to add the decision anyway
```

Pass `--bypass-allowlist` to force the decision through anyway.

## Verification — does the allowlist actually work?

**TL;DR:** add an IP to an allowlist, confirm its existing decision is cleared,
then confirm a new ban can't be created. Full sequence:

```bash
# 1. Pick a victim IP and add a decision manually
sudo cscli decisions add -i 192.0.2.99 --duration 5m --reason "test ban"
sudo cscli decisions list | grep 192.0.2.99    # decision exists, bouncer would block

# 2. Add it to an allowlist — this deletes the existing decision in the same step
sudo cscli allowlists create test
sudo cscli allowlists add test 192.0.2.99       # prints "1 decisions deleted by allowlists"

# 3. Decision is now gone
sudo cscli decisions list | grep 192.0.2.99    # empty — allowlist cleared the ban

# 4. Confirm a new ban is suppressed — a manual add is now refused outright
sudo cscli decisions add -i 192.0.2.99 --duration 5m --reason "retest"
# Error: ... is allowlisted by item ... use --bypass-allowlist to add the decision anyway
# (re-triggering the scenario from logs is silently dropped the same way)

# 5. Tidy up
sudo cscli allowlists delete test
```

## Verification — does a whitelist actually work?

Allowlists are tested at the LAPI (above). The two **whitelist** layers run at
different phases and are tested with different tools. *Authoring* either is out of
scope (canonical docs cover syntax); confirming a deployed one fires is operational.

### Whitelist parser (`parsers/s02-enrich/`) — use `cscli explain`

A whitelist parser drops the **event** during enrichment, so `cscli explain` shows
it directly — no traffic or bucket needed. Replay a line from a whitelisted source
(the shipped `crowdsecurity/whitelists` covers RFC1918, so any private IP works):

```bash
LINE='May 26 10:00:00 host sshd[111]: Failed password for invalid user admin from 10.0.0.5 port 2222 ssh2'
sudo cscli explain --log "$LINE" --type syslog --verbose
```

A matching whitelist tags the parser and ends the line with `ignored by whitelist`:

```
	|	└ 🟢 crowdsecurity/whitelists (~2 [whitelisted])
	|		└ update evt.Whitelisted : false -> true
	|		└ update evt.WhitelistReason :  -> private ipv4/ipv6 ip/ranges
	└-------- parser success, ignored by whitelist (private ipv4/ipv6 ip/ranges) 🟢
```

No `[whitelisted]` tag / no `ignored by whitelist` line → your parser isn't
matching (wrong expression, file not in `s02-enrich`, or not reloaded).

### Postoverflow (`postoverflows/s01-whitelist/`) — replay through the engine

A postoverflow runs **after** a bucket overflows, which `cscli explain` does not
simulate (it stops at scenario routing). The dynamic-home-IP whitelist
(<https://docs.crowdsec.net/u/getting_started/post_installation/whitelists/>) is this
kind. Test it by replaying enough log lines to overflow, in one-shot mode:

```bash
# build a log that would trip the scenario from the whitelisted IP
for i in $(seq 1 20); do
  printf 'May 26 10:00:%02d host sshd[%d]: Failed password for invalid user x from 203.0.113.77 port 22 ssh2\n' "$i" "$i"
done | sudo tee /tmp/bf.log >/dev/null

sudo crowdsec -dsn file:///tmp/bf.log -type syslog -no-api
```

> **`-no-api` is mandatory while the service is running.** Without it the one-shot
> tries to start its own LAPI and dies: `bind: address already in use` (fatal on
> `:8080`). With `-no-api` it reuses the running LAPI.

Read the output:

- **Not matching** → the overflow is reported:
  `Ip 203.0.113.77 performed 'crowdsecurity/ssh-bf' (6 events over 5s)`
- **Matching** → the overflow is suppressed and *named*:
  ```
  Ban for 203.0.113.77 whitelisted, reason [home IP] name=test/home-ip-wl stage=s01-whitelist
  [Ip 203.0.113.77 performed 'crowdsecurity/ssh-bf' ...] is whitelisted, skip.
  ```
  The `name=` / `stage=` confirm **your** rule matched (not a shipped one like
  `crowdsecurity/seo-bots-whitelist`). For a dynamic-DNS whitelist
  (`... in LookupHost("me.ddns.net")`) the same replay applies — resolution happens
  at evaluation time, so this also catches a stale/typo'd hostname (no `whitelisted`
  line = the name didn't resolve to the source IP).

## When allowlists silently fail to apply

- **Per-request AppSec blocks bypass allowlists.** AppSec inband rules return 403 before any decision is written, so allowlisting the source IP doesn't help with inband false positives. Fix at the appsec-config (`exclude_path:` or per-rule disable). See [../appsec/troubleshoot.md](../appsec/troubleshoot.md).
- **Bouncer-side caches.** A bouncer that already pulled a decision before the allowlist was applied will keep enforcing until the decision's TTL elapses or the bouncer re-polls. Delete the existing decision with `cscli decisions delete -i <ip>` if you need an immediate effect.
- **Console-managed allowlist not yet synced.** New entries propagate from Console within a poll cycle (seconds to a minute on default settings). `cscli allowlists list` shows them once received.
- **Scope mismatch.** Allowlists match decisions whose scope is `Ip` or `Range`. Decisions scoped to `Country`, `AS`, or custom scopes are not allowlist-matched by IP. Rare but worth checking with `cscli decisions list -o json | jq '.[] | .source_scope'` if expected suppression doesn't happen.

## Per-environment notes

| Env | What changes |
|---|---|
| **systemd / bare-metal** | The recipes above as-is. Persistence is in the LAPI database; nothing extra to back up beyond your normal `/var/lib/crowdsec/data/`. |
| **Docker / compose** | `docker compose exec crowdsec cscli allowlists ...`. Console-managed allowlists arrive the same way once the engine is enrolled. |
| **Kubernetes / Helm** | `kubectl exec -n <ns> <lapi-pod> -- cscli allowlists ...`. Avoid configuring allowlists per-replica when running multiple agents — use Console-managed allowlists or run the `cscli` commands once against the shared LAPI. |
