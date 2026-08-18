---
verified:
  - date: 2026-07-29
    version: "1.70.52"
    env: sapi
    notes: "create/list/get, add IPs (201), ips/delete, download (204 eventual-consistency observed); delete needs unsubscribe first (409 otherwise); search not exercised"
  - date: 2026-07-30
    version: "1.70.52"
    env: sapi
    notes: "closed loop: subscribe org (remediation required) -> PAPI force_pull -> engine active decision origin=lists on crowdsec-vm; unsubscribe then delete 204"
---

# SAPI — Blocklists

Canonical docs: <https://docs.crowdsec.net/u/console/service_api/blocklists>
OpenAPI: the `/blocklists` group — <https://admin.api.crowdsec.net/v1/docs>

A **blocklist** is a named, cloud-hosted list of IPs (each with optional
expiration). You add IPs via API, then **subscribe** engines / bouncers / firewall
integrations / whole orgs to it — they pull and **enforce** it. You can also
**share** a blocklist read/write with another organization.

> Mutating calls below are marked ⚠ — the URL + body must be shown and approved
> before sending (see SKILL.md operating contract). All snippets assume
> `B=https://admin.api.crowdsec.net/v1` and `KEY` set.

## Lifecycle

### Create ⚠
`name` and `description` are required.
```bash
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/blocklists" -d '{
  "name": "siem-high-confidence",
  "description": "IPs pushed from our SIEM",
  "label": "SIEM feed",
  "tags": ["siem"]
}'
```
The response `id` is what every other call uses (`ID=<that id>`).

### List / get
```bash
curl -s -H "x-api-key: $KEY" "$B/blocklists?page=1&page_size=100"   # add subscribed_only=true to see only what you consume
curl -s -H "x-api-key: $KEY" "$B/blocklists/$ID"
```
Useful list filters: `subscribed_only=true`, `exclude_subscribed=true`,
`include_filter=private,shared`, `category=…`.

### Update ⚠ / Delete ⚠
```bash
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X PATCH "$B/blocklists/$ID" -d '{"description":"new desc"}'
curl -s -H "x-api-key: $KEY" -X DELETE "$B/blocklists/$ID"   # removes the list AND every subscription/feed to it
```
Delete returns **`409 Conflict`** while the list still has subscribers. Either
unsubscribe everyone first (see Subscribers below), or **force it** —
`DELETE "$B/blocklists/$ID?force=true"` drops the list and all its subscriptions.

## Content — the IPs

| Action | Call | Notes |
|---|---|---|
| **Add** IPs | `POST /blocklists/$ID/ips` | Additive. `{"ips":[…],"expiration":"…"}`; `expiration` optional (RFC3339). |
| **Remove** IPs ⚠ | `POST /blocklists/$ID/ips/delete` | `{"ips":[…]}` — un-blocks fleet-wide. |
| **Replace all** ⚠⚠ | `POST /blocklists/$ID/ips/bulk_overwrite` | Wipes the list, then sets exactly these IPs. Not for "add a few". |
| **Download** | `GET /blocklists/$ID/download` | Published content (raw, one IP/line). Safe. |

A successful add returns `201`. Content is **eventually consistent**: right after
an add, `GET …/download` can still return `204 No Content` and `stats.count` `0`
for a short processing interval before the IPs are published. Don't treat an empty
download immediately after an add as a failure — re-check after a moment.

Add with a 24h expiry:
```bash
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/blocklists/$ID/ips" -d '{
  "ips": ["1.2.3.4", "5.6.7.8"],
  "expiration": "'"$(date -u -d tomorrow +%FT%TZ)"'"
}'
```

## Subscribers — who enforces the list ⚠

Subscribe entities so they pull this blocklist. Two fields are **required**:
`entity_type` (one of `engine`, `firewall_integration`,
`remediation_component_integration`, `tag`, `org`) and `remediation` (the action
the subscribers apply, e.g. `ban`). `ids` depends on the type:

| `entity_type` | `ids` |
|---|---|
| `engine` / `firewall_integration` / `remediation_component_integration` / `tag` | required — the specific entity ids to subscribe |
| `org` | **must be omitted** — subscribes the whole org (sending `ids` errors with *"Organization type subscription can't have ids"*) |

```bash
# subscribe specific engines
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/blocklists/$ID/subscribers" -d '{
  "entity_type": "engine",
  "ids": ["<engine_id_1>", "<engine_id_2>"],
  "remediation": "ban"
}'

# subscribe the entire org (no ids)
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/blocklists/$ID/subscribers" -d '{
  "entity_type": "org", "remediation": "ban"
}'

curl -s -H "x-api-key: $KEY" "$B/blocklists/$ID/subscribers"                 # list
curl -s -H "x-api-key: $KEY" -X DELETE "$B/blocklists/$ID/subscribers/<entity_id>"   # ⚠ unsubscribe
```

An enrolled, subscribed engine pulls the blocklist's decisions over PAPI within a
poll cycle (`crowdsec` skill → `references/install/console.md` for enrollment).

To feed a **firewall appliance**, subscribe the *integration* (`entity_type:
firewall_integration`, `ids:[<integration_id>]`) — the device then pulls the
blocklist's IPs in its vendor format. See [integrations.md](./integrations.md).

## Sharing across organizations ⚠

```bash
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/blocklists/$ID/shares" -d '{
  "organizations": [ {"organization_id": "<org-uuid>", "permission": "read"} ]
}'
# permission: "read" (subscribe/view) or "write" (also add/remove IPs)
curl -s -H "x-api-key: $KEY" -X DELETE "$B/blocklists/$ID/shares/<org-uuid>"   # unshare
```

## Discover existing blocklists — search (read-only)

`POST /blocklists/search` finds catalog blocklists (CrowdSec/third-party/custom)
you can subscribe to, filtered by pricing tier, country, classification, etc.
```bash
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/blocklists/search" -d '{
  "query": "ssh", "pricing_tiers": ["premium"], "min_ips": 100, "page": 1, "page_size": 20
}'
```

## Use case — SIEM/SOAR feed

1. Create one blocklist (once). 2. Subscribe your engines/integrations (once).
3. On each detection, `POST …/ips` with a short `expiration`. Expired IPs drop off
automatically — no cleanup job needed. Use `…/ips/delete` only to pull an IP early;
reserve `bulk_overwrite` for a full authoritative re-sync from the source of truth.
