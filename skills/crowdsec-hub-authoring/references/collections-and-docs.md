---
verified:
  - date: 2026-11-27
    version: "1.8.2"
    env: hubtest
    notes: "example collection and context loaded as local items (cscli inspect, crowdsec -t); acquisition examples not exercised"
---

# Authoring — collections, contexts and `.md` docs

Canonical docs: collections <https://docs.crowdsec.net/docs/next/log_processor/collections/format> · alert context <https://docs.crowdsec.net/docs/next/log_processor/alert_context/intro>

## Collection

Supporting a new service = parser + scenario(s) + a collection bundling them.

```yaml
name: alice/myservice
parsers:
  - alice/myservice-logs
scenarios:
  - alice/myservice-bf
  - alice/myservice-user-enum
contexts:
  - crowdsecurity/bf_base        # optional, needs Meta.target_user
description: "MyService parser and bruteforce detection"
labels:
  label: "MyService - Generic Protection"
author: alice
tags:
  - security_engine
  - linux
  - bruteforce
  - myservice
```

- Reference items **by name**, never by path (#379). Don't list the collection in itself (#446).
- Only collections may declare dependencies; no empty lists (`parsers: []`) (hublint).
- `name` + `labels.label` + `security_engine` tag are the current convention (141/145 collections) (#1332).
- No `version:` field — CI versions items (#1370).
- Web servers / proxies: include `crowdsecurity/base-http-scenarios` (and
  `http-cve`) plus `crowdsecurity/http_base` context — copy `crowdsecurity/nginx` (#1332, #273).
- Don't put FP-prone scenarios in a collection users install by default (#245, #406).
- Extending an existing product? Prefer adding to its existing collection, or make
  the old collection include the new one so existing users get it (#612, #980).

## Context

`contexts/<author>/<name>.yaml` adds key/value pairs to alerts:

```yaml
context:
  target_user:
    - evt.Meta.target_user
```

Reuse `crowdsecurity/http_base` / `crowdsecurity/bf_base` when your Meta matches them.

## `.md` files

Every item has a same-name `.md` (rendered on hub.crowdsec.net). Keep them short
and factual (Copilot instructions + #1606):

- **Collection:** one paragraph on the product + link to it, **acquisition example**
  for each realistic deployment (file / docker / journald), minimum product version
  if relevant (#758, #412, #695, #1096). Copy the parser's acquisition example up to
  the collection (users read the collection page) (#833).
- **Parser:** formats supported, how to enable the needed log output, acquisition example.
- **Scenario:** what it detects + **bucket setup** (capacity/leakspeed/what is counted) (#378, #427, #708).
- **Whitelist:** what it allows and the issue it fixes (#609).

Acquisition examples:

```yaml
filenames:
  - /var/log/myservice/*.log
labels:
  type: myservice      # becomes evt.Parsed.program via s00
---
source: docker
container_name:
  - myservice
labels:
  type: myservice
---
filenames:
  - /var/log/syslog
labels:
  type: syslog         # program comes from the syslog tag
```

Remove: TODOs, placeholder text, invented options (`log_level`, made-up
parameters), long off-topic guides (firewall setup, "how to unban yourself"),
unverified claims about versions/products — reviewers flag hallucinated
content (#1606, #1454, #1427).
