---
verified:
  - date: 2026-05-21
    version: "1.7.8"
    env: systemd
    notes: "nginx acquisition + AppSec deploy"
  - date: 2026-05-22
    version: "1.7.8"
    env: k8s
    notes: "k8s with traefik + AppSec"
  - date: 2026-07-17
    version: "1.7.5-174-g66ab61fc-dirty"
    env: docker
    notes: "bot-detection/challenge collection install via hub_branch; Traefik local-plugin wiring for the structured challenge envelope (maxlerebourg/crowdsec-bouncer-traefik-plugin#343)"
---

# AppSec — Deploy

Canonical docs: <https://docs.crowdsec.net/docs/next/appsec/intro> · quickstart <https://docs.crowdsec.net/docs/next/appsec/quickstart/general> · rules deploy <https://docs.crowdsec.net/docs/next/appsec/rules_deploy> · advanced deployments <https://docs.crowdsec.net/docs/next/appsec/advanced_deployments>

## End-to-end recipe (bare-metal / systemd)

This recipe stands the WAF up on an engine that is already running, and proves the loop with `curl`. Per-environment variations follow at the bottom of the page. ("AppSec" is the internal component name — it appears below only in file paths and `cscli appsec-*` commands.)

### 1 — Install the canonical WAF collections

```bash
sudo cscli collections install \
    crowdsecurity/appsec-virtual-patching \
    crowdsecurity/appsec-generic-rules
```

| Collection | Brings |
|---|---|
| `crowdsecurity/appsec-virtual-patching` | CVE virtual patches (inband): `appsec-logs` parser, `appsec-vpatch`/`appsec-native`/`appsec-generic-test` scenarios, `appsec_base` context, `crowdsecurity/virtual-patching` **and** `crowdsecurity/appsec-default` configs, `base-config` + the full `vpatch-*` rule set. |
| `crowdsecurity/appsec-generic-rules` | Curated generic vectors (SSTI, WP upload abuse, no-user-agent, …): same parser/scenarios/context, `crowdsecurity/generic-rules` **and** `crowdsecurity/appsec-default` configs, `base-config` + `generic-*`/`experimental-*` rules. |

Both pull in `crowdsecurity/appsec-default` — the config used in the rest of
this recipe and the one that includes `crowdsecurity/appsec-generic-test` (the
rule the health-check probes). Each collection install resolves its full
dependency graph automatically; no manual glob expansion.

Verify:

```bash
sudo cscli appsec-configs list   # crowdsecurity/appsec-default → enabled
sudo cscli appsec-rules list     # base-config, vpatch-*, generic-* → enabled
```

### 2 — Add the AppSec acquisition

Create `/etc/crowdsec/acquis.d/appsec.yaml`:

```yaml
appsec_config: crowdsecurity/appsec-default
labels:
  type: appsec
listen_addr: 127.0.0.1:7422
source: appsec
```

| Field | Notes |
|---|---|
| `source: appsec` | Required. Identifies the datasource type. |
| `appsec_config` | Hub-installed config name. `crowdsecurity/appsec-default` is what step 1's collections install and it carries the health-check test rule. Multiple configs: use the plural key `appsec_configs:` — see [Advanced shapes](#advanced-shapes) below. |
| `listen_addr` | `127.0.0.1:7422` for loopback (single-host bouncer). `0.0.0.0:7422` to accept cross-host bouncers — pair with mTLS or a private network. |
| `labels.type: appsec` | Used by scenarios that consume out-of-band events. Keep as `appsec` unless you have a reason. |

### 3 — Create a bouncer API key

Each bouncer that talks to AppSec needs its own key. The key authenticates **both** decision pulls from LAPI and AppSec forwarding for that bouncer — same key, two purposes.

```bash
sudo cscli bouncers add my-appsec-bouncer
# prints the key — save it
```

> **Skip this step for the nginx bouncer.** The `crowdsec-nginx-bouncer` package self-registers its own bouncer and key on install (see [../configure/bouncers/web-servers.md](../configure/bouncers/web-servers.md)). Creating a key here too just leaves an orphan in `cscli bouncers list`. Only create a key manually for the smoke test below, or for bouncers that don't auto-register.

### 4 — Reload and verify the listener

```bash
sudo systemctl reload crowdsec
# wait for the listener — usually 1–2s
for _ in 1 2 3 4 5; do
    sudo ss -lntp | grep -q ':7422' && break
    sleep 1
done
sudo ss -lntp | grep 7422   # confirm
```

### 5 — Smoke-test the loop

