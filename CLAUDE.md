# CLAUDE.md

Conventions for authoring this skill. This governs how skill content is **written** and
**validated**.

## Writing style

- **Be concise.** Technical documentation, not an essay. Favor tables, command recipes, and short
  imperative sentences. Cut throat-clearing, restated context, and filler.
- **Write only the final, correct information.** Never record self-corrections, dead ends, or
  "actually, it turned out…" narration discovered while authoring. The reader gets the conclusion,
  not the journey. This applies equally to inline expected-output hints: state the correct
  outcome, never the wrong-then-fixed version. Do not annotate content as *verified* (no
  "(verified)", "Verified on…", "verified gotcha") — verification is guaranteed by this file,
  not restated per-doc.
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


