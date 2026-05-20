# Bouncers — Web servers (nginx, Traefik, Caddy)

Canonical docs: <https://docs.crowdsec.net/u/bouncers/intro> (per-bouncer pages: nginx, traefik, caddy)

A web-server bouncer enforces two things at the edge:
1. **LAPI decisions** — IPs banned by scenarios/CTI get a 403 (or captcha).
2. **AppSec/WAF** (optional) — each request is forwarded to the AppSec listener for inline inspection before it reaches the backend.

Both are served by the **same bouncer API key**. Wiring the WAF is just pointing the bouncer's AppSec URL at the `:7422` listener — see [../../appsec/deploy.md](../../appsec/deploy.md).

## nginx — `crowdsec-nginx-bouncer`

Verified end-to-end on Ubuntu 24.04 / nginx 1.24 against engine v1.7.8.

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

## Traefik — `crowdsec-traefik-bouncer`

Middleware plugin (Yaegi) or the standalone bouncer container. AppSec is enabled with `crowdsec.appsec.enabled: true` + `crowdsec.appsec.url`; the AppSec-aware key goes in `crowdsec.crowdsecLapiKey`. *(Not yet verified end-to-end in this skill — follow the canonical Traefik bouncer page.)*

## Caddy — `caddy-crowdsec-bouncer`

Caddy module; set the equivalent `appsec_url` directive on the bouncer block, auth via the bouncer's API key. *(Not yet verified end-to-end in this skill.)*
