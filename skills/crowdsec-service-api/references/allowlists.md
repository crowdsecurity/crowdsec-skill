---
verified:
  - date: 2026-07-29
    version: "1.70.52"
    env: sapi
    notes: "create, items create + list (scope/value fields); delete needs unsubscribe first (409 otherwise)"
  - date: 2026-07-30
    version: "1.70.52"
    env: sapi
    notes: "closed loop: subscribe org -> engine on crowdsec-vm shows it 'Managed by Console: yes', cscli allowlists check confirms the item allowlisted (~40s sync); unsubscribe then delete 204"
---

# SAPI — Allowlists

Canonical docs: <https://docs.crowdsec.net/u/console/service_api/allowlists>
OpenAPI: the `/allowlists` group — <https://admin.api.crowdsec.net/v1/docs>

A cloud **allowlist** is a named set of IPs/ranges (each with optional expiration and reason)
that subscribed engines treat as "never act on this". Same subscription model as
blocklists.

> **Cloud vs local:** this is the *org-wide, Console-pushed* allowlist. A single
> engine's local allowlist/whitelist is different — see the `crowdsec` skill,
> `references/configure/allowlists.md`. A cloud allowlist only reaches an engine
> that is enrolled and **subscribed here** (`crowdsec` skill →
> `references/install/console.md`).
>
> Mutating calls are marked ⚠. `B=https://admin.api.crowdsec.net/v1`, `KEY` set.

## Lifecycle

### Create ⚠ / list / delete ⚠
`name` is required; `description` optional.
```bash
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/allowlists" -d '{
  "name": "corp-sources", "description": "office + CDN source IPs"
}'
curl -s -H "x-api-key: $KEY" "$B/allowlists"                 # list (paginated)
curl -s -H "x-api-key: $KEY" -X DELETE "$B/allowlists/$ID"   # removes list + subscriptions
```
Delete returns **`409 Conflict`** while the list still has subscribers. Either
unsubscribe first (see Subscribers below), or **force it** —
`DELETE "$B/allowlists/$ID?force=true"`. On subscribed engines the allowlist shows
in `cscli allowlists list` as *Managed by Console: yes* and syncs within ~40s.

## Items — the IPs/ranges

`items` and `description` are required; `expiration` optional (RFC3339).
```bash
# add items ⚠
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/allowlists/$ID/items" -d '{
  "items": ["203.0.113.10", "198.51.100.0/24"],
  "description": "office ranges"
}'

curl -s -H "x-api-key: $KEY" "$B/allowlists/$ID/items"                          # list items
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' \
  -X PATCH "$B/allowlists/$ID/items/<item_id>" -d '{"expiration":"2026-12-31T00:00:00Z"}'   # ⚠ update
curl -s -H "x-api-key: $KEY" -X DELETE "$B/allowlists/$ID/items/<item_id>"      # ⚠ delete item
```
Items accept a single IP or a CIDR range.

## Subscribers — who applies the allowlist ⚠

`entity_type` is required, one of: `org`, `tag`, `engine`, `firewall_integration`,
`remediation_component_integration`, `remediation_component`, `log_processor`. As
with blocklists, `org` takes **no `ids`** (whole org); the other types take `ids`.
```bash
# a specific tag
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/allowlists/$ID/subscribers" -d '{
  "entity_type": "tag", "ids": ["<tag_id>"]
}'
# the entire org (no ids)
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/allowlists/$ID/subscribers" -d '{"entity_type":"org"}'
curl -s -H "x-api-key: $KEY" "$B/allowlists/$ID/subscribers"                       # list
curl -s -H "x-api-key: $KEY" -X DELETE "$B/allowlists/$ID/subscribers/<entity_id>" # ⚠ unsubscribe
```

## Use case — fleet-wide "don't block us"

Put office/CDN/monitoring ranges in one allowlist, subscribe by `tag` (or `org` for
everything). New engines that inherit the tag pick it up automatically — no
per-engine config. Set `expiration` on temporary items (a vendor's scan window,
a short-lived NAT) so they clean themselves up.
