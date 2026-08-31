---
verified:
  - date: 2026-08-31
    version: "1.8.0"
    env: systemd
    notes: "challenge envelope, event vocabulary, exclusion behaviour; conceptual doc"
  - date: 2026-08-31
    version: "1.8.0-rc2"
    env: docker
    notes: "challenge envelope + exclusions only"
---

# Bot detection (AppSec challenge mode) — what it is

Canonical docs: <https://docs.crowdsec.net/docs/next/appsec/bot_detection/intro> ·
[how it works](https://docs.crowdsec.net/docs/next/appsec/bot_detection/how_it_works) ·
[challenge protocol](https://docs.crowdsec.net/docs/next/appsec/bot_detection/challenge_protocol)

Version and prerequisites: SKILL.md § Step 1.6 — Feature compatibility.

**Marked alpha upstream** — config keys, expr helpers and the shipped hub rules may change
between releases. Say so before someone builds a rollout on it.

## Not a captcha

| | Captcha | Bot detection (challenge) |
|---|---|---|
| Who renders it | The bouncer, from its own template | The **engine**, served through the bouncer |
| Third-party provider | hCaptcha / reCAPTCHA / Turnstile keys required | None |
| User interaction | Yes — solve a puzzle | None — the page self-solves |
| What it proves | A human clicked | The client is a real browser (runs JS, has a plausible device fingerprint) |

The engine serves a small HTML page that runs a **proof-of-work** in a worker and collects a
**device fingerprint** (the open-source `fpscanner` library). The browser POSTs the result
back; hooks score the fingerprint; a sealed `__crowdsec_challenge` cookie is issued on
success. Headless Chromium, Selenium, Playwright and CDP-driven browsers solve the PoW fine
— they get caught by the *fingerprint*, not the puzzle.

`challenge` is a fourth AppSec action next to `allow` / `ban` / `captcha`. Restrictiveness
ordering used by remediation components: `allow < unknown < captcha < challenge < ban`.

It is **not** a LAPI decision type — it cannot be set from `profiles.yaml`, only from an
appsec-config. See [../../configure/profiles.md](../../configure/profiles.md) § Decision types.

## Request flow

```
                  ┌─────────── first visit ───────────┐
client ──▶ bouncer ──▶ AppSec :7422 ──▶ in-band WAF rules
                                   └──▶ post_eval: SendChallenge()
                                            │
       403 to the bouncer + JSON envelope ◀─┘
       {action:"challenge", http_status:200, user_body_content:"<html>…",
        user_headers:{…}}            ← no cookie yet
                  │
   bouncer serves the body to the client with http_status
                  │
   browser runs PoW + fingerprint, POSTs /crowdsec-internal/challenge/submit
                  │
       AppSec validates crypto/PoW ──▶ on_challenge_submit hooks score it
                  │
        {"status":"ok"}      + Set-Cookie __crowdsec_challenge   → allowed
        {"status":"failed"}  crypto/PoW invalid
        {"status":"rejected"} a hook called RejectSubmission()   → alert
                  │
   ┌─── later visits carrying a valid cookie ───┐
   AppSec runs on_challenge hooks (before pre_eval), fingerprint available
```

The outer HTTP status to the *bouncer* is always **403** for any non-allow action. The status
the *client* sees is `http_status` inside the envelope — `200` for a challenge page, `307`
for a `GrantChallengeCookie()` redirect. Confusing the two is the most common misreading of
a `curl` against `:7422`.

## Terminology

Extends [../overview.md](../overview.md) § Terminology.

| Term | Meaning |
|---|---|
| Challenge | The PoW + fingerprint page the engine serves |
| Fingerprint / FSID | The device fingerprint and its stable id, visible in alerts as `fingerprint_id` |
| Difficulty | PoW cost: `disabled` / `low` / `medium` (default) / `high` / `impossible` |
| Exemption | Request skipped the challenge entirely (`ExemptFromChallenge`) — per request, no cookie |
| Granted cookie | Challenge waived *and* a cookie issued (`GrantChallengeCookie`) — persists |
| Master secret / epoch | Root key all per-epoch signing keys derive from; must be shared across instances |
| Score | Points accumulated from fingerprint mismatch signals; a threshold config rejects above it |

## Event vocabulary

Challenge events reach the pipeline as a **separate source** from WAF rule matches, so
challenge scenarios never collide with WAF scenarios:

| | WAF rule match | Challenge |
|---|---|---|
| `evt.Parsed.source` | `crowdsec-appsec` | `crowdsec-appsec-challenge` |
| Parser | `crowdsecurity/appsec-logs` | `crowdsecurity/appsec-bot-detection-logs` |
| `evt.Meta.log_type` | `appsec` | `appsec-challenge` |

`evt.Meta.challenge_event` / `evt.Parsed.challenge_event` takes five values:

| Value | Meaning |
|---|---|
| `requested` | Challenge page served |
| `submitted` | A submission arrived |
| `failed` | Submission failed crypto / PoW validation |
| `rejected` | Submission decoded fine but a hook called `RejectSubmission()` — **this is the "caught a bot" signal** |
| `solved` | Validated, cookie issued |

A rejection raises an alert with kind **`bot-detection`** and reason
`crowdsecurity/rejected-browser-submission`, carrying `Remediation: false` — **the alert
alone never bans**. Only the two shipped leaky scenarios turn repeated abuse into a decision.

## Prerequisites

1. A working AppSec setup — [../deploy.md](../deploy.md) first.
2. A **bouncer that supports bot detection** (see below). Enabling it behind one that does
   not will refuse clients, not challenge them.
3. A host that can run the challenge runtime: obfuscating the challenge JS needs a
   WebAssembly runtime in compiler mode — `arm64`, or `amd64` **with SSE4.1** — and the
   engine must be allowed to map executable memory. W^X hardening, a seccomp profile or an
   SELinux policy can deny it, and the AppSec datasource then fails to load and CrowdSec does
   not start. See [./troubleshoot.md](./troubleshoot.md) § 1.
4. Clients that run JavaScript and accept cookies. API clients, feed readers and CLI tools
   cannot — exclude them ([./customize.md](./customize.md) § Let legitimate traffic through).

Startup confirmation, all environments:

```
level=info msg="WAF challenge runtime initialized" cookie_ttl=12h0m0s crypto_pool_size=1 max_cookie_len=4096 module=challenge pow_difficulty=20 rotation_interval=5m0s
```

## Bouncer support

| Bouncer | Bot detection | Verified here |
|---|---|---|
| nginx (`crowdsec-nginx-bouncer`) | ✅ | ✅ 1.2.2 |
| OpenResty | ✅ | — |
| HAProxy **SPOA** (not the Lua bouncer) | ✅ | — |
| Traefik | ✅ | — |
| Envoy | ✅ | — |
| apache, cloudflare, aws-waf, fastly, firewall, blocklist-mirror, php/wordpress | ❌ | — |

**Upstream documents no minimum version for any of them.** The only version this skill has
observed working is `crowdsec-nginx-bouncer` **1.2.2** against engine **1.8.0**. For anything
else, check the bouncer ships `challenge.lua` (lua-based ones) or carries the "Bot Detection"
badge on its docs page, and test before rolling out.

Next: [./deploy.md](./deploy.md) to turn it on.
