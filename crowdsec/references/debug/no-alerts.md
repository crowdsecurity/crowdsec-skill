# Debug — Scenarios not firing (no alerts)

Canonical docs: <https://docs.crowdsec.net/docs/next/troubleshooting/intro> · `cscli metrics` <https://docs.crowdsec.net/docs/next/observability/cscli_metrics>

Commands below are written for **bare-metal** (`sudo cscli …`). In docker,
prefix with `docker exec <name>`; in k8s, `kubectl exec -n <ns> <pod> --`.

Symptom: events are parsed, scenarios are installed, but `cscli alerts list` is
empty (or an attack you generated produced nothing). Work down this ladder.

## 0 — Is it actually parsed?

If `cscli metrics show acquisition` shows 0 parsed for the relevant source, the
problem is upstream — go to [parsing.md](./parsing.md) first. Everything below
assumes lines **are** parsing.

If the source row is **entirely absent** (not merely 0 parsed — *no row for the
attacked service at all*, e.g. nginx running but no `file:/var/log/nginx/...`
row), the service's logs aren't in acquisition. Jump straight to
[parsing.md](./parsing.md) § "Collection installed but no source feeds it" rather
than chasing scenarios below.

## 1 — Is the scenario receiving events?

```bash
sudo cscli metrics show scenarios
```

- **Scenario absent / 0 events**: the parsed event isn't being poured into that
  bucket. Usually the collection that ties the parser to the scenario isn't
  fully installed, or the event's `type`/program doesn't match the scenario's
  filter. `cscli scenarios list` to confirm it's enabled; reinstall the
  collection if partial.
- **Events in, "overflow" 0**: traffic didn't cross the scenario threshold
  (e.g. `ssh-bf` needs N failures in the window). Generate enough events, or
  test with a purpose-built probe — see [../operate/health-check.md](../operate/health-check.md).

## 2 — Source IP whitelisted (the most common "silent" cause)

`crowdsecurity/whitelists` ships **enabled** (at
`/etc/crowdsec/parsers/s02-enrich/whitelists.yaml`) and whitelists RFC1918
ranges: `10/8`, `172.16/12`, `192.168/16`. Events from those IPs are dropped at
`s02-enrich` **before** any bucket — no alert, by design.

```bash
sudo cscli metrics show acquisition     # "Lines whitelisted" column non-zero?
```

Testing from a private IP will *never* alert. Test from a public IP, from
mobile data, or temporarily `cscli parsers remove crowdsecurity/whitelists`
(re-install after). This is the #1 reason "my attack didn't trigger anything".

If the *alert* exists but no ban does, it's an **allowlist**, not a whitelist
parser — these are different layers. See
[../configure/allowlists.md](../configure/allowlists.md) § Suppression
mechanisms for the full comparison.

## 3 — Simulation mode masking the alert

```bash
sudo cscli simulation status
```

Normal output: `global simulation: disabled`. If it's
**enabled**, or a specific scenario is listed, that scenario produces an alert
but **no decision** (it's "simulated"). `cscli alerts list` still shows it with
`simulation: true`; `cscli decisions list` stays empty. Toggle with
`cscli simulation disable [scenario]`.

## 4 — LAPI write failure (alert generated but not stored)

The agent detects but can't persist to LAPI. Check the agent log
(`/var/log/crowdsec.log`) for write errors:

- **`database is locked`** (sqlite): concurrent writers / slow disk — see
  [common-errors.md](./common-errors.md).
- **Disk full**: `df -h /var/lib/crowdsec` — sqlite write fails silently from
  the user's view.
- **Remote LAPI unreachable**: agent-only node can't reach the LAPI host.
  `cscli lapi status` from the agent. See
  [../operate/multi-server.md](../operate/multi-server.md).

## 5 — Right scenario at all?

Confirm the installed scenario actually matches your attack with a read-only
replay (no traffic, no state change):

```bash
sudo cscli explain --log '<a real offending log line>' --type <type>
```

Green scenario nodes = it *would* fire on that line; if none are green, the
installed scenario set doesn't cover this attack. Installing a better hub
collection is in scope; **authoring a scenario is not** — that's outside this
skill.
