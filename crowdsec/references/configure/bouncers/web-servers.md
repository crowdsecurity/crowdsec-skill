# Bouncers — Web servers (nginx, haproxy, apache, Traefik, Caddy)

Canonical docs: <https://docs.crowdsec.net/u/bouncers/intro> (per-bouncer pages: nginx, haproxy, apache, traefik, caddy)

A web-server bouncer enforces two things at the edge:
1. **LAPI decisions** — IPs banned by scenarios/CTI get a 403 (or captcha).
2. **AppSec/WAF** (optional) — each request is forwarded to the AppSec listener for inline inspection before it reaches the backend.

Both are served by the **same bouncer API key**. Wiring the WAF is just pointing the bouncer's AppSec URL at the `:7422` listener — see [../../appsec/deploy.md](../../appsec/deploy.md).

## Pick your bouncer

Jump to the section for your web server. The shared model above (decisions + optional WAF, one key) and the stream-lag / real-IP pitfalls recur across all of them.

| Section | Package / module | WAF (AppSec)? |
|---|---|---|
| § nginx | `crowdsec-nginx-bouncer` (lua) | ✅ |
| § haproxy | `crowdsec-haproxy-spoa-bouncer` (SPOA) | ✅ |
| § apache | `crowdsec-apache2-bouncer` (`mod_crowdsec`) | ❌ decisions only |
| § Traefik | `crowdsec-bouncer-traefik-plugin` (Yaegi middleware) | ✅ |
| § Caddy | `caddy-crowdsec-bouncer` (compiled-in module) | ✅ |

## nginx — `crowdsec-nginx-bouncer`

Targets Ubuntu 24.04 / nginx 1.24, engine v1.7.8.

### Install — the package self-registers

```bash
sudo apt-get install -y crowdsec-nginx-bouncer
```

The package does three things automatically, so **do not** run `cscli bouncers add` first:
- registers its own bouncer (`crowdsec-nginx-bouncer-<timestamp>`) and writes the key into its config,
- drops the lua snippet into `/etc/nginx/conf.d/crowdsec_nginx.conf`,
- reloads nginx.

Confirm:

```bash
sudo cscli bouncers list          # crowdsec-nginx-bouncer-... → valid, recent
sudo nginx -t                     # snippet syntactically OK
```

> If you manually created a bouncer key for AppSec earlier (e.g. `cscli bouncers add my-appsec-bouncer`), it is now redundant — the package's auto-registered key serves both LAPI decisions **and** AppSec. Delete the orphan with `cscli bouncers delete my-appsec-bouncer` to keep the list clean.

### Config — `/etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf`

Shell-style `KEY=VALUE` (not YAML). The keys that matter:

| Key | Set to | Notes |
|---|---|---|
| `API_KEY` | (auto-filled) | The self-registered bouncer key. Leave it. |
| `API_URL` | `http://127.0.0.1:8080` | LAPI endpoint. |
| `ENABLED` | `true` | Master switch. |
| `MODE` | `live` | `live` = query LAPI per request window; `stream` = poll the full decision list periodically (default, lower latency, recommended for production). |
| `UPDATE_FREQUENCY` | `10` | Seconds between decision pulls in stream mode. **A new ban takes up to this long to enforce — wait ~12s before testing.** |
| `BOUNCING_ON_TYPE` | `all` | `ban`, `captcha`, or `all`. |
| `APPSEC_URL` | `http://127.0.0.1:7422` | **Empty by default = WAF off.** Set this to turn on inline AppSec inspection. |
| `APPSEC_FAILURE_ACTION` | `passthrough` | Fail-open (allow if WAF unreachable) — sensible default. Set to `deny` for fail-closed. |

To enable the WAF:

```bash
sudo sed -i 's|^APPSEC_URL=.*|APPSEC_URL=http://127.0.0.1:7422|' \
    /etc/crowdsec/bouncers/crowdsec-nginx-bouncer.conf
sudo nginx -t && sudo systemctl reload nginx
```

### Verify end-to-end (through nginx, not directly to :7422)

