---
verified:
  - date: 2026-11-27
    version: "1.8.2"
    env: hubtest
    notes: "example parser via hubtest (syslog + non-syslog log_type); anchored pattern drops trailing-text line; cscli explain --log/--file and hubtest explain; grok debugging steps on a broken pattern (explain, debug: true, GREEDYDATA bisect)"
---

# Authoring — parsers

Canonical docs: format <https://docs.crowdsec.net/docs/next/log_processor/parsers/format> · create <https://docs.crowdsec.net/docs/next/log_processor/parsers/create> · patterns <https://docs.crowdsec.net/docs/next/log_processor/parsers/patterns-documentation> · expr helpers <https://docs.crowdsec.net/docs/next/expr/intro>

A parser **extracts fields**; detection logic belongs in scenarios, so others
can reuse the parser.

## Stages

| Stage | Role | You usually… |
|---|---|---|
| `s00-raw` | strip transport framing (syslog header, docker/cri JSON, …) and set `evt.Parsed.program` + `evt.Parsed.message` | never write one |
| `s01-parse` | service parser: `filter` on `program`, grok/JSON on `message`, set `Meta` | write this |
| `s02-enrich` | enrichers (geoip, dateparse, http-logs), parser whitelists | write whitelists here |

`s00` sets `program`: from the syslog tag for `type: syslog`, otherwise from the
acquisition `labels.type` (`crowdsecurity/non-syslog`, docker/cri parsers).
So the same s01 parser works for file, syslog, journald and docker **only if**
it filters on `program` and parses `message`.

## Skeleton (s01)

```yaml
onsuccess: next_stage
filter: "evt.Parsed.program == 'myservice'"
name: alice/myservice-logs
description: "Parse myservice logs"
#debug: true
pattern_syntax:
  MYSERVICE_BADPASS: '^bad password for user %{USERNAME:user} from %{IP:source_ip}$'
nodes:
  - grok:
      name: MYSERVICE_BADPASS
      apply_on: message
      statics:
        - meta: log_type
          value: myservice_failed_auth
statics:
  - meta: service
    value: myservice
  - meta: source_ip
    expression: evt.Parsed.source_ip
  - meta: username
    expression: evt.Parsed.user
  - target: evt.StrTime
    expression: evt.Parsed.timestamp
```

## Rules that reviewers enforce

