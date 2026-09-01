---
verified:
  - date: 2026-08-31
    version: "1.8.0"
    env: systemd
    notes: "metrics tables, config error strings, ALWAYS_SEND_TO_APPSEC semantics (banned-IP only), glob-resolution fatal, master_secret warning, custom scenario → ban chain"
---

# Bot detection — troubleshooting

Run [`scripts/diagnose.sh`](../../../scripts/diagnose.sh) first. Non-challenge AppSec problems:
[../troubleshoot.md](../troubleshoot.md).

Locate the break with `sudo cscli metrics show bot-detection`:

| Stuck at zero | See |
|---|---|
| `Requested` | § 2 — no challenge issued |
| `Submitted` while `Requested` climbs | § 3 — client never posts back |
| `Solved` while `Submitted` climbs | § 4 / § 6 — everything rejected |
| `Exempt` unexpectedly high | § 5 — exclusion too broad |

## 1 — Won't start after enabling

`FATAL … failed to create wasm runtime in compiler mode` / `FATAL … wasm compiler mode
unavailable`. Needs `arm64`, or `amd64` **with SSE4.1**, plus permission to map executable
memory. Causes: old/emulated CPU, W^X kernel hardening, restrictive seccomp (docker
`--security-opt seccomp=…`), SELinux denying `execmem`. No software fallback.

```bash
grep -o sse4_1 /proc/cpuinfo | head -1          # must print on amd64
sudo journalctl -u crowdsec -n 50 --no-pager | grep -i wasm
sudo ausearch -m avc -ts recent 2>/dev/null | tail   # SELinux denials
```

Other startup fatals:

| Error | Fix |
|---|---|
| `unable to resolve appsec_config "crowdsecurity/appsec-bot-*": no installed appsec-config matches pattern` | Collection not installed — [./deploy.md](./deploy.md) § 1 |
| `unable to compile apply SendChallenge() : unknown name SendChallenge` | Unavailable in `pre_eval`; move to `post_eval` / `on_challenge` |
| `on_challenge hooks are only valid in-band, not under outofband` | Move the hook under `inband:` |

## 2 — No challenge ever served

`Requested` at zero, pages load normally.

1. `grep -E "^APPSEC_URL" /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf` — empty means the
   WAF is off. If set but nothing changed, `systemctl restart nginx` rather than `reload`: the
   lua module reads config at init and a graceful reload can keep old workers serving.
   `ALWAYS_SEND_TO_APPSEC` is **not** the answer — it only affects already-banned IPs
   ([./deploy.md](./deploy.md) § 3).
2. `cscli appsec-configs list` must show the `appsec-bot-challenge-*` entries.
3. Test the engine directly ([./deploy.md](./deploy.md) § 4a). Envelope from curl but nothing in
   the browser ⇒ the bouncer, not the engine.
4. Check the exempt-by-reason table (§ 5) for an over-broad exclusion.

## 3 — Challenge served, nothing submits

`Requested` climbs, `Submitted` at zero. These must reach AppSec unmodified, never the origin:
`GET /crowdsec-internal/challenge/{challenge.js,fpscanner.js,pow-worker.js}` and
`POST /crowdsec-internal/challenge/submit`. A `404` from your origin on
`curl http://your-site/crowdsec-internal/challenge/pow-worker.js` means the bouncer is not
intercepting them. Also check the browser console: a CSP from your origin or a proxy blocking
`blob:` workers or inline script stops the PoW — the challenge ships its own CSP and a stricter
one overrides it. Also plausible: the client cannot run JS (API clients, feed readers, curl,
mobile apps) — exempt by path ([./customize.md](./customize.md)).

## 4 — Endless challenge loop

The cookie is not surviving the round trip. `Cookies Invalid` counts clients presenting a
cookie the runtime will not open.

| Cause | Check |
|---|---|
| Several instances with no shared `master_secret` | Warning below — [./configure.md](./configure.md) § Multi-instance |
| Engine restarted with an ephemeral secret | Same warning; outstanding cookies died with the process |
| Proxy stripping `Set-Cookie` / `Cookie` | Compare bouncer output with browser storage |
| Bouncer collapsing `user_cookies` into one header | Each entry needs its own `Set-Cookie` |
| Clock skew past `(max_live_epochs + 1) × key_rotation_interval` | `timedatectl` on every node |

```
level=warning msg="no master secret configured for the WAF challenge runtime; generated an ephemeral random secret. Distributed (multi-WAF) deployments MUST configure a shared master_secret in the appsec config; single-instance deployments will see outstanding challenge cookies invalidated on restart." module=challenge
```

## 5 — Legitimate clients challenged or blocked