```bash
# 1. Normal request → 200
curl -sS -o /dev/null -w 'normal:        %{http_code}\n' http://127.0.0.1/

# 2. AppSec inline block (CVE-2017-9841) → 403
curl -sS -o /dev/null -w 'appsec block:  %{http_code}\n' \
    'http://127.0.0.1/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php'

# 3. LAPI decision block: ban self, WAIT for UPDATE_FREQUENCY, then test
sudo cscli decisions add --ip 127.0.0.1 --duration 2m --reason wiring-test
sleep 12                                            # UPDATE_FREQUENCY=10s
curl -sS -o /dev/null -w 'banned:        %{http_code}\n' http://127.0.0.1/   # → 403
sudo cscli decisions delete --ip 127.0.0.1
sleep 12
curl -sS -o /dev/null -w 'after unban:   %{http_code}\n' http://127.0.0.1/   # → 200
```

Confirm rule attribution: `sudo cscli metrics show appsec` should show the triggered rules (`vpatch-CVE-2017-9841`, etc.).

### Pitfalls

- **Behind a CDN / reverse proxy:** nginx must trust the real client IP. Set `real_ip` / `set_real_ip_from` for your upstream so bans apply to the actual visitor, not the proxy.
- **`MODE=stream` lag:** a fresh ban is not instant — it lands within `UPDATE_FREQUENCY`. Tests that ban-then-curl immediately will look like a failure.
- **WAF off silently:** an empty `APPSEC_URL` is the default. If AppSec metrics never increment through nginx, this is the first thing to check.

## haproxy — `crowdsec-haproxy-spoa-bouncer`

WAF-capable, via **SPOA** (Stream Processing Offload Agent): haproxy forwards each request over SPOE to a sidecar daemon that consults LAPI decisions and (optionally) AppSec. Targets Ubuntu 26.04 / haproxy 3.2.9, engine v1.7.8.

### Install — self-registers

```bash
sudo apt-get install -y haproxy crowdsec-haproxy-spoa-bouncer
```

Like nginx, the package **self-registers its bouncer + LAPI key** (`cs-spoa-bouncer-<timestamp>`) into its config — do not run `cscli bouncers add`. It ships:
- `/etc/crowdsec/bouncers/crowdsec-spoa-bouncer.yaml` — bouncer settings (YAML).
- `/etc/haproxy/crowdsec.cfg` — the SPOE message/agent definition (use as-is).
- `/usr/share/doc/crowdsec-haproxy-spoa-bouncer/examples/` — example `haproxy.cfg`.
- systemd unit **`crowdsec-spoa-bouncer.service`** (note: name ≠ package name); SPOA listens on `0.0.0.0:9000` + a unix socket.

### Bouncer config — `/etc/crowdsec/bouncers/crowdsec-spoa-bouncer.yaml`

`api_url`/`api_key` are pre-filled. To enable the WAF, add:

```yaml
appsec_url: http://127.0.0.1:7422
appsec_timeout: 200ms
```

Then `sudo systemctl restart crowdsec-spoa-bouncer` and confirm `ss -lntp | grep 9000`.

### haproxy.cfg wiring

The shipped **example** `haproxy.cfg` uses Docker-compose hostnames (`server s1 whoami:2020`, `server s2 spoa:9000`) — **on bare-metal replace these with `127.0.0.1`**. A working frontend needs four things:

```
global
    lua-prepend-path /usr/lib/crowdsec-haproxy-spoa-bouncer/lua/?.lua
    lua-load /usr/lib/crowdsec-haproxy-spoa-bouncer/lua/crowdsec.lua
    setenv CROWDSEC_BAN_TEMPLATE_PATH /var/lib/crowdsec-haproxy-spoa-bouncer/html/ban.html
    setenv CROWDSEC_CAPTCHA_TEMPLATE_PATH /var/lib/crowdsec-haproxy-spoa-bouncer/html/captcha.html
    tune.bufsize 65536                       # 64KB — for WAF body inspection
    tune.lua.bool-sample-conversion normal   # SEE PITFALL — required on haproxy 3.1+

frontend http-in
    bind *:80
    option http-buffer-request
    filter spoe engine crowdsec config /etc/haproxy/crowdsec.cfg
    acl body_within_limit req.body_size -m int le 51200
    http-request send-spoe-group crowdsec crowdsec-http-body    if body_within_limit || !{ req.body_size -m found }
    http-request send-spoe-group crowdsec crowdsec-http-no-body if !body_within_limit { req.body_size -m found }
    http-request lua.crowdsec_handle if { var(txn.crowdsec.remediation) -m str "ban" }
    http-request lua.crowdsec_handle if { var(txn.crowdsec.remediation) -m str "captcha" }
    use_backend app

backend app
    server s1 127.0.0.1:8888                 # your real app

backend crowdsec-spoa                        # the SPOA sidecar — mode tcp
    mode tcp
    server s1 127.0.0.1:9000
```

`sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl restart haproxy`.

### Verify end-to-end (through haproxy :80)

```bash
curl -sS -o /dev/null -w 'normal:     %{http_code}\n' http://127.0.0.1/                                              # 200
curl -sS -o /dev/null -w 'waf block:  %{http_code}\n' 'http://127.0.0.1/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php'  # 403 (inband vpatch)
sudo cscli decisions add --ip 127.0.0.1 --duration 5m --reason test && sleep 12
curl -sS -o /dev/null -w 'banned:     %{http_code}\n' http://127.0.0.1/                                              # 403
sudo cscli decisions delete --ip 127.0.0.1
sudo cscli metrics show appsec    # vpatch-CVE-2017-9841 → Triggered/Blocked
```

### Pitfalls

- **haproxy 3.1+ lua warning:** without `tune.lua.bool-sample-conversion normal` in `global`, haproxy logs an ambiguity warning and defaults to legacy behavior. Set it explicitly, before any `lua-load`.
- **Example config hostnames:** the shipped example assumes Docker compose (`whoami:2020`, `spoa:9000`). Bare-metal must use `127.0.0.1`, or haproxy fails to resolve and the SPOE filter errors out (`set-on-error` → fail-open `allow`).
- **`crowdsec-spoa` backend must be `mode tcp`** — it carries the SPOE protocol, not HTTP. `option http-buffer-request` is correctly ignored there.
- **Inband vs out-of-band blocking:** only **inband** rules (e.g. `vpatch-*`) return 403 at request time. The health-check path `GET /crowdsec-test-...` triggers `crowdsecurity/appsec-generic-test`, which is **out-of-band** in `appsec-default` — it raises an alert/decision asynchronously and does **not** 403 inline. Use the CVE path above as the inline WAF test. (See [../../appsec/deploy.md](../../appsec/deploy.md).)

## apache — `crowdsec-apache2-bouncer`

**Ban/decision enforcement only — no AppSec/WAF** (unlike nginx and haproxy SPOA). Apache module `mod_crowdsec` queries LAPI per request (with a local cache) and returns a block code for IPs under an active decision. Targets Ubuntu 26.04 / apache 2.4.66, bouncer **v0.1**.

### Install — separate repo, watch the codename

The apache bouncer lives in its **own packagecloud repo** (`crowdsec/crowdsec-apache`), not the main `crowdsec/crowdsec` repo:

```bash
curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec-apache/script.deb.sh | sudo bash
sudo apt-get install -y crowdsec-apache2-bouncer
```

> **Codename gotcha:** the repo script pins your exact distro codename. `crowdsec/crowdsec-apache` only builds for **LTS** codenames — on a non-LTS or brand-new release (e.g. Ubuntu 26.04 `resolute`) `apt install` fails with `Unable to locate package`. Fix: edit `/etc/apt/sources.list.d/*crowdsec-apache*.list` and replace the codename with the most recent supported LTS (e.g. `noble`), then `apt-get update`.

The package auto-enables `mod_crowdsec` and pulls in `proxy`, `proxy_http`, `ssl`, `socache_shmcb`. The directives live in `/etc/crowdsec/bouncers/crowdsec-apache2-bouncer.conf`, which `/etc/apache2/mods-available/mod_crowdsec.conf` `Include`s.

### Set the API key manually (v0.1 packaging gap)

The package registers a bouncer on install **but leaves the config key as a literal placeholder** `CrowdsecAPIKey $API_KEY` — the real key is never written in, and the auto-registered bouncer is therefore keyless/orphaned. Mint your own and substitute it:

```bash
sudo cscli bouncers delete cs-apache2-bouncer-<timestamp>   # remove the keyless orphan (see cscli bouncers list)
KEY=$(sudo cscli bouncers add apache2 -o raw)
sudo sed -i "s|^CrowdsecAPIKey .*|CrowdsecAPIKey $KEY|" /etc/crowdsec/bouncers/crowdsec-apache2-bouncer.conf
sudo apache2ctl configtest && sudo systemctl restart apache2
sudo cscli bouncers list   # 'apache2' should now show a recent 'Last API pull'
```

### Config directives (apache-style, not YAML)

