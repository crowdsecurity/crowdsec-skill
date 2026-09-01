---
verified:
  - date: 2026-08-31
    version: "1.8.0"
    env: systemd
    notes: "overlay deploy loop, ExemptFromChallenge, GrantChallengeCookie 307+TTL, SetChallengeDifficulty, MatchKnownBot + mandatory data: block, hook-placement errors, scoring points read from installed appsec-bot-challenge-scoring 0.2, custom scenario on both evt.Meta and evt.Parsed paths"
---

# Custom bot-detection configs

Canonical: <https://docs.crowdsec.net/docs/next/appsec/bot_detection/customization> ·
[hooks](https://docs.crowdsec.net/docs/next/appsec/bot_detection/hooks)

Two jobs: let legitimate traffic through, and catch bots the shipped scoring misses. Both via
your own appsec-config — never by editing hub files (`cscli hub upgrade` overwrites them).

## Deploy loop

Write to `/etc/crowdsec/appsec-configs/` (docker: mounted path in the same directory; k8s:
log-processor ConfigMap), add its `name:` to `appsec_configs:` **by name** (the
`crowdsecurity/appsec-bot-*` glob does not match your namespace), reload, confirm with
`cscli appsec-configs list`. Configs load in listed order: a re-weighting config must load
**after** `crowdsecurity/appsec-bot-challenge-scoring` and **before** the threshold config,
because `RejectSubmission()` is terminal — it halts every remaining `on_challenge_submit` rule.

## Which hook, which helper

| Hook | When | Key helpers |
|---|---|---|
| `pre_eval` | Before in-band WAF rules, every request | `ExemptFromChallenge` · `GrantChallengeCookie` · `SetChallengeDifficulty` · `MatchKnownBot` · `DropRequest` · `AddRequestScore` |
| `post_eval` | After in-band WAF rules | `SendChallenge` · `SetChallengeDifficulty` · `GrantChallengeCookie` · `ExemptFromChallenge` · `DumpFingerprint` |
| `on_challenge` | Request with a valid cookie, before `pre_eval`; `fingerprint` populated | `SendChallenge` · `EvaluateMismatches` · `SetChallengeDifficulty` · `SetRemediation` · `SetReturnCode` · `DropRequest` |
| `on_challenge_submit` | At `/submit`, after crypto validation, before cookie issuance | `RejectSubmission` · `GrantChallengeCookie` · `LogAccepted` · `EvaluateMismatches` · `DumpFingerprint` · `CancelAlert` |

Score helpers (`AddRequestScore`, `RequestScore`, `RequestScoreReasons`, `RequestScoreDetail`,
`RequestScoreFor`) work in all of the above plus `on_match`. `on_challenge_submit` exposes
nothing that changes the response shape (`SendChallenge`, `SetRemediation`, `SetReturnCode`,
`DropRequest`) — it answers a JSON handshake the client JS parses; escalate from `pre_eval` on
the next request instead. Placement is enforced at startup:

| Mistake | Error |
|---|---|
| `SendChallenge()` in `pre_eval` | `unable to build pre_eval hook : unable to compile apply SendChallenge() : unknown name SendChallenge (1:1)` |
| `on_challenge*` under `outofband:` | `on_challenge hooks are only valid in-band, not under outofband` |

## Let legitimate traffic through

| You can prove | Use | Scope |
|---|---|---|
| Nothing — just this path/host | `ExemptFromChallenge(reason)` | Per request, no cookie |
| A shared secret / header | `GrantChallengeCookie(reason, ttl?)` | Persists via cookie, 307 redirect |
| Published IP ranges or rDNS | `MatchKnownBot(...)` + a `data:` file | Per request |
| A fixed source IP you control | LAPI allowlist | Bypasses AppSec entirely |

A LAPI allowlisted IP never reaches AppSec, is never challenged, never issued a cookie —
[../../configure/allowlists.md](../../configure/allowlists.md). Exemptions are counted by
reason in `cscli metrics show bot-detection`.

```yaml
name: mycorp/appsec-bot-challenge-overlay
inband:
  pre_eval:
    # Exempt everything except the funnel you care about.
    - filter: '!(req.URL.Path startsWith "/checkout/")'
      apply:
        - ExemptFromChallenge("outside-checkout")
    # Per host. Proxies may forward "foobar.com:443" — use startsWith, or
    # req.Host == "foobar.com" || req.Host endsWith ".foobar.com" for a whole domain.
    - filter: req.Host == "api.foobar.com" && !(req.URL.Path startsWith "/v1/login")
      apply:
        - ExemptFromChallenge("api-outside-login")
    # A shared-secret header is a bypass token if it leaks — always pair it with a source
    # constraint; prefer a LAPI allowlist when the IP is stable.
    - filter: req.Header.Get("X-Internal-Probe") == "s3cr3t" && req.RemoteAddr startsWith "10."
      apply:
        - GrantChallengeCookie("internal-probe", "24h")   # omit TTL to use cookie_ttl
```

`GrantChallengeCookie` answers `307` with `Location` and
`__crowdsec_challenge=…; Path=/; Max-Age=86399; HttpOnly; SameSite=Lax`.

### Your own crawler

`MatchKnownBot` matches
`(user_agent matches AND at least one path matches) AND (exact IP OR CIDR range OR FCrDNS)`
against newline-delimited JSON under `<datadir>/legit_bots/` (usually
`/var/lib/crowdsec/data/legit_bots/`):

```json
{"name":"mybot","user_agent":"mycorp-monitor","paths":["^/health(/|$)","^/status$"],"ranges":["10.42.0.0/16"],"ips":["192.0.2.77"]}
```

`name` required. `user_agent` / `paths` are regexes; omitted means "match anything". At least
one of `ips` / `ranges` / `rdns` is required — UA-only definitions are rejected at load. Anchor
`rdns` regexes (`(^|\.)googlebot\.com$`) or `evilgooglebot.com` matches. Parse, DNS and
unknown-file errors fail closed (bot is challenged). FCrDNS needs working reverse DNS from the
engine; the DNS cache is global engine config (`crowdsec_service` → `dns_cache`).

> **The `data:` block is mandatory.** Only files declared there are registered in the expr
> datafile registry; `MatchKnownBot` silently returns false for anything else. Verified — the
> same config matched nothing until the block was added.

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

Verified with that definition: `/status` from `10.42.0.9` or `192.0.2.77` with UA
`mycorp-monitor/1.0` is exempt (range / exact IP); the same UA from `1.2.3.4` is challenged (UA
alone proves nothing); `/other` from `10.42.0.9` is challenged (path not listed).

## Catch bots the scoring misses

`EvaluateMismatches()` returns a cached-per-request report: `.Has("cdp")`, `.Count()`,
`.High()` / `.Medium()` / `.Low()`, `.Reasons()`.

**Points live in the hub config, not the engine.** `crowdsecurity/appsec-bot-challenge-scoring`
is the source of truth — a normal hub item that gets revised and can be overridden; read it
with `sudo grep -B2 AddRequestScore /etc/crowdsec/appsec-configs/appsec-bot-challenge-scoring.yaml`.
As shipped in **0.2**:

| Points | Signals |
|---|---|
| **100** | `cdp`, `webdriver`, `webdriver_writable`, `selenium`, `playwright`, `webdriver_iframe`, `webdriver_worker`, `bot_user_agent` — declared automation; one clears every threshold |
| **50** | `headless_screen_resolution`, `missing_chrome_object`, `impossible_memory`, `inconsistent_etsl`, `mismatch_webgl_worker`, `mismatch_platform_iframe`, `mismatch_platform_worker` — headless / cross-context inconsistencies |
| **30** | `platform_mismatch`, `gpu_mismatch`, `high_cpu_count` — reachable by VMs and remote desktops |
| **15** | `utc_timezone`, `ua_mobile`, `accept_language` — common among real visitors |
| **5** | `swiftshader_renderer`, `mismatch_languages`, `timezone_country` — only meaningful in aggregate |

**Severity is a different axis.** `.High()` / `.Medium()` / `.Low()` do not read those points —
severity is a fixed engine label, and everything from 30 points upward is `high`, 15 is
`medium`, 5 is `low`. So `.High() >= 1` fires on a lone `gpu_mismatch`, far below any threshold.
Use `RequestScore()` or `.Has(...)` when you mean "strong evidence".

```yaml
inband:
  on_challenge_submit:
    # Re-weight: load between the scoring and threshold configs. Scores may be negative.
    - filter: EvaluateMismatches().Has("utc_timezone")
      apply:
        - AddRequestScore(45, "utc_timezone_mycorp")
    - filter: EvaluateMismatches().Has("ua_mobile")
      apply:
        - AddRequestScore(-15, "ua_mobile_expected")
    # Evidence the fingerprint cannot see.
    - filter: req.URL.Path startsWith "/checkout" && req.Header.Get("Referer") == ""
      apply:
        - AddRequestScore(30, "checkout_no_referer")
    # Reject on signal shape rather than score. Optional 2nd arg "minimal" / "info"
    # (default) / "verbose" controls logged fingerprint detail.
    - filter: EvaluateMismatches().High() >= 1
      apply:
        - 'RejectSubmission("high-severity mismatch")'
  on_challenge:
    # Escalate instead of rejecting.
    - filter: EvaluateMismatches().High() >= 1
      apply:
        - SetChallengeDifficulty("high")
        - SendChallenge()
    # Drop a cookie-bearing client that now shows automation.
    - filter: fingerprint.HasAutomationSignal()
      apply:
        - 'DropRequest("automation signal on cookie-bearing client")'
```

`fingerprint` also offers `IsBot()`, `HasBotSignal()`, `BotSignalCount()`, `BotSignals()`,
`HasHeadlessSignal()`, `HasMismatchSignal()`, `Platform()`, `Timezone()`, `Language()`,
`IsMobile()`, `CPUCount()`, `Memory()` —
<https://pkg.go.dev/github.com/crowdsecurity/crowdsec/pkg/appsec/challenge#FingerprintData>

## Custom scenarios on challenge events

Persistent bots are already covered: a rejected submission still emits `submitted`, so
`crowdsecurity/appsec-bot-challenge-too-many-submissions` fills on it (verified — eight
consecutive CDP rejections produced a ban), while a real browser solves once, takes its cookie
and stops submitting. Write your own to ban faster than submission volume allows, react to a
specific signal, or treat one rejection as terminal for a sensitive route. Both `evt.Meta` and
`evt.Parsed` paths work; shipped scenarios use `evt.Meta`.

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
  remediation: true       # what turns the alert into a decision, via your profiles
```

Parser-exposed fields: `source_ip`, `target_host`, `target_uri`, `request_uuid`,
`challenge_event`, `challenge_difficulty`, `challenge_fail_reason`, `fsid`, `fingerprint_bot`,
`http_user_agent`, `request_score`, `request_score_reasons`, `os`. `request_score_reasons` is a
flat string (`"cdp=100,utc_timezone=15"`) — match with
`evt.Meta.request_score_reasons contains "cdp="`. See
[../../configure/profiles.md](../../configure/profiles.md).
