# Install — bare metal (apt/dnf + systemd)

Canonical docs: <https://docs.crowdsec.net/docs/next/getting_started/installation/linux> · post-install <https://docs.crowdsec.net/docs/next/getting_started/post_installation/acquisition>

This is the operational layer over the canonical install. Follow the doc for the
exact repo line for your distro; the notes below are what the doc doesn't tell
you, for a 1.7.x Debian/Ubuntu box.

## 1 — Add the repository and install

The canonical path is the packagecloud one-liner, which drops a signed apt/dnf
repo and installs the engine:

```bash
curl -s https://install.crowdsec.net | sudo sh        # adds the repo
sudo apt install crowdsec                              # or: sudo dnf install crowdsec
```

What this lays down:

- Repo: `/etc/apt/sources.list.d/crowdsec_crowdsec.list` pointing at
  `packagecloud.io/crowdsec/crowdsec`, key in
  `/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg`.
- One package, `crowdsec` (the engine **and** `cscli` — bouncers are separate
  packages installed later).
- systemd unit `crowdsec.service`, `Type=notify`, `Restart=always`,
  `RestartSec=60`. Note the `ExecStartPre … -t` config-test: a bad config makes
  the service fail *before* start, and `systemctl reload` also runs `-t` first —
  a broken acquisition file blocks the reload (you keep the old config running).

The installer auto-runs `cscli setup`, which **detects running services and log
files** and generates per-service acquisition under `/etc/crowdsec/acquis.d/`
(e.g. `setup.linux.yaml`, `setup.sshd.yaml`, `setup.nginx.yaml`). It also
installs matching hub collections and enrolls CAPI (community blocklist).
There is normally **no** `/etc/crowdsec/acquis.yaml` on a fresh 1.7.x install —
that static file is the pre-1.7 layout. Don't add one expecting it to be read
*instead of* `acquis.d/`; both are read, and duplicating a source double-counts
events.

## 2 — Directory map

| Path | What |
|---|---|
| `/usr/bin/crowdsec`, `/usr/bin/cscli` | engine + CLI |
| `/etc/crowdsec/config.yaml` | master config (paths, LAPI, DB, logging) |
| `/etc/crowdsec/acquis.d/*.yaml` | acquisition (one file per source; `cscli setup` writes `setup.*.yaml`) |
| `/etc/crowdsec/{parsers,scenarios,collections,postoverflows,contexts,appsec-configs,appsec-rules}/` | hub-managed symlinks — **do not hand-edit**, use `cscli` + `_custom/` |
| `/etc/crowdsec/hub/` | downloaded hub index + item bodies |
| `/etc/crowdsec/profiles.yaml` | decision profiles (ban duration, captcha) |
| `/etc/crowdsec/simulation.yaml` | scenarios running in simulation (alert, no decision) |
| `/etc/crowdsec/{local,online}_api_credentials.yaml` | LAPI machine creds / CAPI creds |
| `/etc/crowdsec/notifications/` | notification plugin configs |
| `/var/lib/crowdsec/data/` | sqlite `crowdsec.db` (+ `-wal`/`-shm`), GeoLite mmdb, blocklist data |
| `/var/log/crowdsec.log` | agent log |
| `/var/log/crowdsec_api.log` | LAPI log |

Default LAPI listen: `127.0.0.1:8080` (`local_api_credentials.yaml` shows the
`url`/`login`/`password` the agent uses against its own LAPI).

## 3 — Verify the service came up

```bash
systemctl status crowdsec --no-pager
sudo cscli lapi status        # agent can reach LAPI
sudo cscli capi status        # engine is enrolled with CAPI (community blocklist)
sudo cscli metrics            # acquisition rows show lines being read+parsed
sudo cscli hub list           # collections installed by cscli setup
```

If `cscli metrics` shows acquisition sources but **0 parsed**, the source is
matched but the parser collection for it isn't installed — see
[../debug/parsing.md](../debug/parsing.md). If the service won't start, the
single most common cause is a malformed file in `acquis.d/` (the `-t` pre-check
prints the offending file + line to the journal) — see
[../debug/common-errors.md](../debug/common-errors.md).

## 4 — Common post-install pitfalls

- **SELinux / AppArmor** (RHEL-family, some Ubuntu hardening): the engine can't
  read `/var/log/*` it isn't labelled for. Symptom: `cscli metrics` shows the
  source but no lines read. Check `ausearch -m avc -ts recent` /
  `dmesg | grep DENIED`; relabel or add a policy rather than disabling
  enforcement.
- **journald**: if you switch a source to `journalctl`, the `crowdsec` user must
  be in a group that can read the journal (`systemd-journal`) — file-based
  sources don't have this requirement.
- **Logrotate races**: file sources follow inode; a `copytruncate` rotation can
  drop the tail. CrowdSec handles standard `create` rotation fine — only an
  issue with non-standard logrotate configs.
- **Re-running `cscli setup`** appends; it does not dedupe against a hand-written
  `acquis.yaml`. If you wrote your own acquisition, audit `acquis.d/` for the
  same path appearing twice (double-counted events → premature bans).
- **Observe-only first**: to watch without banning while you tune, keep
  scenarios in `simulation.yaml` (alerts fire, no decisions) before wiring a
  remediation bouncer — see [../configure/profiles.md](../configure/profiles.md).

## 5 — Uninstall (clean teardown)

```bash
sudo apt purge -y crowdsec 'crowdsec-*-bouncer'
sudo rm -rf /etc/crowdsec /var/lib/crowdsec /var/log/crowdsec*.log
# if the firewall bouncer was installed, also flush the rules/ipsets it added
# (see ../configure/bouncers/firewall.md — confirm before touching firewall state)
```

## Next steps

- **Verify detection actually works:** run the HTTP/SSH probes in
  [../operate/health-check.md](../operate/health-check.md) — don't assume
  "service is up" means "detection is wired".
- **Block, don't just observe:** install a remediation bouncer —
  [../configure/bouncers/firewall.md](../configure/bouncers/firewall.md) for
  host firewall, [../configure/bouncers/web-servers.md](../configure/bouncers/web-servers.md)
  for nginx/traefik/caddy.
- **Enroll in the Console** (optional, central view + managed blocklists):
  [console.md](./console.md).
