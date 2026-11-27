---
verified:
  - date: 2026-11-27
    version: "1.8.2"
    env: hubtest
    notes: "cscli explain --log -v and TZ=UTC hubtest run commands"
---

# Authoring — review checklist

Use it to review a hub PR, or to self-review before opening one. Ordered by how
often each issue blocked a merge in past PRs. Back every finding with a
reproduction (hubtest, `cscli explain`, a crafted log line) — don't assert from reading.

## Before reading the diff

Reasons and precedents: [overview.md](./overview.md).

- [ ] No existing item or open PR for this product (extend / dedupe / pick the oldest PR).
- [ ] Public product, not a personal app/fork.
- [ ] One service per PR, no unrelated files (README, workflows, taxonomy, `.index.json`).
- [ ] PR template checklist present and honest, AI box ticked if relevant.
- [ ] CI state: fork PRs need workflow approval (`action_required`); no conflict with recent merges.

## Naming

- [ ] Author directory = name prefix = `author:`; not `crowdsecurity/` for external authors.
- [ ] Not a rename of an existing item.
- [ ] Named after the application, not the appliance/distro.

## Parser

- [ ] `filter` on `evt.Parsed.program`; `apply_on: message`.
- [ ] Source IP is the real peer, single value, not a client-controlled header; IPv6 handled.
- [ ] Patterns anchored where client text precedes the IP; no over-broad `DATA`/classes.
- [ ] JSON via `UnmarshalJSON` (+ `startsWith "{"`), numbers cast with `int()`.
- [ ] Custom patterns namespaced; no redefinition of built-ins.
- [ ] `log_type` product-specific; `service: http` for web logs; statics reference existing fields.
- [ ] Timestamp captured → `evt.StrTime` (+ `StrTimeFormat` if needed, works on the released engine); no invented TZ.
- [ ] No double-counting of one event; no dead child nodes.
- [ ] `debug` commented out; no anchors.

Prove the risky ones:

```bash
cscli explain --log '<crafted line>' --type <type> -v     # spoofed IP? dropped line?
TZ=UTC cscli hubtest run <tests loading the parser>
```

## Scenario

- [ ] Filter on `log_type` (+ `service` if generic).
- [ ] `capacity`/`leakspeed` sensible (leakspeed = one leak per X); `blackhole` 1m–5m with a `groupby`.
- [ ] Labels complete and taxonomy-valid; `label` wording consistent; correct CVE/MITRE.
- [ ] FP risk on legit traffic; overlap with existing scenarios/tiers.
- [ ] Explanation of thresholds in PR/`.md`.

## Whitelist / postoverflow

- [ ] Method + status + exact anchored path; query string and `..` can't bypass.
- [ ] Positive and negative test lines.
- [ ] No cloud-wide ranges; data files from `sec-lists`.

## Tests

- [ ] Parser and scenario tests split; s00 parser + dateparse-enrich present.
- [ ] Asserts fully regenerated (all stages), no hand edits/comments, no `results/`.
- [ ] Scenario test actually overflows (not `len(results) == 0`), each variant.
- [ ] Private IPs only; real anonymized lines; old format lines kept.
- [ ] Loads the item the PR ships (relative path).
- [ ] A non-zero test value where it matters (e.g. a `+01:00` offset, not only `+00:00`).

## Docs

- [ ] Same-name `.md` for every item; collection `.md` has acquisition examples.
- [ ] No TODOs, hallucinated options or off-topic guides.

## Writing the review

- Keep the posted comment compact: only what is wrong and what to change.
  Run the tests (hubtest, docker, crafted lines) but never describe them in the
  comment — no test setup, IP groups, run results or "I reproduced with…".
- Be specific: the line, the failing input, the exact fix (pattern, field, file to delete).
- Group into **blocking** vs nits; keep nits few and verified — drop speculative ones.
- Prefer suggesting the fix (or pushing it to the contributor's branch when they
  allow maintainer edits) over long back-and-forth; credit the contributor when
  superseding their PR (#1695, #1681).
