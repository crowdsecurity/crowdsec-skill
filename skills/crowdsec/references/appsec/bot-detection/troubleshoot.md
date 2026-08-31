---
verified:
  - date: 2026-08-31
    version: "1.8.0"
    env: systemd
    notes: "metrics tables, config error strings, ALWAYS_SEND_TO_APPSEC semantics (banned-IP only), glob-resolution fatal, master_secret warning, custom scenario → ban chain"
---

# Bot detection — troubleshooting

Run [`scripts/diagnose.sh`](../../../scripts/diagnose.sh) first for the general picture, then
come here. For AppSec problems that are not challenge-specific, use
[../troubleshoot.md](../troubleshoot.md).

Quick orientation — where in the funnel does it break?

```bash
sudo cscli metrics show bot-detection
```

| Column stuck at zero | Look at |
|---|---|
| `Requested` | § 2 — no challenge is being issued at all |
| `Submitted` (but `Requested` climbing) | § 3 — the client never posts back |
| `Solved` (but `Submitted` climbing) | § 4 / § 6 — everything is being rejected |
| `Exempt` unexpectedly high | § 5 — an exclusion is too broad |

## 1 — CrowdSec won't start after enabling it

```
FATAL … failed to create wasm runtime in compiler mode
FATAL … wasm compiler mode unavailable
```

The challenge JS is obfuscated through a WebAssembly runtime in compiler mode. It needs
`arm64`, or `amd64` **with SSE4.1**, and permission to map executable memory. Check in order:

```bash
grep -o sse4_1 /proc/cpuinfo | head -1          # must print sse4_1 on amd64
sudo journalctl -u crowdsec -n 50 --no-pager | grep -i wasm
sudo ausearch -m avc -ts recent 2>/dev/null | tail   # SELinux denials
```

Common causes: an old/emulated CPU, a hardened kernel with W^X enforcement, a restrictive
seccomp profile (docker `--security-opt seccomp=…`), or an SELinux policy denying
`execmem`. There is no software fallback — fix the host or run bot detection elsewhere.

Different fatal, same moment:

```
FATAL … unable to resolve appsec_config "crowdsecurity/appsec-bot-*": no installed appsec-config matches pattern "crowdsecurity/appsec-bot-*"
```

The glob is in the acquisition but the collection was never installed. Install it, then
reload — [./deploy.md](./deploy.md) § 1.

Hook placement errors, both fatal at startup:

| Error | Fix |
|---|---|
| `unable to compile apply SendChallenge() : unknown name SendChallenge` | `SendChallenge()` is not available in `pre_eval`. Move it to `post_eval` or `on_challenge`. |
| `on_challenge hooks are only valid in-band, not under outofband` | Move the hook under `inband:`. |

## 2 — No challenge is ever served

`Requested` stays at zero and pages load normally.

1. **Is `APPSEC_URL` set, and did the change actually take effect?**
   ```bash
   grep -E "^APPSEC_URL" /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf
   ```
   Empty means the WAF is off entirely. If it is set and nothing changed, `systemctl restart
   nginx` rather than `reload` — the lua module reads the config at init and a graceful
   reload can keep old workers serving, which looks exactly like the setting being ignored.
   (`ALWAYS_SEND_TO_APPSEC` is **not** the answer here; it only affects already-banned IPs.
   See [./deploy.md](./deploy.md) § 3.)
2. **Is the config loaded?** `cscli appsec-configs list` should show the
   `appsec-bot-challenge-*` entries. If not, the acquisition does not reference them.
3. **Test the engine directly**, bypassing the bouncer entirely —
   [./deploy.md](./deploy.md) § 4a. If curl gets a `challenge` envelope but the browser does
   not, the problem is the bouncer, not the engine.
4. **Is something exempting everything?** Check the exempt-by-reason table (§ 5).

## 3 — Challenge served, but nothing ever submits

`Requested` climbs, `Submitted` stays at zero.

The bouncer is serving the page but not forwarding the challenge's own traffic back to
AppSec. All four internal paths must reach AppSec unmodified, never the origin:

```
GET  /crowdsec-internal/challenge/challenge.js
GET  /crowdsec-internal/challenge/fpscanner.js
GET  /crowdsec-internal/challenge/pow-worker.js
POST /crowdsec-internal/challenge/submit
```

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://your-site/crowdsec-internal/challenge/pow-worker.js
```

A `404` from your origin means the bouncer is not intercepting them. Check the browser
console too — a Content-Security-Policy on your side that blocks `blob:` workers or inline
script stops the PoW from ever running; the challenge ships its own CSP, and a stricter one
added by the origin or a proxy overrides it.

Also plausible: the client genuinely cannot solve it. API clients, feed readers, curl and
mobile apps do not run JS. Exempt them by path —
[./customize.md](./customize.md) § Let legitimate traffic through.

## 4 — Endless challenge loop

The browser solves the challenge, gets a cookie, and is challenged again on the next request.
The cookie is not surviving the round trip.

| Cause | Check |
|---|---|
| Several AppSec instances with no shared `master_secret` | The startup warning below; fix per [./configure.md](./configure.md) § Multi-instance |
| Engine restarted with an ephemeral secret | Same warning — all outstanding cookies died with the process |
| A proxy stripping `Set-Cookie` or `Cookie` | Compare what the bouncer emits with what the browser stores |
| Bouncer collapsing multiple `user_cookies` into one header | Each entry must be its own `Set-Cookie` |
| Clock skew beyond `(max_live_epochs + 1) × key_rotation_interval` | `timedatectl` on every node |

```
level=warning msg="no master secret configured for the WAF challenge runtime; generated an ephemeral random secret. Distributed (multi-WAF) deployments MUST configure a shared master_secret in the appsec config; single-instance deployments will see outstanding challenge cookies invalidated on restart." module=challenge
```

`Cookies Invalid` in the metrics table counts exactly this — clients presenting a cookie the
runtime will not open.

## 5 — Legitimate clients are being challenged or blocked

Read the exempt table first; it tells you which exclusions are firing and which are not:

```bash
sudo cscli metrics show bot-detection
```

```
| Bot Detection — Exempted                |
| Appsec Engine   | Reason        | Count |
| 127.0.0.1:7422/ | api           | 1     |
| 127.0.0.1:7422/ | crawler-files | 2     |
| 127.0.0.1:7422/ | googlebot     | 1     |
```

**A real crawler is being challenged.** `MatchKnownBot` requires an identity proof, not just
a user-agent — exact IP, CIDR range, or forward-confirmed reverse DNS. So:

- Confirm rDNS actually resolves from the engine host: `dig -x <crawler-ip> +short`, then
  forward-resolve the name back. If either leg fails, the match fails closed.
- Check the engine's global `dns_cache` config (`crowdsec_service` → `dns_cache`) is not
  disabled.
- A definition with only `user_agent` is rejected at load time by design.
- If it is **your own** datafile: it must be declared in a `data:` block. A file dropped into
  `legit_bots/` by hand is never registered and `MatchKnownBot` silently returns false —
  [./customize.md](./customize.md) § A crawler of your own.

**A human is being challenged repeatedly** — that is § 4, not this section.

**Everything is blocked, not challenged.** The bouncer does not support bot detection and is
falling back to `ban`. Check it against [./overview.md](./overview.md) § Bouncer support.

## 6 — Too many, or too few, rejections

```bash
sudo cscli appsec-configs list | grep scoring
```

You should see the scoring engine plus **exactly one** threshold config. Two threshold
configs means two bundles are installed and the strictest one silently wins —
[./deploy.md](./deploy.md) § 1.

The reject table doubles as a score histogram: each distinct `RejectSubmission` reason string
appears with its count, and the shipped threshold configs put the score in the reason
(`request score 115`). If real users cluster just above your threshold, move to the
permissive bundle or re-weight the offending signal —
[./customize.md](./customize.md) § Catch bots the shipped scoring misses.

Remember what a single rejection does: it raises a `bot-detection` alert with
`Remediation: false`, which does not ban by itself. Repeated rejections do ban, through
`crowdsecurity/appsec-bot-challenge-too-many-submissions` — every rejected submission is
still a `submitted` event, so the bucket fills (capacity 5, leakspeed 20s). If a bot is
being rejected but never banned, it is retrying too slowly to overflow that bucket; add a
scenario on `challenge_event == 'rejected'` to react sooner
([./customize.md](./customize.md) § Custom scenarios on challenge events).

## 7 — Reading the metrics

`cscli metrics show bot-detection` renders two sections (`appsec-challenge` and
`appsec-challenge-infra`, listed by `cscli metrics list`):

```
| Bot Detection   | Requested | Submitted | Solved | Granted | Exempt | Protocol Failures | Submissions Rejected | Cookies Invalid |
| 127.0.0.1:7422/ | 7         | 1         | -      | -       | 7      | -                 | 1                    | -               |
```

| Column | Meaning |
|---|---|
| `Requested` / `Submitted` | Pages served / submissions received |
| `Solved` | Passed validation and got a cookie |
| `Granted` | Cookie issued by `GrantChallengeCookie()`, no challenge solved |
| `Exempt` | Skipped by `ExemptFromChallenge()` — broken out by reason below |
| `Protocol Failures` | Crypto or PoW validation failed — malformed or forged submissions |
| `Submissions Rejected` | Validation passed, a hook called `RejectSubmission()` — real detections |
| `Cookies Invalid` | Incoming cookie could not be opened (see § 4) |

Infrastructure counters (signing key regenerated/evicted, re-obfuscation, dynamic module
evicted) are housekeeping and process-global. They should tick slowly and steadily; a
regeneration rate far above `key_rotation_interval` means something is restarting the runtime.

`cscli metrics show appsec-engine` also gains `Ch. Requested` / `Ch. Accepted` /
`Ch. Rejected` columns.

Prometheus: `cs_appsec_challenge_requested_total`, `…_submitted_total`,
`…_accepted_total` (label `kind` = `solved` | `granted`), `…_rejected_total` (`kind` =
`protocol` | `submission` | `cookie`), `cs_appsec_challenge_exempt_total` (label `reason`),
and `cs_appsec_fingerprint_mismatch_total` (labels `reason`, `severity`).

## 8 — Turning up the logs

Raise verbosity for the challenge runtime alone, without making the rest of CrowdSec noisy —
add to your overlay appsec-config:

```yaml
challenge:
  log_level: debug
