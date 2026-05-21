# Debug — Common errors (string → cause catalog)

Canonical docs: <https://docs.crowdsec.net/docs/next/troubleshooting/intro>

Commands below are written for **bare-metal** (`sudo cscli …`). In docker,
prefix with `docker exec <name>`; in k8s, `kubectl exec -n <ns> <pod> --`.

Use this when you have a specific error string. For general "something's
broken, where do I start" diagnosis, go to [triage.md](./triage.md) first.

Match the error string the engine/bouncer printed to the row below.

> **Catch config errors before they take the service down.** `crowdsec.service`
> runs `crowdsec -t` as `ExecStartPre` *and* on `systemctl reload`. Run it
> yourself first — it prints the offending file + line without touching the
> running engine:
> ```bash
> sudo crowdsec -c /etc/crowdsec/config.yaml -t
> ```

## Acquisition / config

| Error string | Cause | Fix |
|---|---|---|
| `datasource of type appsec: … cannot parse appsec configuration: [2:3] cannot unmarshal []interface {} into Go struct field Configuration.AppsecConfig of type string` | `appsec_config:` (singular) given a **list** | Use the **plural** key `appsec_configs:` for a list; singular takes one string. See [../appsec/configure.md](../appsec/configure.md). |
| `unable to initialize inband engine : invalid WAF config from string: failed to compile the directive "secrule": duplicated rule id 100` | Two appsec-configs on one listener pull the **same** underlying rule (e.g. both include `base-config`/`vpatch-*`) | Use non-overlapping configs, or just `crowdsecurity/appsec-default` alone. See [../appsec/configure.md](../appsec/configure.md). |
| `no appsec-rules found for pattern <name>` | A bare appsec-config was installed without its rules; engine expands globs at load, `cscli` does not | Install via the **collection** (`cscli collections install crowdsecurity/appsec-virtual-patching`), which pulls the rule graph. See [../appsec/deploy.md](../appsec/deploy.md). |
| `no such datasource` / source type unknown | `source:`/`labels.type:` typo or a datasource the build doesn't support | Fix the key in the `acquis.d/*.yaml`; `crowdsec -t` points at the file:line. |
| Source reads lines but **0 parsed** | `type:` label doesn't match any installed parser | [parsing.md](./parsing.md). |

## Permissions / OS

| Symptom | Cause | Fix |
|---|---|---|
| `permission denied` opening a log file; or source present but 0 lines read | `crowdsec` user can't read the file | `sudo -u crowdsec head <path>`; fix ownership/ACL. If that user *can* read it but the engine still can't, it's **SELinux/AppArmor** — `ausearch -m avc -ts recent` / `dmesg | grep DENIED`, then relabel/add policy (don't disable enforcement). |
| apt install of a bouncer hangs: `Failed to open terminal … debconf: whiptail output the above errors, giving up!` | A debconf dialog (e.g. pending-kernel notice) on a non-interactive shell | Re-run with `sudo DEBIAN_FRONTEND=noninteractive apt install -y …`. |

## LAPI / CAPI / auth

| Error | Cause | Fix |
|---|---|---|
| Agent: `unable to authenticate … machine not validated` | Agent machine not registered/validated with LAPI | `cscli machines list`; validate with `cscli machines validate <name>` (or re-`cscli machines add` on the agent). |
| Bouncer log: **HTTP 401** on decision pull | Bouncer key ≠ LAPI key (rotated, stale config, re-added) | `cscli bouncers list`; re-issue and paste the key into the bouncer config. [bouncer-not-blocking.md](./bouncer-not-blocking.md) §3. |
| `cscli capi status` fails / CAPI register errors | Missing `online_api_credentials.yaml`, **clock skew**, or egress blocked to `api.crowdsec.net` | `cscli capi register` then reload; check `timedatectl` (TLS fails on skew); allow egress / set proxy. |

## Database

| Error | Cause | Fix |
|---|---|---|
| `database is locked` (sqlite) | Concurrent writers / slow disk; sqlite single-writer | Reduce write pressure; move `crowdsec.db` to faster storage; for multi-agent or high volume switch the backend to PostgreSQL — see [../operate/multi-server.md](../operate/multi-server.md). |
| sqlite errors + `df` shows full `/var/lib/crowdsec` | Disk full → silent alert-write failure | Free space / rotate; alerts resume. |

## Hub

| Symptom | Cause | Fix |
|---|---|---|
| `cscli hub list` shows an item **`tainted`** | A hub-managed file under `/etc/crowdsec/{parsers,scenarios,…}/` was hand-edited | Revert: `cscli <type> remove <item> && cscli <type> install <item>`; put custom changes in the matching `_custom/` dir instead. |
| `could not retrieve geoip database` at first boot | DNS/egress not up when the engine first fetched GeoLite | Ensure egress, then `cscli hub update`; the mmdb lands in `/var/lib/crowdsec/data/`. |

## Decisions / blocking

| Symptom | Likely cause | Confirm |
|---|---|---|
| Expected ban "not happening" for an IP | The IP matches an **allowlist** | `cscli allowlists check <ip>` → [../configure/allowlists.md](../configure/allowlists.md). |
| Decision exists, traffic still passes | Bouncer latency / scope / key / IP family | Full ladder: [bouncer-not-blocking.md](./bouncer-not-blocking.md). |

When the string isn't here, capture the full forensic bundle with
[`scripts/diagnose.sh`](../../scripts/diagnose.sh) and read the agent log around
the first `level=error`/`FATAL` — the *first* error is usually the root cause;
later ones are fallout.
