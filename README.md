<div align="center">

<img src="https://raw.githubusercontent.com/crowdsecurity/crowdsec-docs/main/crowdsec-docs/static/img/crowdsec_logo.png" alt="CrowdSec" width="280">

# CrowdSec Skill for Claude Code & Codex

**The official CrowdSec plugin for AI coding agents.** It bundles two
[Agent Skills](https://docs.claude.com/en/docs/claude-code/skills) that let Claude Code,
Codex, and Claude.ai install, configure, operate, and debug
[CrowdSec](https://docs.crowdsec.net) — the engine, `cscli`, bouncers, and the WAF/AppSec
component — across bare-metal/systemd, Docker, pfSense/OPNsense, and Kubernetes/Helm.

[![Version](https://img.shields.io/badge/dynamic/json?label=version&query=%24.version&url=https%3A%2F%2Fraw.githubusercontent.com%2Fcrowdsecurity%2Fcrowdsec-skill%2Fmain%2F.claude-plugin%2Fplugin.json&color=blue)](.claude-plugin/plugin.json)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Agent Skills](https://img.shields.io/badge/Agent-Skills-8A2BE2)](https://docs.claude.com/en/docs/claude-code/skills)
[![CrowdSec](https://img.shields.io/badge/CrowdSec-docs-orange)](https://docs.crowdsec.net)

</div>

---

This plugin bundles **two [Agent Skills](https://docs.claude.com/en/docs/claude-code/skills)**:

- **`crowdsec`** — a hands-on CrowdSec operator. Stand up an engine, wire a
  bouncer, enable the WAF, or figure out why nothing's getting blocked. It knows
  the `cscli` commands, the config layout, the failure modes, and the safe way
  through each across **bare-metal/systemd, Docker, pfSense/OPNsense and Kubernetes/Helm**.
- **`crowdsec-service-api`** — drives the premium **Console Service API** (cloud)
  on your behalf with your API key: create and populate blocklists/allowlists,
  wire firewall/appliance integrations, pull remediation ROI metrics, and manage
  org-level decisions — every state change gated behind an explicit confirmation.


## What it covers

**`crowdsec` (operational):**

| Area | Covered |
|---|---|
| **Install** | bare-metal/systemd · Docker · Kubernetes/Helm · pfSense/OPNsense · Console enrollment |
| **Bouncers** | firewall (iptables/nftables/ipset) · nginx · traefik · caddy · apache · and more |
| **WAF / AppSec** | deploy · configure · troubleshoot the AppSec component · bot detection |
| **Hub** | install collections/parsers/scenarios · update · debug |
| **Configure** | acquisition · profiles & ban durations · notifications · allowlists |
| **Operate** | health checks & smoke tests · upgrades & rollback · multi-server / remote LAPI / mTLS |
| **Debug** | logs not parsing · no alerts firing · bouncer not blocking · specific errors |

**`crowdsec-service-api` (premium cloud API):**

| Area | Covered |
|---|---|
| **Blocklists** | create · add/remove/bulk IPs (with expiry) · download · share across orgs · subscribe engines/bouncers |
| **Allowlists** | create · items with expiry · subscribe by engine/tag/org |
| **Integrations** | firewall/appliance feeds (Palo Alto, Fortinet, Cisco, F5, Sophos, pfSense/OPNsense…) · paginated Basic-auth content pull |
| **Metrics** | remediation ROI (traffic dropped, bytes/egress saved, attacks prevented) |
| **Decisions** | org-level decisions + aggregated (read/manage) |

## Install

The skill loads automatically once installed. Just talk to
your agent about CrowdSec.

> **Naming:** the marketplace is `crowdsecurity`, the plugin inside it is `crowdsec`,
> and the plugin ships two skills — `crowdsec` and `crowdsec-service-api`.

**On Claude Code**

```text
/plugin marketplace add crowdsecurity/crowdsec-skill
/plugin install crowdsec@crowdsecurity
```

Update later with:

```text
/plugin marketplace update crowdsecurity
```

**On Codex:** install the skill with:

```text
skill-installer crowdsecurity/crowdsec-skill
```

**On Claude.ai (web)**

Download `crowdsec-skill-vX.Y.Z.zip` from the
[latest release](https://github.com/crowdsecurity/crowdsec-skill/releases/latest)
and upload it in the web skill uploader.

**Or directly with skills.sh**

```bash
npx skills add  crowdsecurity/crowdsec-skill
```

## Example prompts

Once installed, the agent picks the skill up whenever your prompt involves CrowdSec:

- _"Install CrowdSec on this server and set up the nginx bouncer."_
- _"Deploy CrowdSec in my Kubernetes cluster and enroll it in the Console."_
- _"Enable the WAF / AppSec on my server."_
- _"CrowdSec doesn't detect attacks on my nginx server, why?"_
- _"There's a decision for this IP but it's not being blocked."_
- _"Migrate my fail2ban jails to CrowdSec."_
- _"Create a Console blocklist and push these IPs from my SIEM to it."_ (Service API)
- _"Wire a Palo Alto external dynamic list to my CrowdSec blocklist."_ (Service API)
- _"Show me the remediation ROI metrics for last month."_ (Service API)

## What this skill does not do

This is an **operational** skill. It deploys, configures, and debugs CrowdSec —
it does **not author** detection content. Writing a parser, scenario, or WAF
(AppSec) rule is out of scope.

For authoring, head to the [CrowdSec Hub](https://hub.crowdsec.net) and the
[detection-engineering docs](https://docs.crowdsec.net/docs/next/local_api/intro).

## Reference docs

Both skills are backed by 37 reference documents, each verified against a real CrowdSec
environment before it ships:

| Area | Covers |
|---|---|
| [`install/`](skills/crowdsec/references/install/) | bare-metal · Docker · Kubernetes · pfSense · Console enrollment |
| [`configure/`](skills/crowdsec/references/configure/) | acquisition · hub · profiles · notifications · allowlists · [bouncers](skills/crowdsec/references/configure/bouncers/) |
| [`appsec/`](skills/crowdsec/references/appsec/) | WAF deploy · configure · troubleshoot · [bot detection](skills/crowdsec/references/appsec/bot-detection/) |
| [`operate/`](skills/crowdsec/references/operate/) | health checks · upgrades · multi-server |
| [`debug/`](skills/crowdsec/references/debug/) | [common](skills/crowdsec/references/debug/common/) errors & triage · [symptoms](skills/crowdsec/references/debug/symptoms/): parsing, no alerts, not blocked |
| [`migrate/`](skills/crowdsec/references/migrate/) | [from fail2ban](skills/crowdsec/references/migrate/from-fail2ban.md) |
| [Service API](skills/crowdsec-service-api/references/) | authentication · blocklists · allowlists · integrations · metrics · decisions |

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Improvements to the
reference docs and new environment coverage are especially appreciated. If you see
anything missing or wrong, don't hesitate to open a PR.

## Links

- CrowdSec: <https://www.crowdsec.net>
- Documentation: <https://docs.crowdsec.net>
- Hub: <https://hub.crowdsec.net>
- Console: <https://app.crowdsec.net>

## License

MIT — see [LICENSE](LICENSE).
