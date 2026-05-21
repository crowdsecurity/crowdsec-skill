# Configure — Acquisition (log sources)

Canonical docs: <https://docs.crowdsec.net/docs/next/getting_started/post_installation/acquisition> · datasources index <https://docs.crowdsec.net/docs/next/data_sources/intro>

Acquisition tells the engine **what logs to read and how to label them**. Each source
declares a `source:` (the datasource type) and a `labels.type:` (the parser hint). If the
engine reads lines but they show up as **`Lines unparsed`**, acquisition is usually fine
and the problem is the `type:` or the parser — debug that with
[../debug/parsing.md](../debug/parsing.md). If a source shows **0 `Lines read`**, the
problem is here.

## Where acquisition lives

| | Path / mechanism |
|---|---|
| Single legacy file | `/etc/crowdsec/acquis.yaml` (`acquisition_path` in `config.yaml`) |
| Drop-in dir (preferred) | `/etc/crowdsec/acquis.d/*.yaml` (`acquisition_dir` in `config.yaml`) — one file per source set |
| OPNsense / FreeBSD | `/usr/local/etc/crowdsec/acquis.d/` — same drop-in model; `os-crowdsec` plugin drops files here automatically |
| Docker | Bind-mount or env (`COLLECTIONS`, plus a mounted `acquis.d`); see Per-environment notes |
| Kubernetes | The chart's `config.acquisition` values render into the same `acquis.d` files |

Both `acquisition_path` and `acquisition_dir` load if set — check `config.yaml`:

```bash
sudo grep -E 'acquisition_(path|dir)' /etc/crowdsec/config.yaml
# acquisition_path: /etc/crowdsec/acquis.yaml
# acquisition_dir: /etc/crowdsec/acquis.d
```

Each YAML doc is **one source**. Multiple sources per file are allowed if separated by
`---`. Put unrelated sources in their own files under `acquis.d/`.

## The label model — every source needs `labels.type`

`labels.type` is the parser router. A source with no `type` (or the wrong one) is read but
never parsed — every line lands in `Lines unparsed`. Set it to the family the lines belong
to: `syslog`, `nginx`, `haproxy`, `appsec`, etc. (the value the relevant parser matches on).

## File datasource

```yaml
source: file
filenames:
  - /var/log/nginx/*.log        # globs allowed
  - /var/log/auth.log           # list as many paths as you need
labels:
  type: nginx
```

Glob expansion is evaluated at startup; files created later that match are **not** picked
up until reload. For high-rotation logs prefer the directory plus a glob over naming each
file.

