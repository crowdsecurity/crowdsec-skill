---
verified:
  - date: 2026-07-29
    version: "1.70.52"
    env: sapi
    notes: "create (plain_text) returns endpoint + basic-auth credentials{username,password}, delete 204; content pull / update / stream not exercised (no subscribed content)"
---

# SAPI — Integrations (firewall / appliance feeds)

Canonical docs: <https://docs.crowdsec.net/u/console/service_api/integrations>
OpenAPI: the `/integrations` group — <https://admin.api.crowdsec.net/v1/docs>

An **integration** is a pull endpoint that exposes the IPs of the blocklists
subscribed to it, **rendered in a firewall vendor's format**. A device (Palo Alto
EDL, Fortinet threat feed, etc.) polls it on a schedule. The content endpoint uses
**HTTP Basic auth** with credentials minted at creation — the only non-`x-api-key`
call in SAPI.

> Mutating calls marked ⚠. `B=https://admin.api.crowdsec.net/v1`, `KEY` set.

## Create ⚠

Required: `name`, `entity_type`, `output_format`.

- `entity_type` ∈ `firewall_integration`, `remediation_component_integration`.
- `output_format` ∈ `plain_text`, `paloalto`, `fortigate`, `checkpoint`, `cisco`,
  `f5`, `juniper`, `mikrotik`, `pfsense`, `opnsense`, `sophos`, `remediation_component`.

```bash
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/integrations" -d '{
  "name": "edge-paloalto",
  "description": "Palo Alto external dynamic list",
  "entity_type": "firewall_integration",
  "output_format": "paloalto"
}'
```
The response contains `endpoint` (the content URL) and `credentials`
(`username`/`password` for Basic auth) — **shown at creation**; regenerate later if
lost (see Update).

## Wire a blocklist to the integration ⚠

The integration is empty until you subscribe lists to it. From
[blocklists.md](./blocklists.md), subscribe the integration to a blocklist:
```bash
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X POST "$B/blocklists/$BLID/subscribers" -d '{
  "entity_type": "firewall_integration", "ids": ["<integration_id>"]
}'
```

## Pull the content (Basic auth) — what the appliance does

```bash
curl -s -u "<username>:<password>" "$B/integrations/<integration_id>/content?page=1&page_size=1500"
```
Query params: `page` (default 1), `page_size`, `pull_limit`, `enable_ip_aggregation`.
**Paginate** for appliances with a max-entries cap: fetch `page=1,2,…` until a
short/empty page. Point the device's feed/EDL URL at this endpoint with the Basic
credentials.

There is also a decisions **stream** (deltas rather than the full list), for
remediation components that maintain state:
```bash
curl -s -u "<username>:<password>" "$B/integrations/<integration_id>/v1/decisions/stream"
```

## Update ⚠ / Delete ⚠

```bash
# rotate the Basic-auth credentials
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X PATCH "$B/integrations/<id>" -d '{"regenerate_credentials": true}'
# change format or add an entry cap
curl -s -H "x-api-key: $KEY" -H 'Content-Type: application/json' -X PATCH "$B/integrations/<id>" -d '{"output_format":"fortigate","pull_limit":50000}'
curl -s -H "x-api-key: $KEY" -X DELETE "$B/integrations/<id>"   # device feed goes empty/401
```

## Vendor format cheat sheet

| Appliance | `output_format` | Consumes via |
|---|---|---|
| Palo Alto | `paloalto` | External Dynamic List (EDL) |
| Fortinet FortiGate | `fortigate` | External/Threat Feed connector |
| Check Point | `checkpoint` | Custom threat feed |
| Cisco | `cisco` | — |
| F5 | `f5` | — |
| Juniper | `juniper` | — |
| MikroTik | `mikrotik` | address-list |
| pfSense / OPNsense | `pfsense` / `opnsense` | firewall alias / URL table |
| Sophos | `sophos` | — |
| Anything / scripts | `plain_text` | one IP per line |

## Use case — appliance without a native CrowdSec bouncer

For a firewall that can't run a bouncer, an integration turns any subscribed
blocklist into a vendor-native feed the device already knows how to poll — no agent
on the box. Curate the IPs once (blocklist), expose them many ways (one integration
per appliance).
