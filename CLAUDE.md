# CLAUDE.md

Conventions for authoring this skill. This governs how skill content is **written** and
**validated**.

## Writing style

- **Be concise.** Technical documentation, not an essay. Favor tables, command recipes, and short
  imperative sentences. Cut throat-clearing, restated context, and filler.
- **Write only the final, correct information.** Never record self-corrections, dead ends, or
  "actually, it turned out…" narration discovered while authoring. The reader gets the conclusion,
  not the journey. This applies equally to inline expected-output hints: state the correct
  outcome, never the wrong-then-fixed version. Do not annotate verification *inline in prose* (no
  "(verified)", "Verified on…", "verified gotcha"). Record verification in the per-file `verified:`
  frontmatter block instead — see **Verification tracking** below.
- **Keep `SKILL.md` a router.** It is an index and decision layer that points to `references/`.
  Depth and recipes belong in the reference docs, not in `SKILL.md`.
- **Cover every environment.** Each command or recipe carries its systemd / docker / k8s variant,
  matching the existing convention. If some command or recipe is irrelevant to some variant it should be noted.
- **Anchor to canonical docs.** Each reference doc cites the upstream CrowdSec docs URL it derives
  from. Claims trace to canonical documentation, not to memory.

## Testing

- **Nothing ships unverified.** Every command and every expected outcome must have been
  run against a real, current CrowdSec environment and observed first-hand — not inferred, not
  recalled, not invented.
- **Use a dedicated test environment.** Behavioral validation requires a real environment where the
  agent can run commands and observe results. Each contributor supplies their own.
- **The local working copy is for static checks only** — lint, `claude plugin validate .`, and
  structural review. Run commands that change or inspect a CrowdSec install on the test environment,
  never against the authoring machine.
- **If you cannot verify something, mark it `untested` or leave it out.** Never present unconfirmed
  behavior as confirmed.
- **Avoid duplicates** by checking in the existing skill documentation if the information is already present. If it is, ensure it's properly linked/routed, but don't duplicate instruction, code blocks or configurations.

## Verification tracking

Verification is recorded **per reference doc**, in a `verified:` YAML frontmatter block, so freshness
is queryable and drift is visible. A doc with no `verified:` block has never been confirmed against a
real environment.

```yaml
---
verified:
  - date: 2026-05-22      # ISO 8601 (YYYY-MM-DD); the day the recipes were run
    version: "1.6.5"      # CrowdSec engine version, from `cscli version`
    env: docker           # systemd | docker | k8s (free-form allowed, e.g. opnsense)
    notes: "deploy + reload path only"   # optional, short scope note
---
```

Rules:

- **One entry per env.** Re-verifying the same env updates that entry in place (bump `date` and
  `version`); verifying a new env appends a new entry. This keeps "cover every environment"
  auditable.
- **Stamp it when you verify it.** When you run a doc's commands against the real test environment
  (see Testing) and observe them work, add or update that doc's `verified:` entry in the same change:
  `date` = today, `version` = the output of `cscli version`, `env` = the detected environment. The
  record and the verification happen together — never stamp from memory or inference.
- Use ISO 8601 dates so the checker can sort and age them.
- Don't pre-seed unverified docs with empty blocks; absence *is* the "never verified" signal.

`skills/crowdsec/scripts/check-verification.py` (stdlib-only, safe to run locally) reports coverage,
lists docs with no block, flags entries older than 180 days, and fails on a malformed block.