| Directive | Default | Notes |
|---|---|---|
| `CrowdsecURL` | `http://127.0.0.1:8080` | LAPI endpoint. |
| `CrowdsecAPIKey` | `$API_KEY` (placeholder!) | Must be set manually — see above. |
| `CrowdsecBlockedHTTPCode` | `403` | Code returned for banned IPs. (Canonical docs say 429; the shipped default is **403**.) |
| `CrowdsecFallback` | `allow` | Behavior when LAPI is unreachable — fail-open. |
| `CrowdsecCache` / `CrowdsecCacheTimeout` | `shmcb` / `60` | Per-IP verdict cache. **See pitfall.** |
| `Crowdsec` | `On` | Master switch. |

### Verify

```bash
curl -sS -o /dev/null -w 'normal: %{http_code}\n' http://127.0.0.1/        # 200
sudo cscli decisions add --ip 127.0.0.1 --duration 5m --reason test && sleep 8
sudo systemctl restart apache2                                             # flush the cache — SEE PITFALL
curl -sS -o /dev/null -w 'banned: %{http_code}\n' http://127.0.0.1/        # 403
sudo cscli decisions delete --ip 127.0.0.1
```

### Pitfalls

- **`CrowdsecCacheTimeout` masks fresh bans:** the bouncer caches each IP's verdict (default 60s). If an IP was seen *before* it was banned, it keeps getting `allow` until the cache entry expires. A ban-then-curl test within 60s looks like a failure — wait out the timeout or `systemctl restart apache2` to flush the `shmcb` cache. Lower `CrowdsecCacheTimeout` for faster enforcement at the cost of more LAPI lookups.
- **No WAF:** there is no AppSec path for the apache bouncer. To run the CrowdSec WAF in front of apache, terminate with nginx/haproxy SPOA (which forward to `:7422`) ahead of apache, or use a firewall bouncer for IP-level blocking.
- **Early version:** apache bouncer is v0.1 — expect rough edges like the unsubstituted key above.

## Traefik — `crowdsec-bouncer-traefik-plugin`

