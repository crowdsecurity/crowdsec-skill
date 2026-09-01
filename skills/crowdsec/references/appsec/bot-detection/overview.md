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

# Bot detection (AppSec challenge mode)

Canonical: <https://docs.crowdsec.net/docs/next/appsec/bot_detection/intro> ·
[how it works](https://docs.crowdsec.net/docs/next/appsec/bot_detection/how_it_works) ·
[protocol](https://docs.crowdsec.net/docs/next/appsec/bot_detection/challenge_protocol)

Version and prerequisites: SKILL.md § Step 1.6. **Alpha upstream** — config keys, expr helpers
and shipped hub rules may change between releases.

## Mechanism

The engine serves an HTML page running a **proof-of-work** plus a **device fingerprint**
(`fpscanner`). The browser POSTs the result, `on_challenge_submit` hooks score it, and a sealed
`__crowdsec_challenge` cookie is issued on success. Not a captcha: no third-party provider, no
user interaction; it proves *browser authenticity*, not humanity. Headless Chromium, Selenium,
Playwright and CDP-driven browsers solve the PoW — they are caught by the fingerprint.

`challenge` is a fourth AppSec action beside `allow` / `ban` / `captcha`. Restrictiveness
ordering: `allow < unknown < captcha < challenge < ban`. Not a LAPI decision type — settable
only from an appsec-config, never `profiles.yaml`.

## Request flow

1. Bouncer → AppSec `:7422` → in-band WAF rules → `post_eval: SendChallenge()`.
2. AppSec returns **403** to the bouncer with
   `{action:"challenge", http_status:200, user_body_content:"<html>…", user_headers:{…}}` — no
   cookie yet.
3. Bouncer serves that body to the client using `http_status`.
4. Browser runs PoW + fingerprint, POSTs `/crowdsec-internal/challenge/submit`.
5. AppSec validates crypto/PoW, runs `on_challenge_submit` hooks, answers `{"status":"ok"}` +
   `Set-Cookie` (allowed), `{"status":"failed"}` (crypto/PoW invalid), or
   `{"status":"rejected"}` (a hook called `RejectSubmission()` → alert).
6. Later requests with a valid cookie run `on_challenge` hooks (before `pre_eval`), with
   `fingerprint` populated.

The status to the *bouncer* is always **403** for any non-allow action; the status the *client*
sees is `http_status` in the envelope — `200` challenge page, `307` `GrantChallengeCookie()`
redirect.

## Terminology

Extends [../overview.md](../overview.md) § Terminology.

| Term | Meaning |
|---|---|
| Fingerprint / FSID | Device fingerprint and stable id; in alerts as `fingerprint_id` |
| Difficulty | PoW cost: `disabled` / `low` / `medium` (default) / `high` / `impossible` |
| Exemption | Challenge skipped (`ExemptFromChallenge`) — per request, no cookie |
| Granted cookie | Challenge waived *and* cookie issued (`GrantChallengeCookie`) — persists |
| Master secret / epoch | Root key for per-epoch signing keys; shared across instances |
| Score | Points from fingerprint mismatch signals; a threshold config rejects above it |

## Event vocabulary

Challenge events use a separate source from WAF rule matches, so scenarios never collide:

| | WAF rule match | Challenge |
|---|---|---|
| `evt.Parsed.source` | `crowdsec-appsec` | `crowdsec-appsec-challenge` |
| Parser | `crowdsecurity/appsec-logs` | `crowdsecurity/appsec-bot-detection-logs` |
| `evt.Meta.log_type` | `appsec` | `appsec-challenge` |

`challenge_event` (on both `evt.Meta` and `evt.Parsed`): `requested` (page served),
`submitted`, `failed` (crypto/PoW invalid), `rejected` (`RejectSubmission()` — the "caught a
bot" signal), `solved` (cookie issued). A rejection raises a `bot-detection` alert, reason
`crowdsecurity/rejected-browser-submission`, `Remediation: false` — one rejection never bans;
repeated ones do via the shipped scenarios ([./deploy.md](./deploy.md) § 4c).

## Prerequisites

Working AppSec ([../deploy.md](../deploy.md)); a bouncer supporting bot detection (behind one
that does not, clients are refused rather than challenged); WASM compiler mode — `arm64`, or
`amd64` **with SSE4.1**, plus permission to map executable memory, else startup fails
([./troubleshoot.md](./troubleshoot.md) § 1); clients that run JS and accept cookies (API
clients, feed readers and CLI tools cannot — exempt them via [./customize.md](./customize.md)).

Startup confirmation, all environments:

```
level=info msg="WAF challenge runtime initialized" cookie_ttl=12h0m0s crypto_pool_size=1 max_cookie_len=4096 module=challenge pow_difficulty=20 rotation_interval=5m0s
```

## Bouncer support

Supported: **nginx**, **OpenResty**, **HAProxy SPOA** (not the Lua bouncer), **Traefik**,
**Envoy**. Not supported: apache, cloudflare, aws-waf, fastly, firewall, blocklist-mirror,
php/wordpress. Upstream publishes **no minimum version**; verified here
`crowdsec-nginx-bouncer` 1.2.2 against engine 1.8.0. Otherwise check the bouncer ships
`challenge.lua` (lua-based) or carries the "Bot Detection" badge, and test before rollout.

Next: [./deploy.md](./deploy.md).
