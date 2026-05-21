# Changelog

All notable changes to this skill are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `references/configure/acquisition.md` — file/journald/docker datasources, the
  `labels.type` model, verification with `crowdsec -t` / `cscli metrics show acquisition`
  / `cscli explain`, and common pitfalls.
- `references/configure/profiles.md` — alert→decision flow, why alerts don't always ban,
  `profiles.yaml` structure, ban/captcha/throttle, `duration_expr` escalation, simulation
  mode, and allowlist interaction.
- `references/configure/hub.md` — collections vs items, `update` vs `upgrade`, tainted-item
  detection and repair, `_custom/` overrides, and the `sed -i` symlink-break pitfall.
- `references/configure/bouncers/web-servers.md` — full Traefik
  (`maxlerebourg/crowdsec-bouncer-traefik-plugin`) and Caddy
  (`hslatman/caddy-crowdsec-bouncer`) setup, AppSec wiring, and real-client-IP handling,
  replacing the previous canonical-pointer stubs; plus a "Pick your bouncer" section index.
- `references/operate/upgrades.md` — lean per-environment upgrade runbook (backward-compatible
  happy path, independent bouncer cadence), the hub-upgrade-skips-tainted consequence,
  backup-when-it-matters, and a verified rollback note.

### Changed
- `crowdsec/SKILL.md` — dropped the stub markers on acquisition/profiles/hub/upgrades; split
  the single web-servers bouncer row into per-bouncer `§`-section routing rows (also adding
  haproxy/apache cues); added a real-client-IP / reverse-proxy routing cue; and corrected the
  cheat sheet (`cscli profiles list` does not exist; read `/etc/crowdsec/profiles.yaml`).

## [0.1.0] - 2026-05-20

## [0.1.0] - 2026-05-19

### Added
- Initial release of the CrowdSec operational skill for Claude Code.
- `crowdsec/SKILL.md` covering install, configure, operate, and debug flows for
  bare-metal/systemd, Docker, and Kubernetes/Helm.
- Reference docs:
  - `references/install/` — Docker and Kubernetes install notes.
  - `references/operate/` — health check and audit guidance.
  - `references/appsec/` — AppSec/WAF troubleshooting.
  - `references/debug/` — triage and common errors.
- Helper script:
  - `scripts/diagnose.sh` — first-look triage; wraps `cscli support dump`
    (auto-detecting systemd / Docker / Kubernetes) into a curated report.
- Marketplace + plugin manifests under `.claude-plugin/`.

[Unreleased]: https://github.com/crowdsecurity/crowdsec-skill/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/crowdsecurity/crowdsec-skill/compare/v0.1.0...v0.1.0
