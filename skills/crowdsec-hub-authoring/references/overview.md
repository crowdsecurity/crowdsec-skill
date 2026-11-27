# Authoring hub items — overview

Canonical docs: <https://docs.crowdsec.net/docs/next/contributing/contributing_hub> · parsers <https://docs.crowdsec.net/docs/next/log_processor/parsers/create> · scenarios <https://docs.crowdsec.net/docs/next/log_processor/scenarios/create> · repo <https://github.com/crowdsecurity/hub>

This section covers **writing** hub items (parsers, scenarios, whitelists,
postoverflows, collections, contexts, AppSec rules) and getting them merged
into `crowdsecurity/hub`. It is distilled from the docs, the hub's CI and lint
code, and maintainer review comments on ~1500 merged/closed PRs.

| Writing a… | Read |
|---|---|
| parser (`s00`/`s01`/`s02`) | [parsers.md](./parsers.md) |
| scenario | [scenarios.md](./scenarios.md) |
| whitelist (parser `s02`) or postoverflow | [whitelists-postoverflows.md](./whitelists-postoverflows.md) |
| collection, context, `.md` docs | [collections-and-docs.md](./collections-and-docs.md) |
| hubtest (`.tests/`, `.appsec-tests/`) | [testing.md](./testing.md) |
| AppSec / WAF rule | [appsec-rules.md](./appsec-rules.md) |
| reviewing a PR (or self-review before opening one) | [review-checklist.md](./review-checklist.md) |

## Repository layout

```
parsers/s00-raw/<author>/<name>.yaml      # strip transport prefixes (syslog, docker, cri…)
parsers/s01-parse/<author>/<name>.yaml    # service parsers: extract fields
parsers/s02-enrich/<author>/<name>.yaml   # enrichers + parser whitelists
scenarios/<author>/<name>.yaml
postoverflows/s00-enrich|s01-whitelist/<author>/<name>.yaml
collections/<author>/<name>.yaml
contexts/<author>/<name>.yaml
appsec-rules/<author>/<name>.yaml   appsec-configs/<author>/<name>.yaml
.tests/<test-name>/        # log-based hubtests
.appsec-tests/<test-name>/ # nuclei-based AppSec hubtests
taxonomy/behaviors.json mitre_attack.json scenarios.json …   # scenario label validation
```

Every item gets a same-name `.md` next to it (rendered on hub.crowdsec.net).

## Naming and ownership — hard rules

- **Author = directory = name prefix = `author:` field.** `parsers/s01-parse/alice/foo-logs.yaml`
  has `name: alice/foo-logs`; the collection has `author: alice`. hublint
  fails on mismatches (`author must match the item key`, path must match type/stage/name).
  Use your GitHub username; no spaces (#370, #379).
- **Never create new items in the `crowdsecurity/` namespace** unless you are on the
  CrowdSec team (#1798, #430, #1340).
- **Items cannot be renamed.** Renames break user configs (profiles,
  postoverflows, `collections:` lists in compose files) and leave the old
  item on disk. Typo-fix PRs on names are closed (#364, #340, #1122, #1754, #1858).
  Pick the name carefully the first time.
- Name parsers `<product>-logs`, scenarios `<product>-bf`, `<product>-user-enum`,
  `<product>-slow-bf`, etc., after the **application**, not the distro/appliance it ran on
  (charon not opnsense-ipsec #977; opensearch-dashboards not wazuh #1215; no `linux` in names).
- Don't bump versions or edit `.index.json`/`taxonomy/scenarios.json` — CI regenerates
  and versions items on merge (#1257, #1370, #1401, #1854).

## What gets accepted / rejected

Accepted: support for a real, publicly available service; fixes with a log
line proving the new format; tests.

Rejected or closed (with the reasons maintainers gave):

| Pattern | Why |
|---|---|
| No tests, or tests that don't actually trigger | the #1 blocker; PRs go to draft then get closed for inactivity (#412, #438, #467, #1436, #1503) |
| A second parser for a service that already has one | extend the existing parser instead (#802, #1695, #1762, #1676) |
| A scenario duplicating an existing one | e.g. path traversal already in `http-path-traversal-probing` (#1944), OpenVPN bf (#1762) |
| Bespoke/personal app or private fork | belongs in local config, not the hub (#625, #1635, #1870) |
| Source IP from an untrusted header (`X-Forwarded-For` with no trusted-proxy logic) | spoofable → anyone can get any IP banned; and breaks without a proxy (#738, #1909) |
| Whitelists covering huge ranges (all of AWS/Azure/GitHub) | whitelists attackers on those clouds (#834, #1465) |
| Scenarios likely to fire on legit traffic in a default collection | e.g. xmlrpc bf kept out of the wordpress collection (#245); CVE paths used legitimately (#406) |
| Cosmetic churn (whitespace) on popular items | every engine re-downloads and restarts for nothing (#1418) |
| Unrelated file changes in the PR | `Unrelated changes` on README/workflows/taxonomy (#1798) |
| Mixed-purpose PRs | split one service per PR (#713) |

## Workflow

1. Search the hub first (`cscli hub search`, `grep -r` in the repo, open PRs) — extend before adding.
2. Get **real, anonymized log lines** for every format you support (success *and* failure lines).
3. Write the item(s) + same-name `.md`.
4. Create tests with `cscli hubtest create`, run them, commit the generated asserts
   ([testing.md](./testing.md)). Run with `TZ=UTC` (CI is UTC).
5. Self-review with [review-checklist.md](./review-checklist.md).
6. Open the PR on `master` from a feature branch (not your fork's master, #1185).
   Fill the PR template checklist **honestly**, including the "AI was used" box —
   generated content without tests is closed; reviewers check AI-looking PRs harder (#1606, #1676).

## CI gates on a PR

| Job | What fails it |
|---|---|
| HubTest (`test_configurations.yaml`) | any `cscli hubtest run --all` failure, on crowdsec master |
| Lint Index (`lint-index.yml`) | `hublint`: missing `author`/path/file, author≠key, `debug: true`, dependency that doesn't exist, non-collection declaring dependencies, unnamed scenario doc |
| Schema validation (`validate.yml`) | YAML not matching `crowdsec-yaml-schemas` (parser/scenario/postoverflow/collection) |
| Update Taxonomy (`update_taxonomy.yaml`) | scenario labels: missing `labels`/`behavior`/`spoofable`/`confidence`(int 0-3)/`label`, bad MITRE/CVE/CWE format, unknown `intent` (comments on the PR) |
| AppSec (`test_appsec_rules`, `waf-check`, `appsec_vpatch_lint`) | see [appsec-rules.md](./appsec-rules.md) |

Fork PRs need a maintainer to approve workflow runs (`action_required`) before CI executes.

## Hard don'ts

- `debug: true` committed (lint error; reviewers flag it every time — comment it out).
- YAML anchors (`&x` / `<<: *x`) — write values out (#1474, docs).
- Grok-parsing JSON — use `UnmarshalJSON` ([parsers.md](./parsers.md)).
- Public/WAN IPs in test logs — use private/documentation ranges ([testing.md](./testing.md)).
- Committing `.tests/*/results/` or `runtime/` (#374).
