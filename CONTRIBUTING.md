# Contributing

Issues and PRs are welcome. Improvements to the reference docs and coverage for new
environments are the most useful contributions.

## Before you open a PR

Authoring conventions for this skill live in [CLAUDE.md](CLAUDE.md) — writing style,
directory layout, version gating, and the `verified:` frontmatter block. Read it before
adding or restructuring a reference doc; it is the authoritative map of where content goes.

The rule that matters most:

> **Nothing ships unverified.** Every command and expected outcome must have been run
> against a real, current CrowdSec environment and observed first-hand — not inferred,
> not recalled. If you cannot verify something, mark it `untested` or leave it out.

Verification is recorded per file in a `verified:` block (date, engine version, environment).
When you run a doc's commands and see them work, stamp it in the same change.

## What CI checks

`.github/workflows/validate.yml` runs on every PR:

| Check | Fails the build? |
|---|---|
| `plugin.json` and `marketplace.json` versions agree | yes |
| `claude plugin validate .` | yes |
| Malformed `verified:` frontmatter | yes |
| Missing or stale (>180 days) verification records | no — informational |

Run the verification report locally with:

```bash
python3 skills/crowdsec/scripts/check-verification.py
```

## Scope

This is an **operational** skill: install, configure, operate, debug. Authoring detection
content — parsers, scenarios, WAF rules — is out of scope and belongs in the
[CrowdSec Hub](https://hub.crowdsec.net).

## Testing changes

The local working copy is for static checks only. Run commands that change or inspect a
CrowdSec install against a dedicated test environment, never against your authoring machine.

## Commits and PRs

- Conventional commits, one-line subject where possible (`fix(console): …`, `docs(readme): …`).
- Keep PR descriptions short — what changed and why, not a narrative.
- Update [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]` in the same change.

## Reporting a problem

Open an issue using one of the [templates](.github/ISSUE_TEMPLATE/). For anything
security-sensitive in CrowdSec itself, follow the
[CrowdSec security policy](https://github.com/crowdsecurity/crowdsec/security/policy)
rather than filing a public issue here.
