---
verified:
  - date: 2026-07-30
    version: "1.70.52"
    env: sapi
    notes: "list + aggregated reads; create org-targeted ban (POST -> 200 {uuid}) confirmed present in /decisions; DELETE /decisions/{uuid} -> 204, decision stays listed by design (deletion order retained for later pollers)"
---

# SAPI — Decisions (org-level)

Canonical docs: <https://docs.crowdsec.net/u/console/service_api/getting_started>
OpenAPI: the `/decisions` group — <https://admin.api.crowdsec.net/v1/docs>

Org-scoped decisions in the cloud (distinct from a single engine's *local*
decisions, which live behind `cscli` in the `crowdsec` skill). A decision is one
remediation (`ban`, `captcha`…) on a `scope`/`value` (an IP, range, country, AS),
`target`ed at your `org`, a `tag`, or a single `entity`, for a `duration`.

**Decisions vs blocklists** — both end up as enforced decisions on subscribed
engines; pick by shape of the task:

| Use **decisions** for | Use **[blocklists](./blocklists.md)** for |
|---|---|
| A targeted / ad-hoc ban (one IP, right now) | A maintained IP feed (SIEM/SOAR, threat intel) |
| Non-IP scopes — range, country, AS | Bulk IP sets you add/expire/bulk-overwrite |
| Aiming at one `tag`/`entity` instead of a whole subscription | Sharing a curated list across orgs / vendor integrations |
| Org-wide decision **visibility** (list + aggregate) | — |

> **Access:** the `/decisions` group needs a **decision-scoped key**. A key scoped
> only to blocklist/allowlist management gets `403 {"message":"Forbidden"}` on
> every call here — an entitlement gap, not a bad request.
>
> Mutating calls marked ⚠. `B=https://admin.api.crowdsec.net/v1`, `KEY` set.

## List (read-only)

```bash
curl -s -H "x-api-key: $KEY" "$B/decisions?page=1&size=50"
curl -s -H "x-api-key: $KEY" "$B/decisions?ips=1.2.3.4"        # find decisions for an IP
```
Returns the paginated envelope `{items, total, page, size, links}`; each item is a
full decision (`uuid`, `origin`, `scenario`, `scope`, `type`, `value`, `duration`,
`target`, geo fields). Note `id` is `0` for org-targeted decisions — the
identifier that matters is `uuid` (see delete). Filters: `ips=`, `instance_ids=`,
`tag_ids=`, `remediation_types=`, `alert_ids=`, `decision_ids=`, `created_at_from=`,
`sort_by=` (default `created_at`), `sort_order=` (default `desc`) — repeatable
where plural.

## Aggregated (read-only)

```bash
curl -s -H "x-api-key: $KEY" "$B/decisions/aggregated"
```
Collapses decisions by `scope`/`type`/`value`. Each item's `id` is a
**URL-encoded JSON composite key** — decoded, `{"organization_id":…,"scope":"ip","type":"ban","value":"1.2.3.4"}`.
In testing this view listed only CAPI/community-origin decisions, not a freshly
`POST`ed org decision — so don't rely on it to find something you just created.

## Create ⚠

Required: `duration`, `origin`, `scenario`, `scope`, `type`, `value`, and `target`
(`type` ∈ `org`/`tag`/`entity`, `value` = the org id / tag id / entity id). `scope`
uses the usual CrowdSec values (`Ip`, `Range`, `Country`, `AS`); `type` is `ban`,
`captcha`, etc. Get your org id from [`/info`](./authentication.md).

```bash
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/decisions" -d '{
  "duration": "4h",
  "origin": "cscli",
  "scenario": "manual",
  "scope": "Ip",
  "type": "ban",
  "value": "1.2.3.4",
  "target": { "type": "org", "value": "<org-uuid>" }
}'
# → {"uuid":"…"}
```
An `org` target pushes to **every** enrolled engine in the org (each enforces it
within a poll cycle) — treat it like a blocklist mutation and confirm first.

## Delete ⚠

Two delete paths, both returning `204`:

```bash
curl -s -H "x-api-key: $KEY" -X DELETE "$B/decisions/<uuid>"                      # per decision
curl -s -H "x-api-key: $KEY" -X DELETE "$B/decisions/aggregated/<aggregated_id>" # per aggregated key
```

A deleted decision **stays visible** in `GET /decisions`. That is by design, not a
failed delete: the record is kept so that engines and integrations polling later —
including ones that enroll after the deletion — receive the order to drop it.
Don't re-issue the DELETE or report it as broken because the decision is still
listed.
