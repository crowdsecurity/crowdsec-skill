---
name: crowdsec-hub-authoring
description: Use when writing, testing, or reviewing CrowdSec hub items for crowdsecurity/hub — parsers (s00/s01/s02), scenarios, parser whitelists and postoverflows, collections, contexts, AppSec (WAF) rules and virtual patches, their same-name .md docs, and cscli hubtest tests (.tests/, .appsec-tests/, parser.assert, scenario.assert). Also use to contribute a hub PR or review one (hub conventions, naming, labels/taxonomy, CI gates, why PRs get rejected). Complements the operational `crowdsec` skill, which covers installing and running CrowdSec.
---

# CrowdSec hub authoring

Writing and reviewing items for [crowdsecurity/hub](https://github.com/crowdsecurity/hub).
Distilled from the CrowdSec docs, the hub's CI and lint code, and maintainer
review comments on ~1500 merged/closed hub PRs.

Every `#N` in this skill and its references is a **crowdsecurity/hub** pull request
(`gh pr view N --repo crowdsecurity/hub`), cited as the evidence for a rule.

For installing, configuring or debugging a running CrowdSec, use the `crowdsec` skill.

## Route by task

| Task / cue | Read |
|---|---|
| "contribute to the hub", "open a hub PR", repo layout, naming, what gets rejected, CI | [references/overview.md](./references/overview.md) |
| "write a parser", "new log format", grok, `UnmarshalJSON`, `source_ip`, timestamps | [references/parsers.md](./references/parsers.md) |
| "write a scenario", `capacity` / `leakspeed` / `blackhole`, labels, behavior, MITRE | [references/scenarios.md](./references/scenarios.md) |
| "false positive in app X — fix it in the hub", app whitelist, postoverflow | [references/whitelists-postoverflows.md](./references/whitelists-postoverflows.md) |
| collection, context, item `.md`, acquisition example | [references/collections-and-docs.md](./references/collections-and-docs.md) |
| `cscli hubtest`, asserts, test fails in CI, running tests without root | [references/testing.md](./references/testing.md) |
| WAF rule, `vpatch-CVE-…`, nuclei test | [references/appsec-rules.md](./references/appsec-rules.md) |
| "review PR #N", self-review before opening a PR | [references/review-checklist.md](./references/review-checklist.md) |

## Non-negotiables

- Search the hub and open PRs first — extend an existing parser/scenario rather than adding a second one.
- Author dir = name prefix = `author:`; never the `crowdsecurity/` namespace for external items; items can't be renamed.
- Parsers: `filter` on `evt.Parsed.program`, `apply_on: message`, real peer as `source_ip`, anchored patterns around client-controlled text.
- Every item has tests (generated asserts, private IPs, scenario tests that actually overflow) and a same-name `.md`.
- No `debug: true`, no YAML anchors, no `.index.json` / version bumps (CI does it).
- Prove review findings with `cscli hubtest` or `cscli explain` on a crafted line before reporting them.