```

```bash
sudo tail -F /var/log/crowdsec.log | grep -E "challenge submission|on_challenge_submit|module=challenge"
```

Line shapes to expect:

```
level=info msg="challenge submission accepted" source=198.51.100.42 fsid=FS1_… is_bot=false allowlisted=false
level=info msg="on_challenge_submit rejected" automation=true cpu_count=16 fsid=FS1_… is_bot=true language=en-US reason="request score 100" signals="[cdp]" source=203.0.113.7 timezone=Europe/Paris ua="Mozilla/5.0 …" url="http://your-site/"
```

`RejectSubmission("reason", "verbose")` adds `nonce`, `fp_time`, `memory`, `platform`,
`request_uuid` and the full signal list to that line.

## 9 — Capturing a fingerprint to inspect

```yaml
  on_challenge_submit:
    - filter: "fingerprint.IsBot()"
      apply:
        - 'DumpFingerprint("suspected-automation")'
```

Writes JSONL to `<datadir>/fingerprint_dumps/crowdsec_fp_dump_suspected-automation.jsonl`
with the fingerprint plus client IP, UA, host, URI and timestamp.

> Load this config **before** the threshold config. `RejectSubmission()` is terminal — it
> halts every remaining `on_challenge_submit` rule, so a dump rule loaded after it never runs
> on the requests you most want to inspect.

## 10 — Console shows the alert but not the detail

The context (`score_reasons`, `fingerprint_id`, `request_score`) rides on the alert but is
hidden by default. Enable the context column or Comfort view in the Console alerts settings.
Locally the same data is always available:

```bash
sudo cscli alerts inspect <id> -d
```
