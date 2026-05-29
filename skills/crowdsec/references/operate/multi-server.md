---
verified:
  - date: 2026-05-26
    version: "1.7.8"
    env: systemd
    notes: "machines add -f -, machines prune (duration/force/<2min guard), prune semantics"
---

# Operate — Multi-server / distributed LAPI

Canonical docs: <https://docs.crowdsec.net/docs/next/local_api/intro>

## Decommissioning stale machines (log processors)

Every agent registers as a **machine** in `cscli machines list`. Ephemeral agents
— Kubernetes pods, autoscaled VMs, re-imaged hosts — leave behind dead entries
each time they roll. They're cosmetic (a dead machine can't push) but clutter the
list and the Console.

```bash
sudo cscli machines list                 # Last Heartbeat ⚠️ - / old = stale
sudo cscli machines prune                 # default: validated machines idle > 10m
sudo cscli machines prune --duration 1h   # widen the idle window
sudo cscli machines prune --not-validated-only   # only never-validated registrations
sudo cscli machines delete <name>         # remove one explicitly
```

Behavior confirmed on 1.7.8:

- **Prune is idle-time based**, compared against last heartbeat/update — default
  `--duration 10m`. A machine that was active seconds ago is **not** pruned even
  with `--force`; "No machines to prune." That's correct, not a bug.
- **`--force` skips the confirmation prompt but NOT the sub-2-minute safety guard.**
  `cscli machines prune --duration 1s --force` still prompts ("less than 2 minutes…
  Continue?") and, non-interactively, dies with `Error: ... EOF`. Use a duration
  ≥ 2m for unattended runs.
- **There is no built-in auto-prune scheduler.** Run `cscli machines prune` from
  cron/systemd-timer if you want it automatic. `unregister_on_exit`
  (<https://docs.crowdsec.net/docs/next/configuration/crowdsec_configuration/#unregister_on_exit>)
  only covers **graceful** shutdown — a killed/OOM'd pod or a hard node failure
  never unregisters, so prune is still needed.

> **Gotcha — `cscli machines add` clobbers local creds.** Plain
> `cscli machines add <name>` writes to `/etc/crowdsec/local_api_credentials.yaml`
> and refuses if it exists. To register an extra machine (e.g. a remote agent's
> key) without touching the local file, send the creds to stdout: `-f -`
> (`cscli machines add <name> -a -f -`).

Per-env: Docker `docker compose exec crowdsec cscli machines prune`; k8s
`kubectl exec -n <ns> <lapi-pod> -- cscli machines prune` — run against the
**LAPI** pod (the registry), and prefer a CronJob over per-replica logic.

## Sections to fill

> STUB. To cover:
> - Topologies: single LAPI + many agents; HA LAPI behind LB; per-cluster LAPI
> - Registering agents to a remote LAPI (`cscli lapi register`)
> - mTLS between agents and LAPI (cert generation, trust, rotation)
> - Postgres backend for LAPI (when sqlite stops scaling)
> - Bouncer placement: per-agent vs central
> - Cross-LAPI decision sync (Console / CAPI / blocklists API)
> - Pitfalls: clock skew, NAT, agent IDs colliding after image clone (regenerate `machine_id`)
