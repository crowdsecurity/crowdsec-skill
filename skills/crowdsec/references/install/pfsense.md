---
verified:
  - date: 2026-05-27
    version: "1.7.8"
    env: pfsense
    notes: "full Large install (LAPI + log processor + bouncer) on pfSense Plus 26.03 / FreeBSD 16.0-CURRENT amd64"
---

# Install — pfSense

Canonical docs: <https://docs.crowdsec.net/docs/getting_started/install_crowdsec_pfsense>

CrowdSec on pfSense is installed via a shell script (not via the pfSense Package Manager —
the package is not yet in the official repos). The pfSense plugin manages configuration and
service lifecycle. **Do not start or configure services manually** — the GUI save triggers
everything.

## Detect environment

```sh
uname -i        # → pfSense  (confirms pfSense, not generic FreeBSD)
uname -r        # → 15.0-CURRENT / 16.0-CURRENT (pfSense Plus 26.x) or 14.x (CE 2.8.x)
pkg info | grep -i crowdsec   # empty = not installed
```

## Three install modes

| Mode | Components | Use when |
|---|---|---|
| **Large** (default) | Remediation + Log Processor + Local API | Standalone, no other CrowdSec instance |
| **Medium** | Remediation + Log Processor | pfSense sends log data to a remote LAPI |
| **Small** | Remediation only | pfSense enforces blocklists from a remote LAPI |

## Install

SSH into the pfSense box (default shell: `/bin/tcsh` for root):

```sh
fetch https://raw.githubusercontent.com/crowdsecurity/pfSense-pkg-crowdsec/refs/heads/main/install-crowdsec.sh
sh install-crowdsec.sh
```

The script is interactive — it asks three confirmations. Answer **y** to each:
1. Banner prompt (the script IS the correct install path — answer y to continue).
2. Download confirmation (downloads the release `.tar` from GitHub).
3. Install confirmation.

To install a specific release:

```sh
sh install-crowdsec.sh --release v0.1.7-1.7.8-34
```

To uninstall:

```sh
sh install-crowdsec.sh --uninstall
```

## Activate (GUI — required after install)

After `sh install-crowdsec.sh` completes, **services are not yet running**. Open the pfSense
web UI and go to `Services` → `CrowdSec`. Verify that *Remediation Component*, *Log Processor*,
and *Local API* are enabled. Click **Save**.

This triggers the pfSense plugin to:
- Write the YAML config files (`/usr/local/etc/crowdsec/config.yaml`, bouncer config, LAPI credentials).
- Register the machine and bouncer with the local LAPI.
- Install the `crowdsecurity/pfsense` collection (hub update + upgrade).
- Start both services via `service crowdsec.sh restart` and `service crowdsec_firewall.sh restart`.

**Verify activation:**

```sh
service crowdsec status           # crowdsec is running as pid <n>
service crowdsec_firewall status  # crowdsec_firewall is running as pid <n>
cscli lapi status                 # You can successfully interact with Local API (LAPI)
cscli capi status                 # You can successfully interact with Central API (CAPI)
cscli bouncers list               # pfsense-firewall  127.0.0.1  ✔️
cscli machines list               # pfsense  127.0.0.1  ✔️
```

## Directory map (pfSense-specific paths)

| Path | What |
|---|---|
| `/usr/local/bin/crowdsec`, `/usr/local/bin/cscli` | Engine + CLI |
| `/usr/local/etc/crowdsec/config.yaml` | Master config |
| `/usr/local/etc/crowdsec/acquis.yaml` | Base acquisition (nginx, auth.log, httpd) |
| `/usr/local/etc/crowdsec/acquis.d/pfsense.yaml` | pfSense-specific acquisition (filter.log, nginx.log) |
| `/usr/local/etc/crowdsec/acquis.d/` | Drop new acquisition files here |
| `/usr/local/etc/crowdsec/{parsers,scenarios,collections,...}/` | Hub-managed symlinks |
| `/usr/local/etc/rc.conf.d/crowdsec` | Service flags (`crowdsec_machine_name`) |
| `/usr/local/etc/rc.conf.d/crowdsec_firewall` | Service flags (`crowdsec_firewall_name`) |
| `/var/db/crowdsec/data/` | SQLite DB, GeoIP tables — **must be on persistent disk** |
| `/var/log/crowdsec/crowdsec.log` | Engine log (also visible in pfSense UI) |
| `/var/log/crowdsec/crowdsec_api.log` | LAPI log |
| `/var/log/crowdsec/crowdsec-firewall-bouncer.log` | Bouncer log |

