# Configure — Acquisition (log sources)

Canonical docs: <https://docs.crowdsec.net/docs/next/getting_started/post_installation/acquisition> · datasources index <https://docs.crowdsec.net/docs/next/data_sources/intro>

## Overview

CrowdSec reads log lines through **acquisition** — a set of datasource definitions that tell the engine where to read, what format the lines are in, and which parser chain to apply.

- **`/etc/crowdsec/acquis.yaml`** — the legacy single-file location.
- **`/etc/crowdsec/acquis.d/*.yaml`** — drop-in directory; preferred. Each file can hold multiple YAML documents separated by `---`. Plugin-managed files (e.g. `os-crowdsec` on OPNsense) land here automatically.

The engine merges everything at startup. Both locations can coexist, but avoid defining the same log file in both — duplicate sources produce double-parsed lines and inflated metrics.

On **OPNsense / FreeBSD** the config root is `/usr/local/etc/crowdsec/` and the drop-in directory is `/usr/local/etc/crowdsec/acquis.d/`.

## File datasource

The most common type. Reads lines from one or more files. The engine tails each file; it also handles log rotation by re-opening by name.

```yaml
filenames:
  - /var/log/nginx/access.log
  - /var/log/nginx/error.log
labels:
  type: nginx
```

| Field | Notes |
|---|---|
| `filenames` | List of paths; globs are supported (`/var/log/nginx/*.log`). |
| `labels.type` | **Required.** The parser chain selector — must match a `filter` expression on an installed parser (e.g. `nginx`, `syslog`, `apache2`). Wrong or missing value → 0 parsed lines. |
| `force_inotify` | Set `true` to force inotify-based watching even on filesystems that don't advertise it (some NFS mounts, VMs with older kernels). |
| `poll_without_inotify` | Set `true` when the file is a **symlink** that rotates by relinking (e.g. OPNsense's `latest.log` pattern). inotify watches the inode, not the path — without polling the engine misses rotation events. |

### OPNsense log paths

OPNsense writes logs with the RFC 5424 syslog format. The path pattern is `/var/log/<facility>/latest.log` where `latest.log` is always a symlink to the newest rotation file.

| Log | Path | `labels.type` |
|---|---|---|
| SSH authentication | `/var/log/system/latest.log` | `syslog` |
| nginx access/error | `/var/log/nginx/access.log` | `nginx` |
| pf firewall | `/var/log/filter/latest.log` | `pf` |
| OPNsense GUI / API | `/var/log/audit/latest.log` | (configd audit — **not SSH auth**) |

> **Pitfall — SSH log path on OPNsense:** The `os-crowdsec` plugin ships `acquis.d/opnsense.yaml` which maps `/var/log/audit/latest.log` to the `sshd` collection. This file is the **configd** audit log (web admin actions), not SSH auth. Real SSH authentication events land in `/var/log/system/latest.log` (syslog format). Add a separate `acquis.d/ssh.yaml` pointing at the right path.

Because OPNsense's `latest.log` files are symlinks that rotate, always include both options:

```yaml
# acquis.d/ssh.yaml — SSH auth on OPNsense/FreeBSD
filenames:
  - /var/log/system/latest.log
labels:
  type: syslog
force_inotify: true
poll_without_inotify: true
```

## Journald datasource

For systemd-managed Linux hosts; avoids file permission issues and handles rotation transparently.

```yaml
source: journald
journalctl_filter:
  - "_SYSTEMD_UNIT=sshd.service"
labels:
  type: syslog
```

Not available on FreeBSD/OPNsense (no systemd).

## AppSec datasource

Tells the engine to spin up an inline WAF listener. This is **not a log reader** — it opens a TCP port that bouncers forward HTTP requests to. The CrowdSec agent evaluates them in-process and returns an allow/block verdict.

```yaml
# acquis.d/appsec.yaml
source: appsec
appsec_config: crowdsecurity/appsec-default
labels:
  type: appsec
listen_addr: 127.0.0.1:7422
```

| Field | Notes |
|---|---|
| `source: appsec` | **Required.** Identifies the datasource type. Without it the engine ignores the block. |
| `appsec_config` | Hub-installed config name. `crowdsecurity/appsec-default` is included by both canonical WAF collections and carries the health-check test rule. |
| `listen_addr` | `127.0.0.1:7422` for loopback (single-host bouncer); `0.0.0.0:7422` for cross-host bouncers. |
| `labels.type: appsec` | Used by out-of-band scenarios. Keep as `appsec`. |

The WAF collections must be installed before the engine will start with this config — see [../appsec/deploy.md](../appsec/deploy.md).

## Verify after editing

After changing any acquisition file, validate and confirm the source is being read:

```bash
# Validate all config files (parse errors → non-zero exit)
crowdsec -t

# Reload the engine (bare-metal/systemd)
sudo systemctl reload crowdsec

# Confirm the source is registered and counting lines
cscli metrics show acquisition

# Confirm a sample log line parses correctly
cscli explain --log '<paste a real line here>' --type nginx
```

On OPNsense/FreeBSD:

```bash
service crowdsec configtest
service crowdsec reload
cscli metrics show acquisition
```

## Common pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `0 parsed` for a source that exists | `labels.type` missing or wrong | Check installed parsers: `cscli parsers list`; match the type string |
| Engine fails to start: `no appsec-rules found` | AppSec acquisition added but WAF collections not installed | `cscli collections install crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules` |
| Engine reads file but events duplicate | Same file defined in both `acquis.yaml` and `acquis.d/` | Remove one; keep the drop-in |
| `permission denied` on log file | Engine runs as `crowdsec` user, log owned by root | Add `crowdsec` to the `adm` group, or grant `o+r` on the log |
| Symlinked `latest.log` stops updating after rotation | inotify watches the old inode | Add `poll_without_inotify: true` (and optionally `force_inotify: true`) |
| SSH not detected on OPNsense | Acquisition points at `/var/log/audit/latest.log` (configd, not auth) | Point at `/var/log/system/latest.log` with `labels.type: syslog` |
