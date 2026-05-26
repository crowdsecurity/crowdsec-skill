---
verified:
  - date: 2026-05-26
    version: "1.7.8"
    env: systemd
    notes: "apt-cache policy (no-op at latest, packagecloud repo, rollback table), hub upgrade, backup paths; outdated/distro-source facts confirmed (official origin packagecloud.io/crowdsec/crowdsec, Ubuntu 26.04 universe trap = 1.4.6); migrate-in-place recipe not run end-to-end"
---

# Operate — Upgrades, backup, rollback

Canonical docs: <https://docs.crowdsec.net/docs/next/configuration/crowdsec_configuration> · `cscli` reference <https://docs.crowdsec.net/docs/next/cscli/>

Upgrading the engine and bouncers is **a no-brainer for most setups**: releases are
backward-compatible, the database migrates forward automatically on first start, and engine
↔ bouncer version skew is fine. The one part that needs attention is **locally modified
(tainted) hub items** — see below.

## Upgrade the engine — the happy path

| Env | Upgrade |
|---|---|
| **bare-metal** | `sudo apt upgrade crowdsec` (or `sudo dnf upgrade crowdsec`) → `sudo systemctl restart crowdsec` |
| **Docker** | Pull the new tag, recreate with the **same named volumes** (the DB migrates on first start): `docker compose pull && docker compose up -d` |
| **Kubernetes** | `helm repo update` → `helm upgrade crowdsec crowdsec/crowdsec --reset-then-reuse-values` |

`--reset-then-reuse-values` is mandatory on helm — omitting it silently drops your values
(see [../install/kubernetes.md](../install/kubernetes.md)).

Verify:

```bash
sudo cscli version                 # the engine version bumped
sudo cscli lapi status             # LAPI still reachable
# then a quick smoke test — see ../operate/health-check.md
```

The DB migrating forward is automatic and transparent: an engine upgraded across a minor
version (e.g. v1.6 → v1.7) on the same data volume keeps all existing decisions and machines.

## Detect & fix an outdated / distro-packaged install (Linux)

If the engine is **years behind**, the fix isn't `apt upgrade` — that only moves within whatever
repo the package came from. Detect it with the version + install-source check in `SKILL.md`
Step 1.5. If it was installed from the wrong source, add the official repo and upgrade in place —
`apt install` (no `--purge`) keeps `/etc/crowdsec` and the DB:

```bash
curl -s https://install.crowdsec.net | sudo sh        # adds the signed official repo
sudo apt install crowdsec                             # or: sudo dnf install crowdsec — pulls latest
sudo systemctl restart crowdsec
```

Repo and post-install details: [../install/bare-metal.md](../install/bare-metal.md) §1.

## Bouncers upgrade on their own cadence

Each bouncer is its **own package**, versioned independently of the engine — they're LAPI
clients and need no lockstep:

```bash
sudo apt upgrade crowdsec-firewall-bouncer-nftables   # or crowdsec-nginx-bouncer, etc.
sudo systemctl restart crowdsec-firewall-bouncer
```

It's normal to see, say, engine `v1.7.8` alongside firewall-bouncer `0.0.34`. Upgrade
bouncers when their changelog warrants it, not because the engine moved.

## Hub items — the part that needs care

Hub content (parsers, scenarios, collections, AppSec rules) upgrades **separately** from the
engine binary:

```bash
sudo cscli hub update      # refresh the catalog index
sudo cscli hub upgrade     # pull newer versions of installed items
sudo systemctl reload crowdsec
```

**`cscli hub upgrade` skips any item you've locally modified (tainted).** Your edits are
preserved — but that item then **stops receiving new versions and security fixes**, silently:

```
level=warning msg="scenarios:crowdsecurity/http-wordpress_wpconfig is tainted, use '--force' to overwrite"
```

To get the update, reconcile the item: move your change into a `_custom/` override (which
survives upgrades) and `--force` the item back to pristine. The full detect → diff → fix flow
is in [../configure/hub.md](../configure/hub.md) § Tainted items. After any upgrade, scan for
items left behind:

```bash
sudo cscli hub list | grep -i tainted
```

## Backup — only when it actually matters

Because upgrades are backward-compatible, a **routine minor bump does not need a backup
ritual**. Take a snapshot deliberately before the genuinely risky changes:

- a **major-version** jump,
- changing the **DB backend** (sqlite → postgres/mysql) or running a backend migration,
- before a large hand-edit to config you're unsure about.

What to copy (bare-metal paths):

```bash
sudo systemctl stop crowdsec
sudo cp -a /etc/crowdsec /etc/crowdsec.bak                       # config, hub symlinks, _custom/ overrides
sudo cp -a /var/lib/crowdsec/data /var/lib/crowdsec/data.bak     # sqlite crowdsec.db + geoip/datafiles
sudo systemctl start crowdsec
```

A postgres/mysql backend lives in that database, not the data dir — dump it with the DB's own
tools (`pg_dump` / `mysqldump`). In Docker the equivalents are the `cs-config` and `cs-data`
named volumes; in Kubernetes it's the LAPI PVC (or the external DB).

## Rollback (rare)

Reinstall the prior version and restart:

```bash
sudo apt install crowdsec=<old-version>     # e.g. crowdsec=1.7.7; see 'apt-cache policy crowdsec'
sudo systemctl restart crowdsec
```

In Docker, repoint the image tag and `docker compose up -d`. A minor-version rollback against
a forward-migrated sqlite DB generally works (a v1.6 ↔ v1.7 round-trip on the same volume
keeps decisions intact). For a **major** jump, don't rely on that — restore the pre-upgrade DB
snapshot you took above rather than just downgrading the package.

## Pitfalls

- **Tainted items silently miss fixes.** `hub upgrade` leaves them on the old version with no
  error beyond one warning line. Audit with `cscli hub list | grep tainted` after upgrading;
  reconcile via [../configure/hub.md](../configure/hub.md) § Tainted items.
- **helm `--reset-then-reuse-values`.** Skipping it drops your chart values.
- **Read the release notes on minor bumps.** Backward-compatible ≠ zero behavior changes;
  scan the changelog for defaults that moved.
- **Reload vs restart.** Config/acquisition/hub changes need `reload`; a new engine binary
  needs `restart` (or container/pod recreate).

## Per-environment notes

| Env | Apply |
|---|---|
| **systemd / bare-metal** | `apt`/`dnf` upgrade → `systemctl restart crowdsec`. Repo at `packagecloud.io/crowdsec/crowdsec`. |
| **Docker / compose** | `docker compose pull && docker compose up -d` — keep the same named volumes so the DB persists and migrates. Pin a minor tag (`:v1.7`) in prod rather than `:latest`. |
| **Kubernetes / Helm** | `helm repo update` → `helm upgrade … --reset-then-reuse-values`. Engine version follows the chart's app version. |
