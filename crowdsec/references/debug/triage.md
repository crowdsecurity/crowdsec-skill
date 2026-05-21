# Debug — First-look triage

Use this when the user reports a CrowdSec problem and you don't yet know the shape of it.
Goal: in under ten commands, narrow "it's broken" to one of:
*not running*, *not reading logs*, *reading but not parsing*, *parsing but not bucketing*,
*bucketing but not alerting*, *alerting but not deciding*, *deciding but not blocking*.

Canonical docs: <https://docs.crowdsec.net/docs/next/troubleshooting/intro> · `cscli metrics` <https://docs.crowdsec.net/docs/next/observability/cscli_metrics>

## The fast path: run `diagnose.sh`

```bash
~/.claude/skills/crowdsec/scripts/diagnose.sh
# or, with custom log tail and a saved text copy:
~/.claude/skills/crowdsec/scripts/diagnose.sh --log-lines 500 --output /tmp/cs-triage.txt
```

`diagnose.sh` wraps `cscli support dump --fast` — the official forensic snapshot — and emits two things:

- a **sectioned text report** to stdout (or `--output`) that Claude reads to triage in-conversation
- a **canonical zip archive** at `/tmp/crowdsec-support-<timestamp>.zip` (or `--archive`) that contains everything CrowdSec support would ask for: prometheus metrics, system info, redacted config, pprof goroutine/heap dumps, full logs, hub state, etc. Hand this archive to CrowdSec support without re-running anything.

The script auto-detects systemd / docker / k8s. For non-default deployments:

```bash
diagnose.sh --env docker --container crowdsec
diagnose.sh --env k8s --namespace crowdsec --pod crowdsec-agent-xxxx
```

Read the text report top-to-bottom. The section headers map onto the funnel below.

## Manual triage funnel (when `diagnose.sh` can't run)

Read these one at a time and stop at the first anomaly. Each level matches a deeper-debug reference.

### 1. Is the agent running?

| Env | Command |
|---|---|
| systemd | `systemctl is-active crowdsec && systemctl is-enabled crowdsec` |
| docker  | `docker ps --filter name=crowdsec --format '{{.Names}} {{.Status}}'` |
| k8s     | `kubectl get pods -A -l app.kubernetes.io/name=crowdsec` |

If not running → `journalctl -u crowdsec -n 200` / `docker logs <name>` / `kubectl logs <pod>`. Then [common-errors.md](./common-errors.md).

### 2. Is acquisition reading anything?

```
cscli metrics
```
Look at the **Acquisition Metrics** table. For each source you expect:

