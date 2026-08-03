---
verified:
  - date: 2026-07-29
    version: "1.70.52"
    env: sapi
    notes: "GET /metrics/remediation returns raw/computed/stats; units request/byte/packet; computed.saved keys log_lines/storage/egress_traffic"
---

# SAPI — Remediation metrics (ROI)

Canonical docs: <https://docs.crowdsec.net/u/console/service_api/metrics>
OpenAPI: `GET /metrics/remediation` — <https://admin.api.crowdsec.net/v1/docs>

Read-only. Returns what your remediation actually did over a window: traffic
dropped vs processed, plus computed savings — the numbers for an ROI dashboard or
report. `B=https://admin.api.crowdsec.net/v1`, `KEY` set.

## Call

```bash
FROM=2026-07-01T00:00:00Z ; TO=2026-07-29T00:00:00Z
curl -s -H "x-api-key: $KEY" "$B/metrics/remediation?start_date=$FROM&end_date=$TO"
```
Dates are ISO 8601 / RFC3339. Optional filters narrow the scope:
`engine_ids=<id>`, `integration_ids=<id>`, `tags=<tag>` (repeatable).

## What you get

| Group | Fields | Meaning |
|---|---|---|
| **raw.dropped** | requests, bytes, packets | Blocked at the remediation layer. |
| **raw.processed** | requests, bytes, packets | Total seen (dropped + allowed). |
| **computed.saved** | log_lines, storage, egress_traffic | Estimated resources not spent because traffic was dropped. |
| **computed** | dropped, prevented | Aggregate blocked / attacks prevented. |

## Use case — monthly ROI report

Query month-over-month, chart `computed.saved.egress_traffic` and
`raw.dropped.requests`, and attribute per team with `tags=`. Turn "we blocked N
requests" into a concrete savings figure (log lines, storage, egress) for the
report.
