# Authoring — hubtest

Canonical docs: `cscli hubtest` <https://docs.crowdsec.net/docs/next/cscli/cscli_hubtest> · test env <https://docs.crowdsec.net/docs/next/contributing/engine/test_env> · parser test <https://docs.crowdsec.net/docs/next/log_processor/parsers/create#create-our-test>

Tests are mandatory for new parsers, scenarios and AppSec rules, and for any
parser change that adds a format. Missing or non-triggering tests are the most
common reason PRs stall.

## Layout

```
.tests/myservice-logs/          # parser test
  config.yaml  myservice-logs.log  parser.assert
.tests/myservice-bf/            # scenario test
  config.yaml  myservice-bf.log  scenario.assert   (parser.assert empty/absent)
```

**Split parser and scenario tests** (#1909, #1427, #1833): the parser test has no
scenario; the scenario test sets `ignore_parsers: true`.

## config.yaml

```yaml
parsers:
  - crowdsecurity/syslog-logs            # always an s00 parser (#758, #716, #1606)
  - ./parsers/s01-parse/alice/myservice-logs.yaml   # item under test: relative path
  - crowdsecurity/dateparse-enrich       # needed for timestamps / scenarios
scenarios:
  - ./scenarios/alice/myservice-bf.yaml  # scenario test only
postoverflows:
  - ""
log_file: myservice-bf.log
log_type: myservice        # = the acquisition labels.type → evt.Parsed.program
ignore_parsers: true       # scenario test only
```

- `log_type: syslog` when lines carry a syslog header; otherwise the program name
  (not `non-syslog`) (#758).
- Don't add `docker-logs` unless lines are docker JSON (#664).
- Load the item **this PR ships** — e.g. not `crowdsecurity/cowrie-logs` when the PR
  adds `alice/cowrie-logs` (#1833).
- HTTP parsers: add `crowdsecurity/http-logs` and a scenario test with an HTTP
  scenario (e.g. `http-probing`, `http-bad-user-agent`) to prove `Meta` is wired
  correctly (#716, #1549, #1561).

## Logs

- Real lines (anonymized), covering every node/format, success and failure lines,
  IPv6, and **negative** lines that must not parse/whitelist (#1332, #1292, #1947).
- **Only private/documentation IPs**: `192.168.0.0/16`, `10/8`, `172.16/12`,
  `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` — no WAN, no `169.254` (#1580, #1427).
- A scenario log must contain enough events to overflow, for each scenario variant
  (bf **and** user-enum) (#430).

## Asserts

```bash
TZ=UTC cscli hubtest run myservice-logs     # empty assert → prints generated assertions
# paste the FULL output into parser.assert / scenario.assert, re-run → passes
cscli hubtest explain myservice-logs        # per-line stage view
```

- Commit the **complete** generated output, all stages — no filtering, no hand
  edits, no comments (#1580, #967, #771, #1606, #1963).
- Adding log lines to an existing test → **regenerate** the whole assert, don't
  append by hand (#1951, #1963, #1684, #1093).
- `scenario.assert` = `len(results) == 0` means the scenario **didn't fire** — a bug (#1798, #1833, #738).
- Omit `parser.assert` when `ignore_parsers: true`; omit `scenario.assert` when no
  scenario is loaded (#1580, #1179).
- Never commit `results/` or `runtime/` (#374).
- Run with `TZ=UTC`: CI is UTC and `dateparse-enrich` marshals times in local TZ (#783).

## Running locally without root

`/etc/crowdsec/config.yaml` is root-only. Build a user-owned instance and pass `-c`:

1. `git -C ~/dev/crowdsec show v<installed>:config/config.yaml`, rewrite
   `/etc/crowdsec`, `/var/lib/crowdsec/data`, `/var/log` into one directory;
   `daemonize: false`, prometheus off, another LAPI port, drop `online_client`.
2. Copy `patterns/`, `profiles.yaml`, `simulation.yaml`, `console.yaml` from `/etc/crowdsec`.
3. `mkdir <inst>/etc/hub`, `cscli -c … hub update`, `cscli -c … machines add --auto -f <inst>/etc/local_api_credentials.yaml`.
4. Dummy file acquisition so `crowdsec -c … -t` passes.
5. `cscli -c <cfg> hubtest run <test> --crowdsec /usr/bin/crowdsec --cscli /usr/bin/cscli --hub <short-path> --clean`

The hub path must be short: crowdsec binds a unix socket under
`<hub>/.tests/<test>/runtime/` (108-char limit) — symlink a short path. After a
failed run delete `runtime/` and `results/` before retrying.

## Whole-suite checks

When touching a shared parser (sshd, nginx, syslog-logs, http-logs, traefik…), run
every test that loads it:

```bash
grep -l 'sshd-logs' .tests/*/config.yaml | xargs -n1 dirname | xargs -n1 basename
```

CI runs `cscli hubtest run --all` against **crowdsec master**, so a parser relying on
an unreleased engine feature passes CI but not on users' engines — test on the
released version too.

## Replay outside hubtest

`crowdsec -c <cfg> -dsn file://x.log -type syslog -dump-data <dir>` (needs the
instance LAPI; `-no-api` fails on agent login). `-transform '<expr>'` tests an
acquisition transform.
