# CLAUDE.md

Conventions for authoring this skill. This governs how skill content is **written** and
**validated**.

# General rules

Never open responses with filler phrases like "Great question!", "Of course!", "Certainly!", or similar warmups. Start every response with the actual answer. No preamble, no acknowledgment of the question.

Match response length to task complexity. Simple questions get direct, short answers. Complex tasks get full, detailed responses. Never pad responses with restatements of the question or closing sentences that repeat what you just said.

Before any significant task, show me 2-3 ways you could approach this work. Wait for me to choose before proceeding.

If you are uncertain about any fact, statistic, date, or piece of technical information: say so explicitly before including it. Never fill gaps in your knowledge with plausible-sounding information. When in doubt, say so.


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

## Content structure

The plugin ships **two skills** under `skills/`: `crowdsec` (operational — local
engine/cscli/bouncers/WAF) and `crowdsec-service-api` (the premium Console cloud REST API). Each has
its own router `SKILL.md` and `references/`. The layout below describes the `crowdsec` skill; the
`crowdsec-service-api` layout follows in its own subsection.

### `crowdsec` skill layout

`SKILL.md` is the router — a symptom/intent-indexed table that points into `references/`.
All depth lives in `references/<area>/`, organized by the axis that fits the area:

| Dir | Organized by | Notes |
|---|---|---|
| `install/` | **platform** (one file each) | `bare-metal.md` (apt/dnf + systemd), `docker.md`, `kubernetes.md`, `console.md` (enrollment) — install mechanics genuinely diverge per platform. |
| `configure/` | **config domain** | `acquisition`, `hub`, `profiles`, `notifications`, `allowlists`; platforms merged inline. `configure/bouncers/` nests one level by **service type** (`firewall`, `web-servers`). |
| `operate/` | **task** | `health-check`, `upgrades`, `multi-server`. |
| `appsec/` | **lifecycle** | `overview` → `deploy` → `configure` → `troubleshoot` (the WAF/AppSec feature silo). |
| `debug/` | **kind** | `common/` (`triage`, `errors`, `platform-gotchas`) + `symptoms/` (`parsing`, `no-alerts`, `not-blocked`). Feature troubleshooting is *routed to* the feature's own dir (e.g. AppSec → `appsec/troubleshoot.md`), not duplicated under debug/. |
| `migrate/` | **source product** | `from-fail2ban`. |
| `scripts/` | — | helper scripts (`diagnose.sh`, `check-verification.py`); stdlib/bash only, runnable in static checks. |

**Split files vs inline the prefix.** When deciding whether a platform variant gets its own file:

- **Split into separate files** only when the *content itself* diverges — package managers, file
  paths, install/upgrade mechanics. `install/` is the canonical case.
- **Keep one file with inline command-prefix notes** when the task is identical and only the
  invocation differs (`sudo cscli …` → `docker exec <name> …` → `kubectl exec -n <ns> <pod> -- …`).
  This is the default across `configure/`, `operate/`, `appsec/`, and `debug/`.
- **Genuinely platform-specific *failure modes*** (not just prefixes — e.g. container mounts,
  SELinux/AppArmor, k8s RBAC) collect in one place (`debug/common/platform-gotchas.md`) rather than
  fragmenting a single symptom across per-platform files.

**Keep this current.** When you add, move, or remove a `references/` directory — or change an
area's organizing axis — update the table above in the *same* change. This section is the
authoritative map of the layout; let it drift and it stops being trustworthy.

### `crowdsec-service-api` skill layout

`SKILL.md` is the router **plus** the "acting on the user's behalf" operating contract (key
resolution, `/info` validation, read-vs-mutate confirm gate). `references/` is organized by **API
resource group** — the axis that fits a REST API — one file each:

| File | Covers |
|---|---|
| `authentication.md` | Key creation, `x-api-key`, key resolution (env → `~/.config/crowdsec/sapi_key`), `/info`, Python SDK pointer. |
| `blocklists.md` | CRUD, add/remove/bulk IPs + expiration, download, subscribers, shares, search. |
| `allowlists.md` | CRUD, items + expiration, subscribers (cross-links the `crowdsec` skill's *local* allowlists). |
| `integrations.md` | Firewall/appliance feeds: create (entity_type/output_format), Basic-auth content pull + pagination, decisions stream, vendor table. |
| `decisions.md` | Org-level decisions + aggregated (short; prefer blocklists). |
| `metrics.md` | `/metrics/remediation` ROI (raw vs computed). |

CTI (the tracker surface — cves/vendors/fingerprints/tags/products/tracker-*) is **deferred to a
future iteration**: it needs a CTI-scoped key (a blocklist/decision key gets `403`). When added,
restore a `cti.md` row here.

Conventions differ from the `crowdsec` skill in two ways: **no platform axis** (the "environment" is
HTTPS, not systemd/docker/k8s — so no per-platform prefixes), and recipes are `curl` the skill runs
on the user's behalf, every mutating one gated behind explicit confirmation. Verification uses
`env: sapi` in the `verified:` block. When you add/rename a resource file here, update this table in
the same change.

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