```bash
KEY='<bouncer-key-from-step-3>'

# ALLOW
curl -sS -o /dev/null -w 'allow: %{http_code}\n' \
    -H "X-Crowdsec-Appsec-Api-Key: $KEY" \
    -H "X-Crowdsec-Appsec-Ip: 198.51.100.1" \
    -H "X-Crowdsec-Appsec-Host: example.test" \
    -H "X-Crowdsec-Appsec-Verb: GET" \
    -H "X-Crowdsec-Appsec-Uri: /" \
    http://127.0.0.1:7422/

# BLOCK (CVE-2017-9841)
curl -sS -o /dev/null -w 'block: %{http_code}\n' \
    -H "X-Crowdsec-Appsec-Api-Key: $KEY" \
    -H "X-Crowdsec-Appsec-Ip: 198.51.100.2" \
    -H "X-Crowdsec-Appsec-Host: example.test" \
    -H "X-Crowdsec-Appsec-Verb: GET" \
    -H "X-Crowdsec-Appsec-Uri: /vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php" \
    http://127.0.0.1:7422/

# Expected: allow: 200 / block: 403

sudo cscli metrics show appsec   # confirm processed/blocked counters and rule attribution
```

If any of the above don't match expectations, jump to [troubleshoot.md](./troubleshoot.md).

**For end-to-end validation through a real bouncer + web server**, the canonical probe is `GET /crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl`, which triggers `crowdsecurity/appsec-generic-test` — see [../operate/health-check.md](../operate/health-check.md) § AppSec. Because step 1 installs `crowdsecurity/appsec-default` (via either collection), that rule is present and the health-check passes with no extra steps.

## Wiring a real remediation bouncer

The smoke test above proves the WAF works. For production you point a real bouncer at it.

| Bouncer | Where to set the AppSec endpoint |
|---|---|
| `crowdsec-nginx-bouncer` (lua module) | `APPSEC_URL=http://127.0.0.1:7422` in `/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf` (shell-style `KEY=VALUE`, empty by default = WAF off). The self-registered `API_KEY` already serves AppSec — reuse it. |
| Traefik (`maxlerebourg/crowdsec-bouncer-traefik-plugin`) | Flat plugin options: `crowdsecAppsecEnabled: true` (default false), `crowdsecAppsecHost: <host>:<port>` (no scheme — `crowdsec:7422` in Docker Compose where the container is named `crowdsec`; `<release>-appsec-service.<namespace>.svc.cluster.local:7422` in Kubernetes), and the bouncer key in `crowdsecLapiKey`. In Kubernetes the Middleware `spec.plugin.<key>` must match the key registered in Traefik's `experimental.plugins.<key>` — NOT the module name `crowdsec-bouncer-traefik-plugin`. Full recipe in [../configure/bouncers/web-servers.md](../configure/bouncers/web-servers.md) § Traefik. For bot-detection/challenge mode specifically, see § Bot-detection / challenge mode below — the released plugin doesn't parse the structured challenge envelope yet. |
| `github.com/hslatman/caddy-crowdsec-bouncer` (Caddy module) | Two handlers required in the Caddy route — **`appsec` AND `crowdsec`** (see critical note below). The `appsec_url` field goes in the top-level `crowdsec` app config block. |
| Any other AppSec-aware bouncer | Look for an `appsec_url` / `appsec.url` field; auth is always the bouncer's existing API key. |

After wiring: send a request through the real web server (not directly to 7422) and confirm the verdict propagates. The bouncer's own log should show one line per consultation; AppSec's `cscli metrics show appsec` increments.

> **Critical — Caddy (`hslatman/caddy-crowdsec-bouncer`) requires TWO handlers:**
> the `crowdsec` handler only enforces IP-level bans from LAPI — it does **not** forward requests to port 7422. WAF inspection requires the separate `appsec` handler. Both must be in the route, `appsec` first. If only `crowdsec` is present, AppSec metrics will always show 0 processed and no requests are ever blocked by WAF rules. The `appsec_url` field lives in the top-level `crowdsec` app block. Full Caddyfile and JSON recipes: [../configure/bouncers/web-servers.md](../configure/bouncers/web-servers.md) § Caddy.

See also: [../configure/bouncers/web-servers.md](../configure/bouncers/web-servers.md) for installing the bouncer in the first place.

## Bot-detection / challenge mode (early feature)

**Not in a numbered release yet** — see [configure.md](./configure.md) § Bot-detection /
challenge mode for the config-side details (the `challenge:` block, hooks, known-bot
exemption). This section covers installing the collection and the bouncer-side requirement.