**Filter**
- Filter on `evt.Parsed.program` (`==`, `in [...]`, `startsWith`). Not `1 == 1`,
  not `evt.Line.Labels.type` (breaks syslog/docker), not machine names (#758, #1461, #630, #1762).
- Keep it tight: no extra conditions that are never true (#1549); don't match on
  message content from *any* program — attacker text could reach your parser.
- For JSON logs put the unmarshal in the filter (cheap reject of non-matching lines):
  ```yaml
  filter: >-
    evt.Parsed.program == 'myservice' &&
    TrimSpace(evt.Parsed.message) startsWith "{" &&
    UnmarshalJSON(evt.Parsed.message, evt.Unmarshaled, "myservice") in ["", nil]
  ```
  `UnmarshalJSON` returns nil on success and logs an error on bad JSON — the
  `startsWith "{"` guard avoids log spam (traefik, gitlab do this). Then read
  `evt.Unmarshaled.myservice.field` (use `evt.Unmarshaled.x["a-b"]` for dashed keys).
  Also filter on the message kind (e.g. `.msg == "Request"`) so non-access JSON
  lines don't become empty `http_access-log` events.

**Input field**
- `apply_on: message`, never `Line.Raw` / `evt.Line.Raw` (raw still has syslog/docker
  prefixes; breaks other transports) (#1461, #858, #1191, #1606).

**JSON**
- Use `UnmarshalJSON` once, not grok on JSON (#444, #538) and not repeated
  `JsonExtract` (reparses + reflection each call, GC pressure) (#1367, #1635, #1215).
- JSON numbers come back as `float64`: a static gives `"404.000000"`. Use
  `int(evt.Unmarshaled.x.status)` for status codes/ports (traefik-logs does this).

**Patterns**
- Reuse built-in grok patterns; don't redefine `GREEDYDATA` & co. (#758).
  A parser **cannot override** a built-in name (engine logs `already registred`
  and keeps the original) — create a copy with a new name.
- Namespace custom pattern names: `MYSERVICE_DATE`, not `DATETIME`/`DATE_YMD`
  (patterns are global, collisions break other parsers) (#1427, #656).
- Prefer `pattern_syntax` over long inline patterns (#1561).
- Be exact: `%{DATA}` only when the field is genuinely unbounded; watch character
  classes (`[0-9%2C]` matches `%`,`2`,`C`, not `%2C`) (#1681); `can.t` vs `can't` (#1798).
- **IPv6**: use `%{IP}` (not `IPV4`), handle `[ip]:port`, `::ffff:` mapped addresses
  (`TrimPrefix`) and add an IPv6 test line (#1951, #333, #1622, #553, #1701).
- **Anchor patterns that capture client-controlled text.** sshd logs usernames and
  disconnect reasons verbatim; unanchored patterns let a client make the parser
  take `source_ip` from its own text and ban any IP (hub #2003/#2004). Use `^…`
  always, and `$` when a username/user-agent precedes the IP. Greedy `.*` before
  the IP picks the **last** match; lazy `DATA` picks the first.
- Multiple quoted client fields (referer, UA): `DATA` + anchored `$` tail so a
  crafted value can't shift later fields (traefik #1978).

**Source IP — the most important field**
- Set `evt.Meta.source_ip` (and keep it in `Parsed` too). It decides who gets banned.
- Use the TCP peer, not `X-Forwarded-For`, unless the app itself validates trusted
  proxies. Header-based IPs are spoofable when the port is exposed and break
  without a proxy (#738, #1909). If you must, implement trusted-proxy logic
  (right-most untrusted hop, peer must be a trusted range) — see #1909's
  `IpInRange` expression — and document it.
- Make sure the field is always a single IP (XFF can be a comma list).

**Meta conventions** (what scenarios and contexts consume)

| Meta | Notes |
|---|---|
| `service` | product name, or `http` for web access logs (`http-logs` enricher and HTTP scenarios require `service: http` + `log_type: http_access-log`/`http_error-log`) (#1549) |
| `log_type` | `<service>_failed_auth`, `<service>_failed_password`, … specific to the product; avoid generic values like `auth_failed` (collide across services) (#412, #503, #1191) |
| `source_ip` | single IP |
| `username` / `target_user` | `target_user` is what `contexts/crowdsecurity/bf_base` reads (#1293) |
| `http_path`, `http_status`, `http_verb`, `http_user_agent`, `target_fqdn` | for HTTP parsers; `http_path` should include the query string (nginx does) so query-based probes are visible |
| `sub_type` / `log_subtype` | optional finer classification |

- Put shared statics at top level, node-specific ones (log_type) under each grok (#1798, #593).
- Every static must reference a field that exists (#1231, #1230); `target:` not `meta:`
  for `evt.StrTime` (#1225); don't set the same static twice (#1225, #1580).
- Don't count one event twice (two lines per failed login → two events) (#1951, #188, #830).

**Timestamps** — required for replay/forensic ("time machine") mode
- Capture the log's own timestamp and set `target: evt.StrTime` (#200, #1231).
- If the format isn't in the engine's built-in list, set `evt.StrTimeFormat` (Go layout).
  Check the **installed** engine version: e.g. `YYYY-MM-DD HH:MM:SS.mmm+01:00`
  (space + offset) is not parsed by v1.8.2's defaults (hub #2002).
- If the log has no timezone, don't invent a deployment-specific offset; use UTC
  (`+0000`/`Z`) — the hub convention (#1685).
- Include `crowdsecurity/dateparse-enrich` in tests.

**Hygiene**
- `#debug: true` (commented) — never committed enabled.
- Comments explaining the item belong in the `.md`, not in YAML (#1580).
- Keep backward compatibility: new formats as new nodes, old test lines kept (#1561, #1096).
- Extending a hub-wide parser (sshd, nginx, postfix…)? Run **all** tests that load it,
  not only yours.

## `onsuccess` and node trees

- Top-level `onsuccess: next_stage`. With child `nodes`, the first successful child
  stops evaluation of the remaining children (`pkg/parser/node.go`) — order
  specific nodes before generic ones, and a catch-all node (e.g. one that only
  unmarshals JSON) makes later siblings dead code.
- A node succeeds if its grok matched, or it has no grok.

## Debugging

```bash
cscli explain --file sample.log --type syslog -v       # against installed items
cscli hubtest explain <test>                            # in the hub repo
```

When a line doesn't parse:

1. `cscli explain --log '<line>' --type <type> -v` shows which stage stopped (🔴) and
   what s00 produced: check that `evt.Parsed.program` matches your `filter` and that
   `evt.Parsed.message` is the text your pattern expects.
2. Set `debug: true` on the parser locally (never committed) and replay the line: the log
   prints `Grok "<NAME>" didn't return data on "<message>"` for each node that failed.
3. Bisect the pattern: keep the anchor, replace everything after a prefix with
   `%{GREEDYDATA:rest}`, and move the cut point until the node turns 🟢. `rest` then
   shows the text the next token must match.
4. Check what a reused pattern accepts. Base patterns (`IP`, `USERNAME`, `IPORHOST`,
   `GREEDYDATA`, …) are built into the engine
   ([`pkg/grok/base.go`](https://github.com/crowdsecurity/crowdsec/blob/master/pkg/grok/base.go));
   service patterns (`NGINXACCESS`, `SSHD_*`, …) live in `/etc/crowdsec/patterns/`.
