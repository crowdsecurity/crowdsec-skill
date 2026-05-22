#!/usr/bin/env python3
"""Report verification coverage across the CrowdSec skill's reference docs.

A reference doc records when its recipes were last exercised against a real
environment in a YAML `verified:` frontmatter block (see CLAUDE.md §
"Verification tracking"). This static checker — stdlib only, safe to run on the
local working copy — walks the docs and reports:

  * a coverage table (doc · last-verified date · version · env · age in days),
  * docs with no `verified:` block (coverage gaps),
  * entries older than the staleness threshold (default 180 days).

It exits non-zero only when a present `verified:` block is malformed, so it can
run as a non-blocking CI report while backfill is still in progress.
"""

from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

# skills/crowdsec/scripts/check-verification.py -> skills/crowdsec
SKILL_ROOT = Path(__file__).resolve().parent.parent
REFERENCES = SKILL_ROOT / "references"
SKILL_MD = SKILL_ROOT / "SKILL.md"

CANONICAL_ENVS = {"systemd", "docker", "k8s"}
REQUIRED_KEYS = ("date", "version", "env")
OPTIONAL_KEYS = ("notes",)
ALLOWED_KEYS = set(REQUIRED_KEYS) | set(OPTIONAL_KEYS)


class SchemaError(Exception):
    """A present `verified:` block does not match the expected schema."""


def split_frontmatter(text: str) -> str | None:
    """Return the YAML frontmatter body, or None if the file has no frontmatter.

    Frontmatter is the block between a leading `---` line and the next `---`.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i])
    raise SchemaError("frontmatter opened with '---' but never closed")


def parse_verified(frontmatter: str) -> list[dict] | None:
    """Parse the `verified:` list out of a frontmatter body.

    Targeted parser for the documented schema (a top-level `verified:` key whose
    value is a list of flat mappings) — avoids a PyYAML dependency. Returns None
    if there is no `verified:` key, or a list of entry dicts otherwise.
    """
    lines = frontmatter.splitlines()
    start = None
    for idx, line in enumerate(lines):
        if line.rstrip() == "verified:" or line.rstrip() == "verified: []":
            if line.rstrip().endswith("[]"):
                return []
            start = idx + 1
            break
    if start is None:
        return None

    entries: list[dict] = []
    current: dict | None = None
    for raw in lines[start:]:
        if raw.strip() == "":
            continue
        # A new top-level key (no leading space) ends the verified block.
        if not raw.startswith(" ") and not raw.startswith("\t"):
            break
        stripped = raw.strip()
        if stripped.startswith("- "):
            current = {}
            entries.append(current)
            stripped = stripped[2:].strip()
            if not stripped:
                continue
        if current is None:
            raise SchemaError("verified entry data found before any '-' list item")
        if ":" not in stripped:
            raise SchemaError(f"malformed line in verified entry: {raw!r}")
        key, _, value = stripped.partition(":")
        current[key.strip()] = value.strip().strip('"').strip("'")
    return entries


def validate_entry(entry: dict, doc: Path) -> dt.date:
    """Validate one verified entry; return its parsed date."""
    unknown = set(entry) - ALLOWED_KEYS
    if unknown:
        raise SchemaError(f"unknown key(s) {sorted(unknown)} in a verified entry")
    missing = [k for k in REQUIRED_KEYS if not entry.get(k)]
    if missing:
        raise SchemaError(f"verified entry missing required key(s): {missing}")
    try:
        return dt.date.fromisoformat(entry["date"])
    except ValueError as exc:
        raise SchemaError(f"date {entry['date']!r} is not ISO 8601 (YYYY-MM-DD)") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--stale-days",
        type=int,
        default=180,
        help="flag verified entries older than this many days (default: 180)",
    )
    args = parser.parse_args()

    today = dt.date.today()
    docs = sorted(REFERENCES.rglob("*.md"))
    if SKILL_MD.exists():
        docs.append(SKILL_MD)
    if not docs:
        print(f"No reference docs found under {REFERENCES}", file=sys.stderr)
        return 1

    rows: list[tuple[str, str, str, str, str]] = []
    gaps: list[str] = []
    stale: list[str] = []
    errors: list[str] = []

    for doc in docs:
        rel = doc.relative_to(SKILL_ROOT).as_posix()
        try:
            frontmatter = split_frontmatter(doc.read_text(encoding="utf-8"))
            entries = parse_verified(frontmatter) if frontmatter is not None else None
        except SchemaError as exc:
            errors.append(f"{rel}: {exc}")
            continue

        if not entries:
            gaps.append(rel)
            continue

        for entry in entries:
            try:
                date = validate_entry(entry, doc)
            except SchemaError as exc:
                errors.append(f"{rel}: {exc}")
                continue
            age = (today - date).days
            env = entry["env"]
            env_note = "" if env in CANONICAL_ENVS else " (non-canonical env)"
            rows.append((rel, entry["date"], entry["version"], env + env_note, f"{age}d"))
            if age > args.stale_days:
                stale.append(f"{rel} [{env}] verified {entry['date']} ({age}d ago)")

    headers = ("doc", "last verified", "version", "env", "age")
    widths = [len(h) for h in headers]
    for row in rows:
        widths = [max(w, len(c)) for w, c in zip(widths, row)]

    def fmt(cols: tuple[str, ...]) -> str:
        return "  ".join(c.ljust(w) for c, w in zip(cols, widths))

    print("== Verification coverage ==")
    if rows:
        print(fmt(headers))
        print(fmt(tuple("-" * w for w in widths)))
        for row in sorted(rows):
            print(fmt(row))
    else:
        print("(no docs carry a verified: block yet)")

    print(f"\nVerified: {len(rows)} record(s) across {len(docs) - len(gaps) - len(errors)} doc(s)")
    print(f"Coverage gaps (no verified: block): {len(gaps)}")
    for g in gaps:
        print(f"  - {g}")

    if stale:
        print(f"\nStale (> {args.stale_days} days): {len(stale)}")
        for s in stale:
            print(f"  ! {s}")

    if errors:
        print(f"\nMalformed verified: block(s): {len(errors)}", file=sys.stderr)
        for e in errors:
            print(f"  x {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