### Install

The collection isn't on the released hub index. Point `cscli.hub_branch` at the upstream
`[do-not-merge]` PR branch first (verified against `crowdsecurity/hub#1826`,
`test-waf-challenge-mode-scenarios` — see [../configure/hub.md](../configure/hub.md) §
Pinning to a hub branch for the full command sequence and the revert gotchas), then:

```bash
sudo cscli hub update
sudo cscli collections install crowdsecurity/appsec-bot-challenge
```

This pulls `appsec-bot-challenge-simple` (the config that serves the challenge), all nine
`appsec-bot-challenge-exclude-*` configs (each downloads its own verified-bot datafiles from
`hub-data.crowdsec.net` at install time), four scenarios (rate-limiting on
requested-but-never-solved / too-many-submissions / no-submission patterns, plus a
bot-detected alert), a parser, and a context. Add the configs you want to your acquisition's
`appsec_configs:` list alongside your base config (they combine field-by-field — see
[configure.md](./configure.md) § Acquisition file) and reload.

### Bouncer requirement — structured challenge envelope

Unlike a normal AppSec block, a challenge response is a `403` carrying a JSON envelope
(`action: "challenge"`, `http_status`, `user_body_content`, `user_headers`, `user_cookies`) that
the bouncer must parse and relay to the browser verbatim — not just treat as a block. A
compatible bouncer needs both of:

- **Route the challenge protocol paths through the same AppSec-enabled middleware/route as the
  protected application** — `/crowdsec-internal/challenge/*` (the challenge page, the
  proof-of-work JS worker, and the submit endpoint). The bouncer answers these directly from
  AppSec's envelope; they must never reach the real backend.
- **Parse the envelope on any `403`** and write `http_status` (default `200` if absent),
  `user_headers`, and each `user_cookies` entry as its own `Set-Cookie` header (never
  comma-joined) to the client. An empty-body or non-JSON `403` still falls back to a normal
  block — this is how older/incompatible bouncers degrade safely.

As of this writing, this parsing isn't in the *released* `maxlerebourg/crowdsec-bouncer-traefik-plugin` —
only in open PR `#343`. To test it, build the plugin as a Traefik **local plugin** from that
branch rather than installing the registered catalog entry:

```yaml
# docker-compose.yml (Traefik service)
command:
  - "--experimental.localplugins.bouncer.modulename=github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"
volumes:
  - ./plugin:/plugins-local/src/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin:ro   # git clone of the PR branch
```

```yaml
# protected service labels
- "traefik.http.routers.router-challenge.rule=PathPrefix(`/crowdsec-internal/challenge`)"
- "traefik.http.routers.router-challenge.middlewares=crowdsec@docker"
- "traefik.http.routers.router-challenge.service=<same service as the protected route>"
```

### Verify

```bash
curl -sS -D - http://<host>/<protected-path>
# expect: 200, Content-Type: text/html, X-Remediation: challenge (or whatever
# remediationheaderscustomname is set to), body is the challenge HTML — NOT a bare 403
```

A real browser will additionally solve the proof-of-work and reach the backend on the next
request; curl alone only proves the envelope is being relayed, not a full solve — check
`cscli metrics show appsec` (see [configure.md](./configure.md) § Verify) for `Ch. Requested`
incrementing, and `Ch. Accepted` once something has actually solved it.

## Per-environment notes

| Env | What changes |
|---|---|
| **systemd / bare-metal** | The recipe above as-is. |
| **OPNsense / FreeBSD** | Config root is `/usr/local/etc/crowdsec/`; drop acquisition in `acquis.d/appsec.yaml`. The `os-crowdsec` plugin manages the engine — reload with `service crowdsec reload`. No Lua module in the OPNsense nginx package: use the Caddy-based bouncer instead (see [../configure/bouncers/web-servers.md](../configure/bouncers/web-servers.md) § Caddy). Note the LAPI port conflict below. |
| **Docker / compose** | AppSec runs inside the crowdsec container and must `listen_addr: 0.0.0.0:7422`. Bouncer containers reach it via the service name + internal port (`appsec_url: http://crowdsec:7422`), not the published port. The acquisition file is mounted from the host or baked into a customised image. `docker compose exec crowdsec cscli appsec-*` for management commands. **Containerized lua bouncers need a DNS `resolver` — see [../install/docker.md](../install/docker.md) § Bouncer key bootstrap.** |
| **Kubernetes / Helm** | Set `appsec.enabled: true`, `appsec.acquisitions` (list, not scalar — use `appsec_configs:` plural), and `appsec.env` with `COLLECTIONS`. **Also required:** either `agent.enabled: false` or a populated `agent.acquisition` — the chart template rejects values with no agent acquisition at all. Use `helm upgrade --install` (plain `helm upgrade` fails on a fresh cluster with no prior release). The chart creates a service named `<release>-appsec-service`; bouncers reach AppSec at `<release>-appsec-service.<namespace>.svc.cluster.local:7422`. For the Traefik plugin: Traefik needs a writable `/plugins-storage` volume (add an `emptyDir` via `deployment.additionalVolumes` + `additionalVolumeMounts`) and the plugin must be registered under `experimental.plugins.<key>` in Traefik Helm values — the `spec.plugin.<key>` in the Middleware must match that same key name. Create the bouncer key with `kubectl exec -n crowdsec deploy/crowdsec-lapi -- cscli bouncers add <name>`. Cross-namespace Middleware references are disabled by default — either put the Middleware in the same namespace as the IngressRoute, or enable `providers.kubernetesCRD.allowCrossNamespace: true` in Traefik. |