WAF-capable. The canonical Traefik integration is the community middleware plugin
**[`maxlerebourg/crowdsec-bouncer-traefik-plugin`](https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin)**
(loaded via Traefik's Yaegi engine — no separate binary). It checks LAPI decisions and,
optionally, forwards each request to the AppSec listener.

### Load the plugin (static config)

```yaml
# traefik.yml (static)
experimental:
  plugins:
    bouncer:
      moduleName: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
      version: v1.6.0
```

### Configure the middleware (dynamic config)

The bouncer needs a LAPI key. With the official CrowdSec container, set a fixed key via
`BOUNCER_KEY_traefik: <key>` in its env (auto-registers on start); on bare-metal LAPI mint
one with `cscli bouncers add traefik -o raw`.

```yaml
# dynamic config (file provider) — same key serves LAPI decisions AND AppSec
http:
  middlewares:
    crowdsec:
      plugin:
        bouncer:
          enabled: true
          crowdsecMode: stream                 # poll the full decision list (recommended)
          updateIntervalSeconds: 10            # stream poll cadence; a new ban lands within this
          crowdsecLapiKey: <bouncer-key>
          crowdsecLapiScheme: http
          crowdsecLapiHost: crowdsec:8080      # service:port on the Docker network
          crowdsecAppsecEnabled: true          # turn on inline WAF
          crowdsecAppsecHost: crowdsec:7422    # AppSec listener (must listen 0.0.0.0:7422)
          forwardedHeadersTrustedIPs:
            - "172.16.0.0/12"                  # the proxy/LB hop(s) in front, if any
  routers:
    whoami:
      rule: "PathPrefix(`/`)"
      service: whoami
      middlewares: [crowdsec]
```

| Key | Set to | Notes |
|---|---|---|
| `crowdsecMode` | `stream` | `live` = query LAPI per request; `stream` = poll list (lower latency, prod default); `appsec` = WAF only; `none`/`alone`. |
| `crowdsecLapiKey` | (bouncer key) | Serves both decisions and AppSec. |
| `crowdsecLapiHost` | `crowdsec:8080` | Host:port, no scheme (scheme is `crowdsecLapiScheme`). |
| `crowdsecAppsecEnabled` | `false` | **WAF is off by default.** `true` to forward requests to AppSec. |
| `crowdsecAppsecHost` | `crowdsec:7422` | AppSec must `listen_addr: 0.0.0.0:7422` so the Traefik container can reach it. |
| `forwardedHeadersTrustedIPs` | `[]` | Plugin-side trust for `X-Forwarded-For`. **Not sufficient alone — see real-IP pitfall.** |
| `clientTrustedIPs` | `[]` | IPs that **bypass the bouncer entirely**. Do **not** put your proxy/Docker range here or every request is allowed. |

### Real client IP — the #1 Traefik gotcha

Traefik **rewrites `X-Forwarded-For` to the immediate peer** unless the *entrypoint* trusts
that hop. Without it, the plugin only ever sees the proxy/Docker-gateway IP, so bans on the
real client never match. Set it on the entrypoint **in addition to** the plugin option:

```yaml
# traefik.yml (static)
entryPoints:
  web:
    address: ":80"
    forwardedHeaders:
      trustedIPs:
        - "172.16.0.0/12"      # the upstream proxy/LB (or Docker network) in front of Traefik
```

### Verify end-to-end (through Traefik, not directly to LAPI/:7422)

```bash
curl -sS -o /dev/null -w 'normal:       %{http_code}\n' http://127.0.0.1:8081/                                                      # 200
curl -sS -o /dev/null -w 'appsec block: %{http_code}\n' 'http://127.0.0.1:8081/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php'  # 403
# ban an IP, wait one stream interval, present it as the forwarded client:
docker exec crowdsec cscli decisions add --ip 198.51.100.123 --duration 5m --reason test
sleep 12                                                                                  # updateIntervalSeconds=10
curl -sS -o /dev/null -w 'banned XFF:   %{http_code}\n' -H 'X-Forwarded-For: 198.51.100.123' http://127.0.0.1:8081/  # 403
curl -sS -o /dev/null -w 'clean XFF:    %{http_code}\n' -H 'X-Forwarded-For: 203.0.113.5'   http://127.0.0.1:8081/  # 200
docker exec crowdsec cscli decisions delete --ip 198.51.100.123
docker exec crowdsec cscli metrics show appsec     # Processed/Blocked increment
```

### Pitfalls

- **Real IP rewritten:** if bans never match, you almost certainly skipped the *entrypoint*
  `forwardedHeaders.trustedIPs` above. The plugin's `forwardedHeadersTrustedIPs` is a second,
  separate layer — you usually need both.
- **`clientTrustedIPs` bypass:** anything in this list skips the bouncer. Putting your Docker
  range here makes every request return 200 (no AppSec, no ban). Use `forwardedHeadersTrustedIPs`
  for proxy trust, not this.
- **WAF off silently:** `crowdsecAppsecEnabled` defaults to `false`, and AppSec must listen on
  `0.0.0.0:7422` (not loopback) for a containerized Traefik to reach it.
- **`stream` lag:** a fresh ban lands within `updateIntervalSeconds`; immediate ban-then-curl
  looks like a failure. (See [../../debug/bouncer-not-blocking.md](../../debug/bouncer-not-blocking.md).)

## Caddy — `github.com/hslatman/caddy-crowdsec-bouncer`

WAF-capable Caddy module ([`hslatman/caddy-crowdsec-bouncer`](https://github.com/hslatman/caddy-crowdsec-bouncer)).
Caddy has no plugin loader, so the module must be **compiled in** — build a custom binary/image
with `xcaddy`.

### Build with the module

**Docker / Linux (Dockerfile):**

```dockerfile
FROM caddy:2.10-builder AS builder
RUN xcaddy build \
    --with github.com/hslatman/caddy-crowdsec-bouncer/http \
    --with github.com/hslatman/caddy-crowdsec-bouncer/appsec
FROM caddy:2.10
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

(`/http` enforces decisions; `/appsec` adds the WAF handler. Add `/layer4` only for L4
proxying.) Mint a bouncer key with `cscli bouncers add caddy -o raw`.

**FreeBSD/OPNsense** (no Go in base, no Docker):

```bash
# Download Go binary for freebsd-amd64
fetch https://go.dev/dl/go1.22.4.freebsd-amd64.tar.gz   # or latest
tar -C /usr/local -xzf go*.tar.gz
export PATH=$PATH:/usr/local/go/bin

sudo pkg install -y git   # xcaddy needs git for module resolution

GOPATH=$HOME/go go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
GOPATH=$HOME/go $HOME/go/bin/xcaddy build \
    --with github.com/hslatman/caddy-crowdsec-bouncer \
    --output /tmp/caddy-cs

sudo cp /tmp/caddy-cs /usr/local/bin/caddy-cs
```

### Caddyfile

```caddyfile
{
  crowdsec {
    api_url http://crowdsec:8080
    api_key <bouncer-key>
    appsec_url http://crowdsec:7422   # omit to run decisions-only (no WAF)
    ticker_interval 10s               # stream poll cadence
    #disable_streaming                # switch to live (per-request) lookups
    #enable_hard_fails                # fail-closed if LAPI is unreachable (default fails open)
  }
  servers {
    trusted_proxies static 172.16.0.0/12   # real-IP: trust the upstream hop
    client_ip_headers X-Forwarded-For
  }
}

:80 {
  route {
    appsec            # WAF inspection first
    crowdsec          # then LAPI decision enforcement
    reverse_proxy whoami:80
  }
}
```

### Config (JSON API — for OPNsense/FreeBSD or programmatic use)

The bouncer exposes two handlers and one top-level app:

```json
{
  "apps": {
    "crowdsec": {
      "api_url": "http://127.0.0.1:8080",
      "api_key": "<bouncer-key>",
      "appsec_url": "http://127.0.0.1:7422",
      "ticker_interval": "15s",
      "enable_streaming": true,
      "appsec_fail_open": false
    },
    "http": {
      "servers": {
        "demo": {
          "listen": [":8080"],
          "routes": [
            {
              "handle": [
                {"handler": "appsec"},
                {"handler": "crowdsec"},
                {
                  "handler": "reverse_proxy",
                  "upstreams": [{"dial": "127.0.0.1:8888"}]
                }
              ]
            }
          ]
        }
      }
    }
  }
}
```

| Handler | Function |
|---|---|
| `http.handlers.appsec` | Forwards each request to AppSec (port 7422) for WAF inspection — returns 403 on inband rule match |
| `http.handlers.crowdsec` | Checks the LAPI decision list for the client IP — returns 403 on active ban |

> **Both handlers are required.** `crowdsec` alone silently skips WAF inspection — `cscli metrics show appsec` will show 0 processed. Put `appsec` first in the route.

### Verify end-to-end

```bash
# AppSec block (CVE-2017-9841) → 403
curl -sS -o /dev/null -w 'appsec block: %{http_code}\n' \
    'http://<host-ip>:8080/vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php'

# LAPI ban block
cscli decisions add --ip <test-ip> --duration 2m --reason test
sleep 16   # wait for streaming ticker
curl -sS -o /dev/null -w 'banned: %{http_code}\n' http://<host-ip>:8080/

cscli metrics show appsec   # confirm processed/blocked counters
```

> **Do not test via `127.0.0.1:<bouncer-port>`** if LAPI is on `127.0.0.1:8080` and the bouncer frontend shares port `8080`. Loopback traffic routes to LAPI, not the bouncer. Use the host's internal/external IP instead.

### Pitfalls

- **`crowdsec-caddy-bouncer` / `crowdsecurity/caddy-cs-bouncer` do not exist** — these names return 404 on GitHub and pkg.go.dev. The correct module is `github.com/hslatman/caddy-crowdsec-bouncer`.
- **Module not compiled in:** the stock `caddy` image has no `crowdsec` directive — Caddy errors on the Caddyfile. You must `xcaddy build` (above) or use a prebuilt image that bundles the module.
- **xcaddy needs `git`** — the build fails with "git not found" on a minimal FreeBSD install. `sudo pkg install -y git` first.
- **Build to `/tmp`, then copy** — xcaddy may not have write access to `/usr/local/bin` directly; build to `/tmp/caddy-cs`, then `sudo cp`.
- **Real IP:** without `trusted_proxies` + `client_ip_headers`, Caddy treats the proxy/Docker hop as the client and bans never match. Set both in the global `servers` block.
- **Handler order:** put `appsec` before `crowdsec` in the route so WAF inspection runs ahead of decision enforcement.
- **WAF off:** omit `appsec_url` and the module enforces decisions only. AppSec must listen on `0.0.0.0:7422` for a containerized Caddy to reach it.
- **LAPI port conflict** — see [../../appsec/deploy.md](../../appsec/deploy.md) § OPNsense / FreeBSD: LAPI port conflict.

