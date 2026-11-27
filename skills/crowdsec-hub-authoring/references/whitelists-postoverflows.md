# Authoring — whitelists and postoverflows

Canonical docs: format <https://docs.crowdsec.net/docs/next/log_processor/whitelist/format> · expr-based <https://docs.crowdsec.net/docs/next/log_processor/whitelist/expr_based_whitelist> · postoverflow <https://docs.crowdsec.net/docs/next/log_processor/whitelist/postoverflow_based_whitelist>

For *user-side* allowlisting (office IPs, CAPI), see
the `crowdsec` skill (`references/configure/allowlists.md`). This page is about
**hub items** that suppress known false positives of an application
(`nextcloud-whitelist`, `plex-allowlist`, `jellyfin-whitelist`, …).

## Which layer

| Layer | Runs | Sees | Use for |
|---|---|---|---|
| Parser whitelist (`parsers/s02-enrich/<author>/<app>-whitelist.yaml`) | on **every event**, before buckets | `evt.Meta`, `evt.Parsed` | app endpoints that legitimately generate 404/403/bursts |
| Postoverflow (`postoverflows/s01-whitelist/…`) | only when a bucket overflows | `evt.Overflow` (`evt.Parsed` is empty) | expensive checks (rdns, data files), or "only if **all** events of this alert are X" |

A parser whitelist removes the event from **every** scenario — including path
traversal and CVE scenarios. Keep it narrow.

## Rules for app whitelists (from review history)

Each expression should constrain **method + status + exact path shape**:

```yaml
name: alice/myapp-whitelist
description: "Whitelist known false positives from MyApp"
filter: "evt.Meta.service == 'http' && evt.Meta.log_type in ['http_access-log', 'http_error-log']"
whitelist:
  reason: "MyApp known false positives"
  expression:
    - evt.Meta.http_verb == 'GET' && evt.Meta.http_status in ['200', '404'] && evt.Meta.http_path matches '^(/[^/?]+)?(/index[.]php)?/apps/myapp/api/preview/\\d+([?]|$)'
```

- `evt.Meta.http_path` **includes the query string**: `contains '/apps/x'` also
  matches `/wp-login.php?x=/apps/x` — anchor with `^` and end with `([?]|$)` (hub #1947).
- `startsWith '/prefix'` also matches `/prefix/../../.env` (raw path, server
  normalizes it) — exclude `..` or match the exact shape.
- Restrict statuses to those actually observed; don't copy a status list blindly.
- Require the numeric id / exact segment where the app uses one.
- Allow a subfolder install and `/index.php/` where the app supports them.
- Back every rule with a real log line; add a **negative** test (crafted request that
  must stay un-whitelisted) next to the positive one (#1947, #1099, #1020).
- In regex YAML strings, escape for YAML *and* regex (`\\d`, `[.]`), and check
  character-class semantics (#1681).
- Link the issue in the `.md` (#609).

## Postoverflow pattern ("all events must be benign")

```yaml
name: alice/matrix-whitelist
description: "Whitelist known false positives from Matrix clients"
whitelist:
  reason: "Matrix known false positives"
  expression:
    - |
      evt.Overflow.Alert.GetScenario() == 'crowdsecurity/http-probing' && all(evt.Overflow.Alert.Events, {
        .GetMeta('http_verb') == 'GET' && .GetMeta('http_status') == '404' &&
        .GetMeta('http_path') matches '^/_matrix/federation/v1/event/[^/]+$'
      })
```

One rule per scenario. `all()` only sees the last `cache_size` events of the alert.

## IP/range whitelists

- Data must come from `crowdsecurity/sec-lists` (synced sources) so ranges stay
  current — don't hardcode provider ranges or point at third-party URLs (#1896).
- Never whitelist a whole cloud (AWS/Azure/GitHub-hosted runners): attackers rent
  VMs there (#834, #1465). Scope to the specific service (e.g. CloudFront, not EC2).
- `File()` reads line by line — no JSON documents as data files (#1465).
