# AppSec — Overview

Canonical docs: <https://docs.crowdsec.net/docs/next/appsec/intro> · request lifecycle <https://docs.crowdsec.net/docs/next/appsec/request-lifecycle> · protocol <https://docs.crowdsec.net/docs/next/appsec/protocol> · FAQ <https://docs.crowdsec.net/docs/next/appsec/faq>

## What AppSec actually is

AppSec is an HTTP server bundled into the CrowdSec agent. A **remediation bouncer** (nginx, traefik, caddy, or any AppSec-aware bouncer) intercepts a client request, forwards a copy of its metadata to AppSec, and enforces the verdict AppSec returns. AppSec itself does not sit inline with traffic — it's an out-of-band oracle the bouncer consults.

Request flow on a default deployment:

```
client ──► web server / ingress
              │
              ▼
        remediation bouncer ──► AppSec endpoint (127.0.0.1:7422)
              │                     │
              │       verdict ◄─────┘
              ▼
     allow / 403 / captcha
```

The AppSec endpoint listens on whatever address the AppSec acquisition file sets (`listen_addr`). Default is loopback; production deployments often expose it on a private interface so several bouncers can reach a single AppSec. `listen_addr` is interpreted per environment: bare-metal binds the host address directly; Docker needs `0.0.0.0` so the published port is reachable; Kubernetes reaches it via the AppSec Service DNS. See [deploy.md](./deploy.md).

## Terminology

| Term | What it is |
|---|---|
| **AppSec component** | The HTTP server hosted by the CrowdSec agent. Listens for bouncer requests, runs rules against them, returns a verdict. |
| **appsec-config** | A hub item (e.g. `crowdsecurity/virtual-patching`, `crowdsecurity/crs`) that names a set of `inband_rules` / `out_of_band_rules` and a `default_remediation`. Lives in `/etc/crowdsec/appsec-configs/`. |
| **appsec-rule** | A single matching rule (e.g. `crowdsecurity/vpatch-CVE-2017-9841`). Hub items in `/etc/crowdsec/appsec-rules/`. Authoring is out of this skill's scope — see SKILL.md. |
| **inband rule** | Matches a request and returns `block` **immediately**. Produces a `kind: waf` alert with `Remediation: false` (no default ban — the 403 is already enforced per-request). Visibility: `cscli metrics show appsec` and `cscli alerts list`. |
| **out-of-band rule** | Matches a request and emits an event into the regular scenarios/buckets pipeline, the same way log-derived events do. Produces normal `kind: crowdsec` alerts and (via profiles) decisions. |
| **remediation bouncer** | The component that actually enforces the verdict. AppSec doesn't block traffic — bouncers do. |

## Protocol — what the bouncer sends

Bouncers forward request metadata over HTTP to the AppSec endpoint. The relevant headers:

| Header | Meaning |
|---|---|
| `X-Crowdsec-Appsec-Api-Key` | Bouncer's API key (created via `cscli bouncers add`). Mismatch → 401. |
| `X-Crowdsec-Appsec-Ip` | Original client IP. |
| `X-Crowdsec-Appsec-Host` | Original `Host` header. |
| `X-Crowdsec-Appsec-Verb` | HTTP method of the original request. |
| `X-Crowdsec-Appsec-Uri` | Original URI (path + query). |
| `X-Crowdsec-Appsec-User-Agent` | Original User-Agent. |
| Request body | Forwarded as-is (subject to body-size limits). |

Response codes from AppSec:

| Code | Meaning |
|---|---|
| `200` | Allow. |
| `401` | Bouncer auth failure (wrong / missing API key). |
| `403` | Block (default; the response code is configurable per appsec-config). |

A clean way to confirm the loop works on a freshly deployed AppSec is to invoke it with `curl` directly using a real bouncer key — see [deploy.md](./deploy.md) for the recipe.

## When to use what

| Goal | Mode | Result |
|---|---|---|
| Patch a known CVE / shut down `/.env` / block obviously bad paths | **inband** (e.g. `crowdsecurity/virtual-patching`) | Per-request 403. `kind: waf` alert with `Remediation: false`. No IP-level ban from the default profile (each block is already enforced). |
| Detect probing patterns over many requests and ban the source IP | **out-of-band** + scenarios (e.g. `crowdsecurity/crs` feeding `crowdsecurity/appsec-*` scenarios) | Bucket fills → alert → decision → bouncer pulls the IP into its blocklist on next poll. |
| Both — fast-fail on virtual patches **and** ban probers | install both an inband config and an out-of-band config in the same AppSec acquisition | Independent pipelines. |

The most common confusion when standing AppSec up: a user installs `virtual-patching` (inband), watches `cscli metrics show appsec` increment `Blocked`, then immediately runs `cscli alerts list` and sees nothing. The alerts do appear — but on the next signal-push cycle (several seconds), and they have `Remediation: false` so the default profile won't create a ban decision from them. See [troubleshoot.md](./troubleshoot.md).