### OPNsense / FreeBSD: LAPI port conflict

CrowdSec LAPI binds to `127.0.0.1:8080` by default. Any bouncer that listens on `*:8080` (wildcard) will shadow the LAPI only from external IPs — loopback (`127.0.0.1`) always routes to LAPI. This means:

- **Do not test via `127.0.0.1:8080`** — you will hit LAPI, not the bouncer.
- Use the host's internal or external IP for end-to-end testing (e.g. `172.31.x.x:8080` on an AWS instance).
- If both LAPI and the bouncer bind `:8080`, move the **bouncer's backend** to another port (e.g. `:8888`) and keep the bouncer frontend on `:8080` listening on `0.0.0.0` only — LAPI stays on its loopback bind and the conflict is resolved.

## Advanced shapes

- **AppSec on a separate host** from the engine: set `listen_addr` to the private interface and protect with mTLS (cert configuration on both bouncer and AppSec sides; documented at <https://docs.crowdsec.net/docs/next/appsec/advanced_deployments>).
- **Multiple AppSec endpoints behind a load balancer**: each AppSec replica must be served by an engine that shares the same LAPI for decision sync. Sticky sessions are not required — AppSec evaluation is stateless across replicas.
- **Multiple configs on one AppSec listener**: the shape, the overlap rule (`duplicated rule id 100`), and why `crowdsecurity/appsec-default` is usually enough on its own live in [configure.md](./configure.md) § appsec-config file.
- **Engine-on-a-different-host than AppSec**: not supported — AppSec is part of the crowdsec agent process.

## Advanced: install a bare appsec-config without its collection

The collection install in step 1 is the recommended path. Use this only if you want strict subset control (a specific config without its full collection).

```bash
cscli appsec-configs list -a       # see hub catalogue
sudo cscli appsec-configs install crowdsecurity/virtual-patching
```

| appsec-config | Purpose | Mode |
|---|---|---|
| `crowdsecurity/virtual-patching` | CVE virtual patches | inband |
| `crowdsecurity/generic-rules` | Curated generic checks (env files, git config, etc.) | inband |
| `crowdsecurity/crs-inband` | OWASP Core Rule Set, inband evaluation | inband |
| `crowdsecurity/crs` | OWASP CRS, out-of-band → scenarios | out-of-band |

**Installing a bare appsec-config does NOT install its rules.** The engine fatally fails to start with `no appsec-rules found for pattern <name>` if any are missing. Read the config and install everything it lists:

```bash
sudo cat /etc/crowdsec/appsec-configs/virtual-patching.yaml
# inband_rules:
#  - crowdsecurity/base-config
#  - crowdsecurity/vpatch-*
```

`cscli appsec-rules install` **does not expand globs** even though the engine does at load time. Expand them yourself from the hub listing:

```bash
VPATCH=$(cscli appsec-rules list -a -o raw | awk -F, '/^crowdsecurity\/vpatch-/ {print $1}')
{ echo crowdsecurity/base-config; echo "$VPATCH"; } \
    | xargs sudo cscli appsec-rules install
sudo cscli appsec-rules list   # every glob-expanded rule should be 'enabled'
```

Note: the bare `crowdsecurity/virtual-patching` config does **not** include `crowdsecurity/appsec-generic-test`, so the WAF health-check will not pass under it. Use `crowdsecurity/appsec-default` (or install via the collection in step 1) if you want the health-check to succeed.
