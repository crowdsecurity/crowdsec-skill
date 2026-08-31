---
verified:
  - date: 2026-08-31
    version: "1.8.0"
    env: systemd
    notes: "overlay deploy loop, ExemptFromChallenge, GrantChallengeCookie 307+TTL, SetChallengeDifficulty, MatchKnownBot + mandatory data: block, hook-placement errors, scoring points read from installed appsec-bot-challenge-scoring 0.2 (hub config is the source of truth), custom scenario on both evt.Meta and evt.Parsed paths"
---

# Write your own bot-detection config

Canonical docs: <https://docs.crowdsec.net/docs/next/appsec/bot_detection/customization> ·
[hooks reference](https://docs.crowdsec.net/docs/next/appsec/bot_detection/hooks)

Two jobs: **let legitimate traffic through**, and **catch bots the shipped scoring misses**.
Both are done with your own appsec-config — never by editing the hub files, which a
`cscli hub upgrade` will overwrite.

## The deploy loop

1. Write the file to `/etc/crowdsec/appsec-configs/` (docker: a mounted path in the same
   directory; k8s: the log-processor ConfigMap).
2. Add its `name:` to `appsec_configs:` in the acquisition — **by name**. The
   `crowdsecurity/appsec-bot-*` glob does not match your namespace.
3. Reload, then `cscli appsec-configs list` to confirm it is loaded.

```yaml
listen_addr: 127.0.0.1:7422
appsec_configs:
  - crowdsecurity/appsec-bot-*
  - mycorp/appsec-bot-challenge-overlay
labels:
  type: appsec
source: appsec
```

**Order matters.** Configs load in the order listed. A config that re-weights scores must
load *after* `crowdsecurity/appsec-bot-challenge-scoring` and *before* the threshold config,
because `RejectSubmission()` is terminal — it halts every remaining
`on_challenge_submit` rule.

## Which hook, which helper

| Hook | When | Key helpers |
|---|---|---|
| `pre_eval` | Before in-band WAF rules, every request | `ExemptFromChallenge` · `GrantChallengeCookie` · `SetChallengeDifficulty` · `MatchKnownBot` · `DropRequest` · `AddRequestScore` |
| `post_eval` | After in-band WAF rules | `SendChallenge` · `SetChallengeDifficulty` · `GrantChallengeCookie` · `ExemptFromChallenge` · `DumpFingerprint` |
| `on_challenge` | Request carrying a valid cookie, before `pre_eval`; `fingerprint` populated | `SendChallenge` · `EvaluateMismatches` · `SetChallengeDifficulty` · `SetRemediation` · `SetReturnCode` · `DropRequest` |
| `on_challenge_submit` | At the `/submit` POST, after crypto validation, before the cookie is issued | `RejectSubmission` · `GrantChallengeCookie` · `LogAccepted` · `EvaluateMismatches` · `DumpFingerprint` · `CancelAlert` |

Score helpers (`AddRequestScore`, `RequestScore`, `RequestScoreReasons`,
`RequestScoreDetail`, `RequestScoreFor`) are available in all of the above plus `on_match`.

Two placement rules the engine enforces at startup:

- **`SendChallenge()` is not available in `pre_eval`** — a challenge may only be issued after
  in-band evaluation. Using it there is a fatal config error:
  ```
  FATAL … unable to build pre_eval hook : unable to compile apply SendChallenge() : unknown name SendChallenge (1:1)
  ```
- **`on_challenge` and `on_challenge_submit` are in-band only.** Under `outofband:`:
  ```
  FATAL … on_challenge hooks are only valid in-band, not under outofband
  ```

`on_challenge_submit` deliberately exposes no helper that changes the response shape
(`SendChallenge`, `SetRemediation`, `SetReturnCode`, `DropRequest`) — it answers a JSON
handshake the client-side JS is parsing. Escalate from `pre_eval` on the *next* request
instead.

## Let legitimate traffic through

Four mechanisms. Pick by what you can prove about the client:

| You can prove | Use | Scope |
|---|---|---|
| Nothing — it is just this path/host | `ExemptFromChallenge(reason)` | Per request, no cookie |
| A shared secret or header | `GrantChallengeCookie(reason, ttl?)` | Persists via cookie, 307 redirect |
| Published IP ranges or rDNS (a real crawler) | `MatchKnownBot(...)` + a `data:` file | Per request |
| A fixed source IP you control | A native LAPI allowlist | Bypasses AppSec entirely |

A LAPI allowlist is the bluntest and often the right answer for your own infrastructure — an
allowlisted IP never reaches AppSec at all, is never challenged and never issued a cookie.
See [../../configure/allowlists.md](../../configure/allowlists.md).

### Scope the challenge to what matters

Challenging your whole site is rarely what you want. Invert it — exempt everything except the
funnel you care about:

```yaml
name: mycorp/appsec-bot-challenge-checkout-only
inband:
  pre_eval:
    - filter: '!(req.URL.Path startsWith "/checkout/")'
      apply:
        - ExemptFromChallenge("outside-checkout")
```

Per host, for a multi-vhost listener:

```yaml
name: mycorp/appsec-bot-challenge-protected-surface
inband:
  pre_eval:
    - filter: req.Host != "foobar.com" && req.Host != "api.foobar.com"
      apply:
        - ExemptFromChallenge("unprotected-host")
    - filter: req.Host == "api.foobar.com" && !(req.URL.Path startsWith "/v1/login")
      apply:
        - ExemptFromChallenge("api-outside-login")
```

Proxies may forward `foobar.com:443` rather than the bare host — use `startsWith`, or
`req.Host == "foobar.com" || req.Host endsWith ".foobar.com"` for a whole domain.

Verify with the exempt metric, which counts by reason:

```
| Bot Detection — Exempted                  |
| Appsec Engine   | Reason          | Count |
| 127.0.0.1:7422/ | internal-health | 1     |
| 127.0.0.1:7422/ | crawler-files   | 3     |
```

### An internal probe

```yaml
name: mycorp/appsec-bot-challenge-overlay
inband:
  pre_eval:
    - filter: req.Header.Get("X-Internal-Probe") == "s3cr3t" && req.RemoteAddr startsWith "10."
      apply:
        - GrantChallengeCookie("internal-probe", "24h")
```

The response is a `307` carrying the cookie, so the client lands where it was going:

```json
{
  "action": "challenge",
  "http_status": 307,
  "user_cookies": ["__crowdsec_challenge=ABme-J7g…; Path=/; Max-Age=86399; HttpOnly; SameSite=Lax"],
  "user_headers": { "Location": ["/"], "Cache-Control": ["no-store"] }
}
```

A shared-secret header is a bypass token the moment it leaks. Always pair it with a source
constraint as above, and prefer a LAPI allowlist when the source IP is stable.

Drop the `, "24h"` to use the configured `cookie_ttl`. Use `ExemptFromChallenge` instead if
you want no cookie at all.

### A crawler of your own

`MatchKnownBot` checks a JSON datafile of bot definitions:

```
(user_agent matches AND at least one path matches) AND (exact IP OR CIDR range OR FCrDNS)
```

Newline-delimited JSON, one definition per line, landing under
`<datadir>/legit_bots/` (usually `/var/lib/crowdsec/data/legit_bots/`):

```json
{"name":"mybot","user_agent":"mycorp-monitor","paths":["^/health(/|$)","^/status$"],"ranges":["10.42.0.0/16"],"ips":["192.0.2.77"]}
```

`name` is required. `user_agent` and `paths` are regexes; omitting them matches anything. At
least one of `ips` / `ranges` / `rdns` is required — a user-agent-only definition is rejected
at load, because a UA is trivially spoofed. `rdns` entries are forward-confirmed reverse DNS
regexes; anchor them (`(^|\.)googlebot\.com$`), or `evilgooglebot.com` matches. Parse, DNS
and unknown-file errors all fail closed — the bot is challenged.

> **The `data:` block is mandatory.** Dropping the file into `legit_bots/` by hand does
> nothing: only files declared in `data:` are registered in the expr datafile registry, and
> `MatchKnownBot` silently returns false for anything else. Verified — the same config
> matched nothing until the `data:` block was added.

```yaml
name: mycorp/appsec-bot-challenge-known-bot
inband:
  pre_eval:
    - filter: MatchKnownBot(req.RemoteAddr, req.UserAgent(), req.URL.Path, "legit_bots/mybot.json")
      apply:
        - ExemptFromChallenge("mybot")
data:
  - source_url: https://example.com/mybot.json
    dest_file: legit_bots/mybot.json
    type: bots
```

Behaviour of the definition above, verified:

| Request | Result |
|---|---|
| `/status` from `10.42.0.9`, UA `mycorp-monitor/1.0` | exempt — range + UA + path |
| `/status` from `192.0.2.77`, same UA | exempt — exact IP |
| `/status` from `1.2.3.4`, same UA | challenged — UA alone proves nothing |
| `/other` from `10.42.0.9`, same UA | challenged — path not listed |

FCrDNS needs working reverse DNS resolution from the engine. The DNS cache is global engine
config (`crowdsec_service` → `dns_cache`), not part of the appsec-config.

## Catch bots the shipped scoring misses

`EvaluateMismatches()` returns a cached-per-request report over the fingerprint:

| Call | Returns |
|---|---|
| `.Has("cdp")` | Did this signal fire |
| `.Count()` | How many fired |
| `.High()` / `.Medium()` / `.Low()` | Count by severity |
| `.Reasons()` | The signal names |

### What a signal is worth

**Points live in the hub config, not the engine.** `crowdsecurity/appsec-bot-challenge-scoring`
is the source of truth for what each signal contributes, and it is a normal hub item — it gets
revised, and you can override it. Always read the installed file rather than trusting a table:

```bash
sudo grep -B2 AddRequestScore /etc/crowdsec/appsec-configs/appsec-bot-challenge-scoring.yaml
```

As shipped in `appsec-bot-challenge-scoring` **0.2**:

| Points | Signals | Rationale in the config |
|---|---|---|
| **100** | `cdp`, `webdriver`, `webdriver_writable`, `selenium`, `playwright`, `webdriver_iframe`, `webdriver_worker`, `bot_user_agent` | Declared automation. One is enough to clear every shipped threshold. |
| **50** | `headless_screen_resolution`, `missing_chrome_object`, `impossible_memory`, `inconsistent_etsl`, `mismatch_webgl_worker`, `mismatch_platform_iframe`, `mismatch_platform_worker` | Headless environments and cross-context inconsistencies — hard to fake away, thin tail of legitimate clients. |
| **30** | `platform_mismatch`, `gpu_mismatch`, `high_cpu_count` | Suspicious, but reachable by odd-but-real setups (VMs, remote desktops). |
| **15** | `utc_timezone`, `ua_mobile`, `accept_language` | Common enough among real visitors that acting on one alone is a false positive. |
| **5** | `swiftshader_renderer`, `mismatch_languages`, `timezone_country` | Only meaningful in aggregate. |

### Severity is a different axis

`.High()` / `.Medium()` / `.Low()` do **not** read those points. Severity is a fixed label the
engine attaches to each signal, and the two do not line up: every signal from 30 points upward
is `high`, only the 15-point ones are `medium`, only the 5-point ones are `low`.

So `EvaluateMismatches().High() >= 1` fires on a lone `gpu_mismatch` — a 30-point signal,
nowhere near any shipped threshold. If you mean "strong evidence", filter on `RequestScore()`
or name the signals with `.Has(...)`; reach for `.High()` only when you genuinely want any
high-severity signal regardless of weight.

Re-weight a signal for your traffic — load this **between** the scoring config and the
threshold config:

```yaml
name: mycorp/appsec-bot-challenge-reweight
inband:
  on_challenge_submit:
    # A UTC-only audience is unusual for us; treat it as stronger evidence.
    - filter: EvaluateMismatches().Has("utc_timezone")
      apply:
        - AddRequestScore(45, "utc_timezone_mycorp")
    # Our app is mobile-first, so a mobile UA mismatch is expected noise.
    - filter: EvaluateMismatches().Has("ua_mobile")
      apply:
        - AddRequestScore(-15, "ua_mobile_expected")
```

Scores may be negative. Add application-specific evidence the fingerprint cannot see:

```yaml
    - filter: req.URL.Path startsWith "/checkout" && req.Header.Get("Referer") == ""
      apply:
        - AddRequestScore(30, "checkout_no_referer")
```

Reject on signal shape rather than score:

```yaml
    - filter: EvaluateMismatches().High() >= 1
      apply:
        - 'RejectSubmission("high-severity mismatch")'
```

`RejectSubmission(reason, verbosity)` takes an optional `"minimal"` / `"info"` (default) /
`"verbose"` controlling how much fingerprint detail is logged.

Escalate instead of rejecting — make a suspicious client work harder on its next challenge:

```yaml
  on_challenge:
    - filter: EvaluateMismatches().High() >= 1
      apply:
        - SetChallengeDifficulty("high")
        - SendChallenge()
```

Or hard-drop a client that carries a valid cookie but now shows automation signals:

```yaml
  on_challenge:
    - filter: fingerprint.HasAutomationSignal()
      apply:
        - 'DropRequest("automation signal on cookie-bearing client")'
```

The `fingerprint` object also offers `IsBot()`, `HasBotSignal()`, `BotSignalCount()`,
`BotSignals()`, `HasHeadlessSignal()`, `HasMismatchSignal()`, `Platform()`, `Timezone()`,
`Language()`, `IsMobile()`, `CPUCount()`, `Memory()`. Full shape:
<https://pkg.go.dev/github.com/crowdsecurity/crowdsec/pkg/appsec/challenge#FingerprintData>

## Custom scenarios on challenge events

A persistent bot is already covered without any custom scenario. A rejected submission is
still a submission, so it emits `submitted` as well as `rejected`, and
`crowdsecurity/appsec-bot-challenge-too-many-submissions` fills on it —
verified: eight consecutive CDP-browser rejections produced a ban from that scenario, not
just alerts. A real browser solves once, takes its cookie and stops submitting, so it does
not trip the same bucket.

What the shipped scenarios do *not* give you is a rejection-specific reaction: no scenario
filters on `challenge_event` being `rejected`, `failed` or `solved`. Write one when you want
to ban faster than raw submission volume allows, react to a particular signal, or treat a
single rejection as terminal for a sensitive route.

Both field paths work; the shipped scenarios use `evt.Meta`, upstream docs teach
`evt.Parsed`. `evt.Meta` fields are the ones the hub parser sets, so prefer them for
consistency with the shipped content:

```yaml
# /etc/crowdsec/scenarios/mycorp-appsec-bot-rejected.yaml
type: leaky
name: mycorp/appsec-bot-rejected
description: "Ban clients repeatedly rejected by the bot challenge"
filter: |
  evt.Meta.log_type == 'appsec-challenge' &&
  evt.Meta.challenge_event == 'rejected'
groupby: evt.Meta.source_ip
capacity: 3
leakspeed: 10m
blackhole: 5m
labels:
  service: http
  confidence: 3
  spoofable: 0
  behavior: "http:bot"
  label: "Repeatedly failed the CrowdSec bot challenge"
  remediation: true
```

Fields the parser exposes on the event: `source_ip`, `target_host`, `target_uri`,
`request_uuid`, `challenge_event`, `challenge_difficulty`, `challenge_fail_reason`, `fsid`,
`fingerprint_bot`, `http_user_agent`, `request_score`, `request_score_reasons`, `os`.

`request_score_reasons` is a flat string like `"cdp=100,utc_timezone=15"`, so match on it
with `contains`:

```yaml
filter: |
  evt.Meta.log_type == 'appsec-challenge' &&
  evt.Meta.challenge_event == 'rejected' &&
  evt.Meta.request_score_reasons contains "cdp="
```

`remediation: true` is what turns the alert into a decision through your profiles —
[../../configure/profiles.md](../../configure/profiles.md).