- **Source row entirely absent** for a service you run (e.g. nginx active, no `file:/var/log/nginx/...` row) → no acquisition feeds it. Cross-check enabled collections vs declared types: `cscli collections list` vs `grep -r 'type:' /etc/crowdsec/acquis.d/`. Classic when the service was installed *after* `cscli setup` ran. See [parsing.md](./parsing.md) § "Collection installed but no source feeds it".
- **Lines read = 0** → log file not reachable or rotated under it. Check perms, mount, and that the file path in `/etc/crowdsec/acquis.d/*.yaml` is correct. On 1.7.x the default file is split into per-service files in `acquis.d/`; there is no `/etc/crowdsec/acquis.yaml` after `cscli setup`.
- **Lines read > 0, parsed = 0** → wrong `type:` label or no parser installed for it. See [parsing.md](./parsing.md).
- **Mostly unparsed but some parsed** → mixed-format file (e.g. `/var/log/syslog` includes lines that aren't sshd/postfix). Often benign.

### 3. Are scenarios firing?

Same `cscli metrics` output, **Scenario Metrics** table:

- **Instantiated = 0** for every scenario → events aren't matching any bucket filter (acquisition labels wrong, or events whitelisted before reaching the bucket).
- **Instantiated > 0, Poured > 0, Overflows = 0** → buckets receive events but never tip. Either threshold not reached, or LEAKY decay too fast for the traffic. See [no-alerts.md](./no-alerts.md).
- **Overflows > 0** → alerts should exist. Continue to step 4.

Also check **Whitelist Metrics** in the same output — a high `Whitelisted` count can hide expected alerts. And confirm simulation isn't masking:

```
cscli simulation status
```

`global simulation: enabled` means alerts are recorded but no decisions are written. Disable with `cscli simulation disable` if you actually want bans.

### 4. Are alerts and decisions present?

```
cscli alerts list -l 50
cscli decisions list
```

- **No active alerts** → step 3 lied about overflows, or LAPI write failed. Check `tail -n 200 /var/log/crowdsec_api.log` for `database is locked` / disk-full / migration errors.
- **Alerts exist, no decisions** → inspect `/etc/crowdsec/profiles.yaml` (there is no `cscli profiles` command) — the profile filter may not match, or the duration is `0s`. See [../configure/profiles.md](../configure/profiles.md).
- **Decisions exist** → continue to step 5.

### 4½. Is the IP allowlisted?

If a user reports "I expected this IP to be banned but it isn't", or "this user got blocked when they shouldn't have", check allowlists before going deeper:

```bash
cscli allowlists check <ip>          # which allowlist (if any) covers it
cscli allowlists list                 # local + Console-managed
```

Allowlists suppress *new* decisions (local and CAPI/Console) for matching IPs but leave alerts visible — so the symptom is "alerts exist, no decision". See [../configure/allowlists.md](../configure/allowlists.md).

### 5. Is the bouncer pulling and enforcing?

```
cscli bouncers list
cscli lapi status
cscli capi status
```

- **`cscli bouncers list` empty** → no bouncer registered. Install one (firewall, web bouncer, AppSec — see `../configure/bouncers/`).
- **Bouncer present but `Last API pull` is old** → bouncer can't reach LAPI (auth or network). See [bouncer-not-blocking.md](./bouncer-not-blocking.md).
- **Bouncer pulling decisions but traffic still passes** → backend state problem (iptables/nftables rules not materialised, web bouncer mis-wired, captcha mode instead of ban). Also see [bouncer-not-blocking.md](./bouncer-not-blocking.md).

### 6. Is the hub healthy?

```
cscli hub list
```

A line with `status: tainted` is hub-managed content modified locally — fix with `cscli <type> upgrade <name> --force`, or move the change to `_custom/` if intentional. A `status: missing` line means the package shipped a reference to an item that wasn't downloaded; `cscli hub update && cscli hub upgrade` usually heals it.

### 7. Is anything LAPI/CAPI degraded?

`cscli lapi status` should print `You can successfully interact with Local API (LAPI)`. Anything else means the agent can't talk to its own LAPI — wrong URL in `/etc/crowdsec/config.yaml` `api.client.credentials_path`, expired creds, or LAPI not listening.

`cscli capi status` shows whether the engine is registered with the Central API (community blocklist, signal sharing, console). Failure here is non-fatal but kills CAPI-pulled blocklists. See [../install/console.md](../install/console.md) for enrollment.

## Live log streaming for an active incident

`cscli explain` replays log lines through the parser pipeline without writing
to LAPI — the single most useful debug tool. Pair with a live agent-log tail:

```bash
sudo tail -F /var/log/crowdsec.log     # bare-metal; docker/k8s: `logs -f`
cscli explain --file /var/log/auth.log --type syslog --only-successful-parsers
```

See [parsing.md](./parsing.md) for the flag combinations.

## Hard don'ts during triage

- **Do not** run `cscli decisions delete --all` to "reset" — it removes every active ban, including CAPI-pulled blocklists. If you need to clear one test IP, use `cscli decisions delete -i <ip>`.
- **Do not** edit `/etc/crowdsec/hub/`, `/etc/crowdsec/parsers/`, `/etc/crowdsec/scenarios/`, or `/etc/crowdsec/collections/` in place to "fix" a hub item. The next `cscli hub upgrade` will overwrite it and the file will show as *tainted* until then. Use `cscli <type> upgrade --force` to restore, and put local overrides in `*/parsers/*/_custom/` etc.
- **Do not** disable a collection wholesale to silence a false positive. Pick the right suppression layer — see [../configure/allowlists.md](../configure/allowlists.md) § Suppression mechanisms.
