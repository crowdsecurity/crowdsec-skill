# Publishing & releasing the CrowdSec skill

This is the runbook for cutting releases and distributing the skill across
marketplaces. The source of truth is this repo (`crowdsecurity/crowdsec-skill`);
the same plugin can be listed in several marketplaces with no conflict because
each uses a distinct namespace (`@crowdsecurity`, `@claude-community`).

## Releasing a new version

Versioning is **semver at the plugin level** (`SKILL.md` has no version field).
The version lives in `.claude-plugin/plugin.json` and is mirrored into
`.claude-plugin/marketplace.json` and `CHANGELOG.md`.

You don't edit those JSON files by hand. The release flow is:

1. Make sure everything you want to ship is on `main` and the `[Unreleased]`
   section of `CHANGELOG.md` lists the changes.
2. **Publish a GitHub Release** with a tag like `v0.2.0` (semver, leading `v`).
3. The [`release.yml`](.github/workflows/release.yml) workflow then:
   - writes `0.2.0` into `plugin.json` and the `marketplace.json` entry,
   - moves `[Unreleased]` notes under a dated `[0.2.0]` heading and refreshes the
     compare links,
   - runs `claude plugin validate .` as a gate,
   - commits the bumped files back to `main`.

**Bump rules:** patch = doc/reference fixes · minor = new coverage area or
script · major = breaking change to scope or structure.

Every PR is also checked by [`validate.yml`](.github/workflows/validate.yml),
which runs `claude plugin validate .` and fails if `plugin.json` and
`marketplace.json` versions have drifted apart.

## Pre-flight checklist (before any publication)

- `claude plugin validate .` passes locally.
- Repo is **public**; `README.md` and `LICENSE` are present.
- `crowdsec/SKILL.md` frontmatter `name`/`description` are accurate.
- `CHANGELOG.md` references only files that exist.

## A. CrowdSec marketplace (live now)

This repo is the official CrowdSec marketplace: it contains
`.claude-plugin/marketplace.json` (`name: crowdsecurity`) with the plugin served
from `"source": "./"`, so users can install today:

```text
/plugin marketplace add crowdsecurity/crowdsec-skill
/plugin install crowdsec@crowdsecurity
```

## B. Anthropic community marketplace

The public, Anthropic-curated catalog (`anthropics/claude-plugins-community`).

1. Submit via <https://platform.claude.com/plugins/submit> (form).
2. Submission goes through automated validation + safety screening.
3. On approval the plugin is **pinned to a commit SHA** in the community catalog;
   CI bumps the pin as you push new commits, and the public catalog syncs nightly.
4. Users install as `crowdsec@claude-community`.

Requirements: public repo, README + LICENSE present, `claude plugin validate`
clean (it runs the same checks Anthropic's pipeline does).

## C. skills.sh (exploratory — verify first)

`skills.sh` is a **third-party** community directory, not part of Anthropic's
official tooling. Before advertising it in the README, confirm:

- whether it indexes plugins or raw `SKILL.md` skills,
- its submission flow (PR vs web form vs auto-crawl of public repos),
- any manifest/format it expects.

Do **not** add a skills.sh install line to the README until the flow is confirmed.

## Keeping one source of truth

- Code stays in one repo; bump semver there once per release.
- The community catalog pins SHAs (CI-managed); self-hosted marketplaces track
  the same source repo.
- Never set the version in both `plugin.json` and `marketplace.json` to different
  values — `plugin.json` wins silently. The release workflow keeps them equal.