## Service management

```sh
service crowdsec start|stop|restart|status
service crowdsec_firewall start|stop|restart|status
```

The `.sh` suffix form (`service crowdsec.sh`) also works for `start/stop/restart` but **does
not support `status`**. Always use the form without `.sh` to check running state.

pfSense GUI equivalent: `Status` → `Services`.

## Acquisition notes

`acquis.d/pfsense.yaml` is created by the package. It reads `/var/log/filter.log` and
`/var/log/nginx.log` with `labels.type: syslog`, plus two important options:

```yaml
poll_without_inotify: true   # required when log sources are symlinks
force_inotify: true          # watches for directory/file creation (critical if /var is in RAM)
```

`cscli metrics show acquisition` will show high "unparsed" rate for `/var/log/filter.log`.
**This is normal**: CrowdSec only parses pf entries that match its scenarios (port scans, etc.).
The majority of firewall log entries are intentionally not processed.

To add new log sources, create files in `/usr/local/etc/crowdsec/acquis.d/` and reload:

```sh
service crowdsec reload
```

## Default collections installed (Large mode)

After GUI save, `cscli hub list` shows (among others):

- `crowdsecurity/pfsense` — pfSense core collection (pf-logs, pfsense-gui, sshd, freebsd)
- `crowdsecurity/pfsense-gui` — pfSense admin UI brute-force detection
- `firewallservices/pf` — pf port-scan detection
- `crowdsecurity/sshd` — SSH brute-force
- `crowdsecurity/nginx` — nginx log parsing (for pfSense's nginx reverse proxy)
- `crowdsecurity/base-http-scenarios`, `crowdsecurity/http-cve` — HTTP attack patterns
- `crowdsecurity/whitelist-good-actors` — CDN, search engine whitelists

## UI page map

| Quickstart reference | Actual pfSense menu path |
|---|---|
| `Services/CrowdSec` | `Services` → `CrowdSec` (config / Save) |
| `Status/CrowdSec` | `Status` → `CrowdSec Status` (read-only status, decision revocation) |
| `Diagnostics/CrowdSec Metrics` | `Diagnostics` → `CrowdSec Metrics` |
| `Status/System Logs/Packages/crowdsec` | `Status` → `System Logs` → `Packages` → `crowdsec` |
| `Status/Services` | `Status` → `Services` (service start/stop/restart) |
| `Diagnostics/Tables` | `Diagnostics` → `Tables` (view pfctl blacklist tables) |
| `Diagnostics/Command Prompt` | `Diagnostics` → `Command Prompt` |

## Known gotchas

**Services don't auto-start after `sh install-crowdsec.sh`**: you must open the GUI and click
Save. There is no documented CLI shortcut; the activation is done via the PHP resync hook.

**RAM disk**: if `System` → `Advanced` → `Misc` → `Use RAM disks` is enabled, Local API
cannot be used (the database in `/var/db` would be lost on reboot). Disable RAM disk or use
a remote LAPI (Medium/Small setup).

**Confusing post-install messages**: the `crowdsec` and `crowdsec-firewall-bouncer` packages
print standard FreeBSD install instructions (service enable/start, pf.conf changes) during
installation. These can be ignored — the pfSense plugin handles all of this.

**`service crowdsec.sh status` shows usage message**: only `start/stop/restart` are supported
in the `.sh` form. Use `service crowdsec status` to check running state.

**Private IP whitelist**: since CrowdSec 1.6.3, `crowdsecurity/whitelists` is installed by
default and prevents local bans on private IP ranges. To remove:
```sh
cscli parsers remove crowdsecurity/whitelists
```

## Health check

```sh
cscli version                  # v1.7.x-...
cscli lapi status              # LAPI reachable
cscli capi status              # CAPI connected, sharing enabled
cscli bouncers list            # pfsense-firewall ✔️, last pull recent
cscli machines list            # pfsense ✔️, recent heartbeat
cscli metrics show acquisition # filter.log + auth.log being read
cscli decisions list           # active bans (empty is normal on fresh install)
pfctl -T show -t crowdsec_blacklists   # IPv4 blocked IPs
```

## Quick uninstall (clean)

```sh
pkg remove pfSense-pkg-crowdsec crowdsec crowdsec-firewall-bouncer
rm -rf /usr/local/etc/crowdsec /usr/local/etc/rc.conf.d/crowdsec*
rm -rf /var/db/crowdsec /var/log/crowdsec* /var/run/crowdsec*
# optionally: remove <crowdsec> section from /conf/config.xml
```
