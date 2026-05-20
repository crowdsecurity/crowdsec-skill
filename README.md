<div align="center">

<img src="https://raw.githubusercontent.com/crowdsecurity/crowdsec-docs/main/crowdsec-docs/static/img/crowdsec_logo.png" alt="CrowdSec" width="280">

# CrowdSec skill for Claude Code

**Install, configure, operate, and debug [CrowdSec](https://www.crowdsec.net) — straight from your terminal, with Claude doing the heavy lifting.**

[![Version](https://img.shields.io/badge/version-0.1.0-blue)](.claude-plugin/plugin.json)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Claude Code skill](https://img.shields.io/badge/Claude%20Code-skill-8A2BE2)](https://docs.claude.com/en/docs/claude-code/skills)
[![CrowdSec](https://img.shields.io/badge/CrowdSec-docs-orange)](https://docs.crowdsec.net)

</div>

---

This is an [Agent Skill](https://docs.claude.com/en/docs/claude-code/skills) that turns Claude Code into a
hands-on CrowdSec operator. Ask it to stand up an engine, wire a bouncer, enable
the WAF, or figure out why nothing's getting blocked — it knows the `cscli`
commands, the config layout, the failure modes, and the safe way through each of
them across **bare-metal/systemd, Docker, and Kubernetes/Helm**.


## What it covers

| Area | Covered |
|---|---|
| **Install** | bare-metal/systemd · Docker · Kubernetes/Helm · Console enrollment |
| **Bouncers** | firewall (iptables/nftables/ipset) · nginx · traefik · caddy · apache · and more |
| **WAF / AppSec** | deploy · configure · troubleshoot the AppSec component |
| **Hub** | install collections/parsers/scenarios · update · debug |
| **Configure** | acquisition · profiles & ban durations · notifications · allowlists |
| **Operate** | health checks & smoke tests · upgrades & rollback · multi-server / remote LAPI / mTLS |
| **Debug** | logs not parsing · no alerts firing · bouncer not blocking · specific errors |
| **Migrate** | fail2ban → CrowdSec |

## 🚀 Install

The skill loads automatically once installed — no flags, no setup. Just talk to
Claude about CrowdSec.

**From the CrowdSec marketplace (available now):**

```text
/plugin marketplace add crowdsecurity/crowdsec-skill
/plugin install crowdsec@crowdsecurity
```

Update later with:

```text
/plugin marketplace update crowdsecurity
```

**From the Anthropic community marketplace** _(once published)_:

```text
/plugin install crowdsec@claude-community
```

## 💬 Example prompts

Once installed, Claude picks the skill up whenever your prompt involves CrowdSec:

- _"Install CrowdSec on this server and set up the nginx bouncer."_
- _"Deploy CrowdSec in my Kubernetes cluster and enroll it in the Console."_
- _"Enable the WAF / AppSec on my server."_
- _"CrowdSec doesn't detect attacks on my nginx server, why?"_
- _"There's a decision for this IP but it's not being blocked."_
- _"Migrate my fail2ban jails to CrowdSec."_

## 🚫 What it does **not** do

This is an **operational** skill. It deploys, configures, and debugs CrowdSec —
it does **not author** detection content. Writing a parser, scenario, or WAF
(AppSec) rule is out of scope.

For authoring, head to the [CrowdSec Hub](https://hub.crowdsec.net) and the
[detection-engineering docs](https://docs.crowdsec.net/docs/next/local_api/intro).

## 📂 What's inside

```
crowdsec-skill/
├── .claude-plugin/         # marketplace + plugin manifests
├── crowdsec/
│   ├── SKILL.md            # skill entry point (auto-loaded by Claude Code)
│   ├── references/         # ~25 topic-specific reference docs
│   │   ├── install/        #   bare-metal · docker · kubernetes · console
│   │   ├── configure/      #   acquisition · hub · profiles · notifications · allowlists · bouncers
│   │   ├── appsec/         #   WAF overview · deploy · configure · troubleshoot
│   │   ├── operate/        #   health-check · upgrades · multi-server
│   │   ├── debug/          #   triage · parsing · no-alerts · bouncer-not-blocking · common-errors
│   │   └── migrate/        #   from-fail2ban
│   └── scripts/
│       └── diagnose.sh     # first-look triage; wraps `cscli support dump`
├── CHANGELOG.md
└── LICENSE
```

`diagnose.sh` is the go-to first move for any "it's broken" prompt — it collects
a support dump (auto-detecting systemd / Docker / Kubernetes) and a curated
report Claude can read.

## 🤝 Contributing

Issues and PRs welcome. Improvements to the reference docs, new environment
coverage, and sharper debug playbooks are especially appreciated. Run
`claude plugin validate .` before opening a PR.

## 🔗 Links

- CrowdSec: <https://www.crowdsec.net>
- Documentation: <https://docs.crowdsec.net>
- Hub: <https://hub.crowdsec.net>
- Console: <https://app.crowdsec.net>

## 📄 License

MIT — see [LICENSE](LICENSE).
