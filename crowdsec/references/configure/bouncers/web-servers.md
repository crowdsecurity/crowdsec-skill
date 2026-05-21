# Bouncers — Web servers (nginx, Traefik, Caddy)

Canonical docs: <https://docs.crowdsec.net/u/bouncers/intro> (per-bouncer pages: nginx, traefik, caddy)

A web-server bouncer enforces two things at the edge:
1. **LAPI decisions** — IPs banned by scenarios/CTI get a 403 (or captcha).
2. **AppSec/WAF** (optional) — each request is forwarded to the AppSec listener for inline inspection before it reaches the backend.

Both are served by the **same bouncer API key**. Wiring the WAF is just pointing the bouncer's AppSec URL at the `:7422` listener — see [../../appsec/deploy.md](../../appsec/deploy.md).

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

## Traefik — `crowdsec-traefik-bouncer`

Middleware plugin (Yaegi) or a standalone bouncer container. Per the canonical page, AppSec is wired via `crowdsec.appsec.enabled` + `crowdsec.appsec.url`, with the AppSec-aware key in `crowdsec.crowdsecLapiKey`. Follow the canonical [Traefik bouncer page](https://docs.crowdsec.net/u/bouncers/intro).

## Caddy — `caddy-crowdsec-bouncer`

Caddy module; per the canonical page, set the `appsec_url` directive on the bouncer block, auth via the bouncer's API key. Follow the canonical [Caddy bouncer page](https://docs.crowdsec.net/u/bouncers/intro).