| Field | Notes |
|---|---|
| `filenames` | List of paths; globs are supported. |
| `labels.type` | **Required.** The parser chain selector. |
| `force_inotify` | Set `true` to force inotify-based watching on filesystems that don't advertise it (some NFS mounts, older kernels). |
| `poll_without_inotify` | Set `true` when the file is a **symlink** that rotates by relinking (e.g. OPNsense's `latest.log` pattern). inotify watches the inode, not the path — without polling the engine misses rotation events. |

### OPNsense log paths

OPNsense writes logs in RFC 5424 syslog format. The path pattern is `/var/log/<facility>/latest.log` where `latest.log` is always a symlink to the newest rotation file.

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

## journald datasource

```yaml
source: journalctl
journalctl_filter:
  - "_SYSTEMD_UNIT=ssh.service"   # journalctl-style match; one filter per list entry
labels:
  type: syslog
```

The filter strings are passed straight to `journalctl`. After reload the source appears in
metrics as `journalctl:journalctl-_SYSTEMD_UNIT=ssh.service`. A typo in the unit name is
silent — the source reads **0 lines** rather than erroring.

Not available on FreeBSD/OPNsense (no systemd).

## docker datasource

For a CrowdSec **container** reading other containers' stdout/stderr via the Docker socket:

```yaml
source: docker
container_name:
  - acq-nginx            # exact names; container_name_regexp / labels also supported
labels:
  type: nginx
```

Requires `/var/run/docker.sock` mounted into the CrowdSec container. The source shows up as
`docker:<container-name>`. Use this instead of a file source when apps log to stdout (the
12-factor norm in Docker/compose) — there is no log file to bind-mount.

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

## When to pick which source

| Logs come from… | `source:` |
|---|---|
| A file or files on disk | `file` |
| systemd journal (no file written, e.g. modern sshd) | `journalctl` |
| Other containers' stdout (CrowdSec runs in Docker) | `docker` |
| A remote host shipping over syslog | `syslog` (listener) |
| Kubernetes audit webhook | `k8s_audit` |
| AWS Kinesis / CloudWatch | `kinesis` / `cloudwatch` |
| The WAF listener (not a log — request inspection) | `appsec` (see [../appsec/deploy.md](../appsec/deploy.md)) |

## Verify after editing

```bash
# 1. Validate config — silent + exit 0 means OK. A bad source prints FATAL.
sudo crowdsec -t
#   e.g. FATAL crowdsec init: while loading acquisition config:
#        /etc/crowdsec/acquis.d/foo.yaml: unknown data source nonexistent_ds

# 2. Apply (reload picks up acquisition changes without dropping the API)
sudo systemctl reload crowdsec

# 3. Confirm the source is actually read — find your source, check 'Lines read' climbs
sudo cscli metrics show acquisition
#   | file:/var/log/nginx/access.log | 19 | 19 | -   ...
#   | journalctl:journalctl-_SYSTEMD_UNIT=ssh.service | 2 | 2 | - ...
#   | docker:acq-nginx | 5 | 5 | - ...

# 4. Confirm a representative line parses with the chosen type
sudo cscli explain --log 'May 21 09:00:00 host sshd[123]: Failed password for invalid user admin from 1.2.3.4 port 22 ssh2' --type syslog
#   s01-parse → 🟢 crowdsecurity/sshd-logs ... parser success 🟢
sudo cscli explain --file /var/log/nginx/access.log --type nginx   # replay a whole file
```

On OPNsense/FreeBSD:

```bash
service crowdsec configtest
service crowdsec reload
cscli metrics show acquisition
```

## Pitfalls

- **Missing/wrong `labels.type`:** lines read but all `unparsed`. The single most common
  acquisition mistake. Match `type` to the parser family.
- **Permission denied on log files:** on bare-metal the engine runs as root and reads most
  logs, but tightly-permissioned files (e.g. some `/var/log` set to `0640 root:adm`) can
  still block it under a non-root setup — check ownership/ACLs if a file source reads 0.
- **journald unit typo:** wrong `_SYSTEMD_UNIT` → 0 lines, no error. Verify with
  `journalctl _SYSTEMD_UNIT=ssh.service` first.
- **Docker bind-mount path mismatch:** for a *file* source inside a CrowdSec container, the
  `filenames:` must be the **container** path, not the host path. Mismatch → 0 lines. (Use
  the `docker` source to avoid the problem entirely.)
- **Globs are startup-only:** new files matching a glob need a reload to be acquired.
- **Edited but not applied:** `crowdsec -t` validates the file but does not load it — you
  still need `systemctl reload crowdsec` (or recreate the container / `helm upgrade`).
- **Symlinked `latest.log` stops updating after rotation:** inotify watches the old inode — add `poll_without_inotify: true` (and optionally `force_inotify: true`).
- **SSH not detected on OPNsense:** acquisition points at `/var/log/audit/latest.log` (configd, not auth) — point at `/var/log/system/latest.log` with `labels.type: syslog`.
- **AppSec source fails to start:** WAF collections not installed — `cscli collections install crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules`.

## Per-environment notes

| Env | What changes |
|---|---|
| **systemd / bare-metal** | Recipes above as-is. Edit `acquis.d/*.yaml`, `crowdsec -t`, `systemctl reload crowdsec`. |
| **OPNsense / FreeBSD** | Config root is `/usr/local/etc/crowdsec/`; drop-in dir is `/usr/local/etc/crowdsec/acquis.d/`. Use `file` source with `poll_without_inotify: true` for symlinked `latest.log` files. No journald. Reload with `service crowdsec reload`. |
| **Docker / compose** | Mount `./acquis.d:/etc/crowdsec/acquis.d` (and `/var/run/docker.sock` for the docker source). `COLLECTIONS=`/`PARSERS=` env install hub items at start. Run cscli with `docker exec <name> cscli metrics show acquisition`. Recreate the container to apply (a reload signal also works). |
| **Kubernetes / Helm** | Define sources under `config.acquisition` in values; `helm upgrade --reset-then-reuse-values`. Inspect with `kubectl exec -n <ns> <agent-pod> -- cscli metrics show acquisition`. The `k8s_audit` source needs the API server's audit webhook pointed at the agent. |

