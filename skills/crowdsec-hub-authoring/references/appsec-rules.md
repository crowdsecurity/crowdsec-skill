---
verified:
  - date: 2026-11-27
    version: "1.8.2"
    env: hubtest
    notes: "example vpatch rule + hubtest create/run --appsec with the hub docker/appsec OpenResty target and nuclei; negative control fails; crowdsec-local-mcp 0.9.3 tools (fetch, validate, lint, run_waf_tests positive + negative, prepare_waf_pr)"
---

# Authoring — AppSec (WAF) rules

Canonical docs: create <https://docs.crowdsec.net/docs/next/appsec/create_rules> · syntax <https://docs.crowdsec.net/docs/next/appsec/rules_syntax> · contributing <https://docs.crowdsec.net/docs/next/contributing/hub/appsec_rules>

For deploying/operating the WAF, use the `crowdsec` skill (`references/appsec/`).

To draft and pre-test a rule, use the [crowdsec-local-mcp](https://github.com/crowdsecurity/crowdsec-local-mcp) MCP server (`uvx --from crowdsec-local-mcp init claude-code`):

- `generate_waf_rule` / `generate_waf_tests` return prompts; you write the rule.
- `fetch_nuclei_exploit <CVE>` pulls the nuclei template from projectdiscovery.
- `validate_waf_rule` checks the schema, `lint_waf_rule` gives hints.
- `run_waf_tests` runs the nuclei template against a Docker CrowdSec + OpenResty stack
  and fails if the request isn't blocked.

It doesn't replace the rules below: validation accepts a rule that matches every request
(`.*`, no labels). `prepare_waf_pr` needs `rule_filename` as `appsec-rules/<author>/<name>.yaml`
(a bare name lands at the hub root), overwrites an existing test's `config.yaml`, and adds
neither the `.md` nor the collection entry.

## Naming

| Prefix | For |
|---|---|
| `vpatch-CVE-YYYY-NNNN` | one vulnerability; test named `CVE-YYYY-NNNN`/`vpatch-CVE-…` |
| `crs-` | OWASP CRS bridge |
| `generic-` | behavioral, not tied to one CVE |
| `experimental-` | detects, never blocks (loaded out of band) |

Ship a same-name `.md` next to the rule (`appsec-rules/<author>/<name>.md`): what it
detects, the CVE or advisory link, affected versions. Most existing `vpatch-*` rules
lack one; new rules include it. Format: [collections-and-docs.md](./collections-and-docs.md).

## Rule skeleton

```yaml
name: crowdsecurity/vpatch-CVE-2025-49113
description: 'Detects RCE via PHP object deserialization in Roundcube'
rules:
  - and:
      - zones: [METHOD]
        match: {type: equals, value: POST}
      - zones: [ARGS]
        variables: [_action]
        transform: [urldecode, lowercase]
        match: {type: equals, value: upload}
      - zones: [ARGS]
        variables: [_from]
        transform: [urldecode, lowercase]
        match: {type: regex, value: "[^\\w.-]"}
labels:
  type: exploit
  service: http
  confidence: 3
  spoofable: 0
  behavior: 'http:exploit'
  label: "Roundcube - RCE"
  classification:
    - cve.CVE-2025-49113
    - attack.T1190
    - cwe.CWE-502
```

## What reviewers check

- **Precision over breadth**: scope to the vulnerable endpoint/parameter of the
  vulnerable product. Prefer "value contains characters a legit value never has"
  (`[^a-z0-9]`, negative regex) over matching one exploit string (#1737, #1738, #1739).
  Consider `libinjection` helpers for injection classes (#1299, #1236).
- If the rule **can't tell an attacker from a legit request** (auth bypass with a
  valid-looking token, legit admin actions), it is closed, not merged (#1604, #1488, #1483, #1486, #1491).
- Apply `transform` (`urldecode`, `lowercase`) before matching; check body vs args zones.
- `label`: "Product - Vulnerability class" ("Cacti RCE", "F5 BIG-IP iControl REST - Authentication Bypass"),
  no "Attempt" (#885, #1347, #1011).
- `classification` must match the CVE; disclosure-only rules shouldn't share the
  RCE CVE bucket unintentionally (#1714).
- Metadata (product names, versions, URLs) must match what the rule actually covers.

## Test (`.appsec-tests/<test>/`)

```yaml
# config.yaml
appsec-rules:
  - ./appsec-rules/crowdsecurity/base-config.yaml
  - ./appsec-rules/crowdsecurity/vpatch-CVE-2025-49113.yaml
nuclei_template: vpatch-CVE-2025-49113.yaml
```

The nuclei template sends the exploit request(s) and expects `403` (blocked).
Capture real requests with `nc -lvp 4245` + the PoC. Run:

```bash
cscli hubtest create vpatch-CVE-YYYY-NNNN --appsec
cscli hubtest run vpatch-CVE-YYYY-NNNN --appsec
```

Add a test when matching logic, transforms or exclusions change.

## Collections and CI

- New `vpatch-*` rules must be listed in `collections/crowdsecurity/appsec-virtual-patching.yaml`
  (`appsec_vpatch_lint` comments otherwise); product-specific ones may go in a product
  vpatch collection (e.g. WordPress) (#1737–#1739).
- Adding a rule to an appsec-config is not enough for it to be downloaded — it must be
  in a collection (#1393); `generic-*` collections need `crowdsecurity/base-config` (#1011).
- `waf-check` replays legitimate traffic and fails on false positives even if the rule's
  own test passes.
