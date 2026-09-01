---
verified:
  - date: 2026-08-31
    version: "1.8.0"
    env: systemd
    notes: "collection install, glob acquisition, nginx bouncer 1.2.2 at default config, challenge served, CDP browser rejected, alert + metrics, too-many-submissions ban; ALWAYS_SEND_TO_APPSEC semantics"
  - date: 2026-08-31
    version: "1.8.0-rc2"
    env: docker
    notes: "install + acquisition + engine-level smoke test; no bouncer wired"
---

# Deploy bot detection

Canonical: <https://docs.crowdsec.net/docs/next/appsec/bot_detection/enable> ·
[what's included](https://docs.crowdsec.net/docs/next/appsec/bot_detection/whats_included).
Prerequisite: a working AppSec listener — [../deploy.md](../deploy.md).

## 1 — Pick exactly one bundle

| Collection | Threshold config | Rejects at |
|---|---|---|
| `crowdsecurity/appsec-bot-challenge` | `…-scoring-balanced` | ≥ 75 |
| `crowdsecurity/appsec-bot-challenge-strict` | `…-scoring-strict` | ≥ 45 |
| `crowdsecurity/appsec-bot-challenge-permissive` | `…-scoring-permissive` | ≥ 100 |

Separately installable building blocks: `…-scoring` (scoring engine, never rejects),
`…-good-bots` (verified-crawler exclusions), `…-exclude-paths`.

> **One bundle only.** The `appsec-bot-*` glob loads every installed threshold config and their
> rejection rules stack — the strictest wins silently. Verified: `-strict` alongside the default
> leaves both loaded, rejecting at 45. `cscli appsec-configs list | grep scoring` must show the
> engine plus **one** threshold.

```bash
sudo cscli collections install crowdsecurity/appsec-bot-challenge
```

Prefix: `sudo cscli …` / `docker exec <name> cscli …` / `kubectl exec -n <ns> <pod> -- cscli …`.
Docker: prefer `-e COLLECTIONS="crowdsecurity/appsec-bot-challenge"` so it survives a container
replace.

## 2 — Acquisition

```yaml
# /etc/crowdsec/acquis.d/appsec.yaml
listen_addr: 127.0.0.1:7422
appsec_configs:
  - crowdsecurity/appsec-default        # existing WAF config, if any
  - crowdsecurity/appsec-bot-*
labels:
  type: appsec
source: appsec
```

Globs expand against **installed** appsec-configs only; matching nothing is fatal, so install
the collection first:

```
FATAL crowdsec init: while loading acquisition config: /etc/crowdsec/acquis.d/appsec.yaml: datasource of type appsec: unable to resolve appsec_config "crowdsecurity/appsec-bot-*": no installed appsec-config matches pattern "crowdsecurity/appsec-bot-*"
```

Your own configs are not matched by the `crowdsecurity/` glob — list them by name. Docker: mount
the acquisition dir *and* a `/var/lib/crowdsec/data` volume (the entrypoint refuses to start
without it). k8s: acquisition goes in the log-processor ConfigMap. Then reload and confirm:

```bash
sudo systemctl reload crowdsec
sudo cscli appsec-configs list
sudo grep "WAF challenge runtime initialized" /var/log/crowdsec.log
```

## 3 — Wire the bouncer

nginx / OpenResty — `APPSEC_URL=http://127.0.0.1:7422` in
`/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf` is all that is required; the bouncer
consults AppSec for every IP with no decision.

> **Leave `ALWAYS_SEND_TO_APPSEC` at its default (`false`).** It only governs *already banned*
> IPs: the default serves them the ban page without consulting AppSec. `true` sends them to
> AppSec too, and since bot-detection configs challenge everything, a `ban` is effectively
> downgraded to a challenge. Verified on 1.2.2.

`sudo nginx -t && sudo systemctl restart nginx` — prefer `restart` over `reload`, since the lua
module reads config at init and a graceful reload can keep old workers serving.

A supported bouncer handles the protocol ([./overview.md](./overview.md) § Bouncer support), but
a CDN or reverse proxy in front of it can break the challenge. Three things must arrive intact:
`/crowdsec-internal/challenge/*` (JS assets, `POST …/submit`), served by AppSec and not your
origin — routing, caching or rewriting them breaks the loop
([./troubleshoot.md](./troubleshoot.md) § 3); the `__crowdsec_challenge` cookie in both
directions, since stripping `Set-Cookie` or `Cookie` causes an endless loop (§ 4); and the real
client IP on every request including assets and the submit
([../../configure/bouncers/web-servers.md](../../configure/bouncers/web-servers.md)).
Implementing the protocol in a new bouncer is out of scope —
<https://docs.crowdsec.net/docs/next/appsec/bot_detection/challenge_protocol>.

## 4 — Smoke test

### a. Engine level (no bouncer needed)

```bash
KEY=$(sudo cscli bouncers add smoketest -o raw)
q(){ curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7422/ \
  -H "x-crowdsec-appsec-api-key: $KEY" -H "x-crowdsec-appsec-ip: $2" \
  -H "x-crowdsec-appsec-host: example.com" -H "x-crowdsec-appsec-uri: $1" \
  -H "x-crowdsec-appsec-verb: GET" -H "x-crowdsec-appsec-user-agent: $3"; }

q /            1.2.3.4     "Mozilla/5.0"     # 403 — challenged
q /robots.txt  1.2.3.4     "Mozilla/5.0"     # 200 — crawler-files exclusion
q /style.css   1.2.3.4     "Mozilla/5.0"     # 200 — static exclusion
q /api/v1/x    1.2.3.4     "Mozilla/5.0"     # 200 — api exclusion
q /            1.2.3.4     "Googlebot/2.1"   # 403 — spoofed UA, no IP proof
q /            66.249.66.1 "Googlebot/2.1"   # 200 — real Googlebot, FCrDNS verified
```

The last pair is the useful one. `403` means "challenge issued", not "banned". Drop
`-o /dev/null -w …` to see the envelope: `action`, `http_status`, `user_body_content` (the
challenge HTML) and `user_headers` (`Content-Type: text/html`, `Cache-Control: no-cache,
no-store`, and the challenge's own `Content-Security-Policy`). No `user_cookies` on the initial
challenge — the cookie appears only on a solved submission or a `GrantChallengeCookie()` grant.

### b. Through the bouncer

```bash
curl -s -o /tmp/c.html -w "%{http_code} %{size_download}\n" http://your-site/
grep -c "CrowdSec Challenge" /tmp/c.html
```

Expect `200` with a few hundred KB containing `CrowdSec Challenge`.

### c. Prove a bot gets caught

Point any CDP-driven browser at the site (Puppeteer, Playwright-Chromium,
`chrome --remote-debugging-port`). `cdp` alone scores 100, above every threshold.

```
level=info msg="on_challenge_submit rejected" automation=true cpu_count=16 fsid=FS1_0000100… is_bot=true language=en-US reason="request score 100" signals="[cdp]" source=203.0.113.7 timezone=Europe/Paris ua="Mozilla/5.0 … Chrome/148.0.0.0 Safari/537.36" url="http://your-site/"
level=info msg="WAF bot-detection: 203.0.113.7 rejected by crowdsecurity/rejected-browser-submission (request score 100)"
```

```bash
sudo cscli alerts list --kind bot-detection
sudo cscli alerts inspect <id> -d      # bot_detected, challenge_event=rejected, fail_reason,
                                       # request_score, score_reasons=cdp=100
```

One rejection has `Remediation: false` and does not ban. Keep the bot running and the shipped
scenarios ban it — verified after eight consecutive rejections:

| Scenario | Fires on |
|---|---|
| `…-too-many-requests` | Challenge served 10×/20s with no submission. Cancelled once a submission arrives, so a real browser never trips it. |
| `…-too-many-submissions` | 5 submissions/20s. Rejected submissions count, so this bans a bot failing the fingerprint check. A real browser solves once, takes its cookie and stops submitting. |

### d. Metrics

```bash
sudo cscli metrics show bot-detection
```

```
| Bot Detection   | Requested | Submitted | Solved | Granted | Exempt | Protocol Failures | Submissions Rejected | Cookies Invalid |
| 127.0.0.1:7422/ | 7         | 1         | -      | -       | 7      | -                 | 1                    | -               |
```

Column meanings: [./troubleshoot.md](./troubleshoot.md) § 7. Next:
[./configure.md](./configure.md), [./customize.md](./customize.md).