The exempt table (`Bot Detection — Exempted`, one row per reason) shows which exclusions fire.

**Real crawler challenged.** `MatchKnownBot` needs an identity proof, not a user-agent:
`dig -x <crawler-ip> +short` then forward-resolve the name — either leg failing means the match
fails closed; global `dns_cache` (`crowdsec_service`) must not be disabled; UA-only definitions
are rejected at load by design; your own datafile must be declared in a `data:` block, since a
file dropped into `legit_bots/` by hand is never registered
([./customize.md](./customize.md) § Your own crawler).

**Everything blocked, not challenged.** The bouncer does not support bot detection and falls
back to `ban` — [./overview.md](./overview.md) § Bouncer support.

**A human challenged repeatedly** is § 4.

## 6 — Too many / too few rejections

```bash
sudo cscli appsec-configs list | grep scoring
```

Expect the scoring engine plus **exactly one** threshold config. Two means two bundles are
installed and the strictest wins silently ([./deploy.md](./deploy.md) § 1).

The reject table doubles as a score histogram — each `RejectSubmission` reason with its count,
and shipped thresholds put the score in the reason (`request score 115`). If real users cluster
just above your threshold, move to the permissive bundle or re-weight the signal
([./customize.md](./customize.md) § Catch bots the scoring misses).

A single rejection raises a `bot-detection` alert with `Remediation: false` and does not ban.
Repeated ones ban via `appsec-bot-challenge-too-many-submissions` (capacity 5, leakspeed 20s),
because every rejected submission is still a `submitted` event. A bot rejected but never banned
is retrying too slowly to overflow that bucket — add a scenario on
`challenge_event == 'rejected'` ([./customize.md](./customize.md) § Custom scenarios).

## 7 — Reading the metrics

`cscli metrics show bot-detection` renders `appsec-challenge` and `appsec-challenge-infra`.

| Column | Meaning |
|---|---|
| `Requested` / `Submitted` | Pages served / submissions received |
| `Solved` | Passed validation, cookie issued |
| `Granted` | Cookie from `GrantChallengeCookie()`, no challenge solved |
| `Exempt` | Skipped by `ExemptFromChallenge()`, broken out by reason |
| `Protocol Failures` | Crypto/PoW validation failed — malformed or forged submissions |
| `Submissions Rejected` | Validation passed, a hook rejected — real detections |
| `Cookies Invalid` | Incoming cookie could not be opened (§ 4) |

Infrastructure counters (signing key regenerated/evicted, re-obfuscation, dynamic module
evicted) are process-global housekeeping; a regeneration rate far above `key_rotation_interval`
means something is restarting the runtime.

`cscli metrics show appsec-engine` gains `Ch. Requested` / `Ch. Accepted` / `Ch. Rejected`.

Prometheus: `cs_appsec_challenge_requested_total`, `…_submitted_total`, `…_accepted_total`
(`kind` = `solved` | `granted`), `…_rejected_total` (`kind` = `protocol` | `submission` |
`cookie`), `cs_appsec_challenge_exempt_total` (label `reason`),
`cs_appsec_fingerprint_mismatch_total` (labels `reason`, `severity`).

## 8 — Verbose logs

`challenge: { log_level: debug }` in your overlay raises verbosity for the challenge runtime
only. `sudo tail -F /var/log/crowdsec.log | grep -E "challenge submission|on_challenge_submit"`:

```
level=info msg="challenge submission accepted" source=198.51.100.42 fsid=FS1_… is_bot=false allowlisted=false
level=info msg="on_challenge_submit rejected" automation=true cpu_count=16 fsid=FS1_… is_bot=true reason="request score 100" signals="[cdp]" source=203.0.113.7 timezone=Europe/Paris ua="Mozilla/5.0 …" url="http://your-site/"
```

`RejectSubmission("reason", "verbose")` adds `nonce`, `fp_time`, `memory`, `platform`,
`request_uuid` and the full signal list.

## 9 — Capture a fingerprint

```yaml
  on_challenge_submit:
    - filter: "fingerprint.IsBot()"
      apply:
        - 'DumpFingerprint("suspected-automation")'
```

Writes JSONL to `<datadir>/fingerprint_dumps/crowdsec_fp_dump_suspected-automation.jsonl`
(fingerprint plus client IP, UA, host, URI, timestamp).

> Load this **before** the threshold config — `RejectSubmission()` halts remaining
> `on_challenge_submit` rules, so a dump rule after it never runs on the requests you want.

## 10 — Console shows the alert without detail

Context (`score_reasons`, `fingerprint_id`, `request_score`) is hidden by default — enable the
context column or Comfort view. Locally: `sudo cscli alerts inspect <id> -d`.
