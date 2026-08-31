---
verified:
  - date: 2026-08-31
    version: "1.8.0"
    env: systemd
    notes: "full loop: collection install, glob acquisition, nginx bouncer 1.2.2 at default config, challenge served, CDP browser rejected, alert + metrics, too-many-submissions ban after repeated rejections; ALWAYS_SEND_TO_APPSEC semantics re-tested"
  - date: 2026-08-31
    version: "1.8.0-rc2"
    env: docker
    notes: "install + acquisition + engine-level smoke test; no bouncer wired"
---

# Deploy bot detection

Canonical docs: <https://docs.crowdsec.net/docs/next/appsec/bot_detection/enable> ·
[what's included](https://docs.crowdsec.net/docs/next/appsec/bot_detection/whats_included)

Prerequisite: a working AppSec listener — [../deploy.md](../deploy.md). This doc only adds
bot detection on top.

## 1 — Pick exactly one bundle

| Collection | Loads threshold config | Rejects at score |
|---|---|---|
| `crowdsecurity/appsec-bot-challenge` | `…-scoring-balanced` | ≥ 75 |
| `crowdsecurity/appsec-bot-challenge-strict` | `…-scoring-strict` | ≥ 45 |
| `crowdsecurity/appsec-bot-challenge-permissive` | `…-scoring-permissive` | ≥ 100 |

Start with the balanced bundle. Each also pulls three building blocks you can install on
their own if you are assembling a custom stack: `…-scoring` (the scoring engine, never
rejects), `…-good-bots` (verified-crawler exclusions), `…-exclude-paths` (path exclusions).

> **Install one bundle, not several.** The `crowdsecurity/appsec-bot-*` glob below loads
> *every* threshold config you have installed, and their rejection rules stack — the
> strictest wins, silently overriding your choice. Verified: installing `-strict` alongside
> the default leaves both `appsec-bot-challenge-scoring-balanced.yaml` and
> `…-strict.yaml` loaded, so rejection happens at 45, not 75. Check with
> `cscli appsec-configs list | grep scoring` — you should see the engine plus **one**
> threshold config.

```bash
sudo cscli collections install crowdsecurity/appsec-bot-challenge
```

| Env | Prefix |
|---|---|
| systemd | `sudo cscli …` |
| docker | `docker exec <name> cscli …` |
| k8s | `kubectl exec -n <ns> <pod> -- cscli …` |

Docker: prefer baking it in with `-e COLLECTIONS="crowdsecurity/appsec-bot-challenge"` so it
survives a container replace.

## 2 — Acquisition

`/etc/crowdsec/acquis.d/appsec.yaml`:

```yaml
listen_addr: 127.0.0.1:7422
appsec_configs:
  - crowdsecurity/appsec-default        # your existing WAF config, if any
  - crowdsecurity/appsec-bot-*
labels:
  type: appsec
source: appsec
```

Glob patterns in `appsec_configs` are themselves version-gated (see SKILL.md § Step 1.6). They expand against **installed**
appsec-configs only, and a pattern matching nothing is fatal at startup:

```
FATAL crowdsec init: while loading acquisition config: /etc/crowdsec/acquis.d/appsec.yaml: datasource of type appsec: unable to resolve appsec_config "crowdsecurity/appsec-bot-*": no installed appsec-config matches pattern "crowdsecurity/appsec-bot-*"
```

So install the collection **before** writing the glob. Custom configs of your own are not
matched by the `crowdsecurity/` glob and must be listed by name — see
[./customize.md](./customize.md).

Docker: mount the acquisition dir *and* a data volume (`/var/lib/crowdsec/data`), which the
entrypoint refuses to start without. Kubernetes: the acquisition goes in the log-processor
ConfigMap.

Reload, then confirm:

```bash
sudo systemctl reload crowdsec
sudo cscli appsec-configs list
sudo grep "WAF challenge runtime initialized" /var/log/crowdsec.log
```

## 3 — Wire the bouncer

Setting `APPSEC_URL` is not enough. Bot detection needs the bouncer to send **every** request
to AppSec, and to treat four internal paths as AppSec's, not the origin's.

### nginx / OpenResty

`/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf`:

```ini
APPSEC_URL=http://127.0.0.1:7422
```

That is all bot detection needs — the bouncer consults AppSec for every IP that has no
decision, so clean visitors get challenged out of the box.

**Leave `ALWAYS_SEND_TO_APPSEC` at its default (`false`).** It only governs IPs that are
*already banned*: with the default they get the ban page and AppSec is never consulted, which
is what you want. Setting it to `true` sends banned IPs to AppSec as well, and since the
bot-detection configs challenge everything, a `ban` decision is effectively downgraded to a
challenge. Verified on 1.2.2 — a banned IP returned the 403 ban page with the default and the
challenge page with `true`.

Then `sudo nginx -t && sudo systemctl restart nginx`. Prefer `restart` over `reload` after
editing the bouncer config: the lua module reads it at init, and a graceful reload can keep
serving from old workers long enough to look like the change had no effect.

### What has to survive between client and AppSec

A supported bouncer handles the challenge protocol for you — picking one from
[./overview.md](./overview.md) § Bouncer support is the whole job. What you do own is
everything *else* in the request path: a CDN, reverse proxy or WAF in front of the bouncer can
silently break the challenge. Three things must reach their destination intact:

- **`/crowdsec-internal/challenge/*`** (the JS assets and the `POST …/submit`) — these are
  served by AppSec, not your origin. A proxy that routes, caches, or rewrites them breaks the
  loop; symptoms in [./troubleshoot.md](./troubleshoot.md) § 3.
- **The `__crowdsec_challenge` cookie**, in both directions. Anything stripping `Set-Cookie`
  or `Cookie` produces an endless challenge loop (§ 4).
- **The real client IP**, on every request including the assets and the submit — not just the
  first page. See [../../configure/bouncers/web-servers.md](../../configure/bouncers/web-servers.md)
  for per-bouncer real-IP configuration.

Writing a bouncer that speaks the challenge protocol is out of scope here — the wire format,
status codes and cookie handling are specified in
<https://docs.crowdsec.net/docs/next/appsec/bot_detection/challenge_protocol>.

## 4 — Smoke test

### a. Engine level — works with no bouncer at all

Useful anywhere, and the only option if your bouncer has no bot-detection support yet.

```bash
KEY=$(sudo cscli bouncers add smoketest -o raw)
q(){ curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7422/ \
  -H "x-crowdsec-appsec-api-key: $KEY" \
  -H "x-crowdsec-appsec-ip: $2" \
  -H "x-crowdsec-appsec-host: example.com" \
  -H "x-crowdsec-appsec-uri: $1" \
  -H "x-crowdsec-appsec-verb: GET" \
  -H "x-crowdsec-appsec-user-agent: $3"; }

q /            1.2.3.4     "Mozilla/5.0"     # 403 — challenged
q /robots.txt  1.2.3.4     "Mozilla/5.0"     # 200 — crawler-files exclusion
q /style.css   1.2.3.4     "Mozilla/5.0"     # 200 — static exclusion
q /api/v1/x    1.2.3.4     "Mozilla/5.0"     # 200 — api exclusion
q /            1.2.3.4     "Googlebot/2.1"   # 403 — spoofed UA, no IP proof
q /            66.249.66.1 "Googlebot/2.1"   # 200 — real Googlebot, FCrDNS verified
```

The last two are the useful pair: a bot claiming to be Googlebot from an arbitrary IP is
still challenged, while the real crawler is waved through. `403` here means "challenge
issued", not "banned" — see the `http_status` note in [./overview.md](./overview.md).

To see the envelope itself:

```bash
curl -s http://127.0.0.1:7422/ -H "x-crowdsec-appsec-api-key: $KEY" \
  -H "x-crowdsec-appsec-ip: 1.2.3.4" -H "x-crowdsec-appsec-host: example.com" \
  -H "x-crowdsec-appsec-uri: /" -H "x-crowdsec-appsec-verb: GET" \
  -H "x-crowdsec-appsec-user-agent: Mozilla/5.0" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); d["user_body_content"]=d["user_body_content"][:60]; print(json.dumps(d,indent=2))'
```

```json
{
  "action": "challenge",
  "http_status": 200,
  "user_body_content": "<!DOCTYPE html>\n<html lang=\"en\">\n  <head>\n    <title>CrowdSec",
  "user_headers": {
    "Cache-Control": ["no-cache, no-store"],
    "Content-Security-Policy": ["default-src 'self'; script-src 'self' 'unsafe-inline'; …"],
    "Content-Type": ["text/html"]
  }
}
```

No `user_cookies` on the initial challenge — the cookie only appears on a solved submission
or a `GrantChallengeCookie()` grant.

### b. Through the bouncer

```bash
curl -s -o /tmp/c.html -w "%{http_code} %{size_download}\n" http://your-site/
grep -c "CrowdSec Challenge" /tmp/c.html
```

Expect `200` with a body of a few hundred KB containing `CrowdSec Challenge` — the engine
returned 403 and the bouncer rendered it as a 200 page.

### c. Prove a bot gets caught

Point any CDP-driven browser at the site — Puppeteer, Playwright-Chromium, or
`chrome --remote-debugging-port`. The `cdp` signal alone scores 100, over every threshold.

```js
// npm i puppeteer && node cdp-check.js
const puppeteer = require("puppeteer");
(async () => {
  const b = await puppeteer.launch({ headless: false });
  const p = await b.newPage();
  await p.goto("http://your-site/", { waitUntil: "networkidle0" });
  await b.close();
})();
```

Expected — the browser solves the PoW, submits, and is rejected on its fingerprint:

```
level=info msg="on_challenge_submit rejected" automation=true cpu_count=16 fsid=FS1_0000100… is_bot=true language=en-US reason="request score 100" signals="[cdp]" source=203.0.113.7 timezone=Europe/Paris ua="Mozilla/5.0 (X11; Linux x86_64) … Chrome/148.0.0.0 Safari/537.36" url="http://your-site/"
level=info msg="WAF bot-detection: 203.0.113.7 rejected by crowdsecurity/rejected-browser-submission (request score 100)"
```

```bash
sudo cscli alerts list --kind bot-detection
sudo cscli alerts inspect <id> -d
```

```
| bot_detected     | true              |
| challenge_event  | rejected          |
| fail_reason      | request score 100 |
| request_score    | 100               |
| score_reasons    | cdp=100           |
| target_uri       | /                 |
```

The alert shows `Remediation: false` — one rejection records the catch without banning. Keep
the bot running and the shipped scenarios ban it; verified here after eight consecutive
rejections:

| Scenario | Fires on |
|---|---|
| `crowdsecurity/appsec-bot-challenge-too-many-requests` | Served the challenge 10×/20s without ever submitting. Cancelled as soon as a submission arrives, so a real browser never trips it. |
| `crowdsecurity/appsec-bot-challenge-too-many-submissions` | 5 submissions/20s. Rejected submissions count too, so this is what bans a bot that keeps failing the fingerprint check. A real browser solves once, takes its cookie and stops submitting. |

### d. Metrics

```bash
sudo cscli metrics show bot-detection
```

```
| Bot Detection   | Requested | Submitted | Solved | Granted | Exempt | Protocol Failures | Submissions Rejected | Cookies Invalid |
| 127.0.0.1:7422/ | 7         | 1         | -      | -       | 7      | -                 | 1                    | -               |
```

Detail in [./troubleshoot.md](./troubleshoot.md) § 7.

Next: [./configure.md](./configure.md) for multi-instance and cookie tuning,
[./customize.md](./customize.md) to change who gets challenged.
