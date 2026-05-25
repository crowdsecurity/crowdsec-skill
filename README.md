<div align="center">

<img src="https://raw.githubusercontent.com/crowdsecurity/crowdsec-docs/main/crowdsec-docs/static/img/crowdsec_logo.png" alt="CrowdSec" width="280">

# CrowdSec skill for Claude Code

**Install, configure, operate, and debug [CrowdSec](https://doc.crowdsec.net) — straight from your terminal, with Claude doing the heavy lifting.**

[![Version](https://img.shields.io/badge/version-0.2.1-blue)](.claude-plugin/plugin.json)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Claude Code skill](https://img.shields.io/badge/Claude%20Code-skill-8A2BE2)](https://docs.claude.com/en/docs/claude-code/skills)
[![CrowdSec](https://img.shields.io/badge/CrowdSec-docs-orange)](https://docs.crowdsec.net)

</div>

---

This is an [Agent Skill](https://docs.claude.com/en/docs/claude-code/skills) that turns Claude/Codex/... into a
hands-on CrowdSec operator. Ask it to stand up an engine, wire a bouncer, enable
the WAF, or figure out why nothing's getting blocked — it knows the `cscli`
commands, the config layout, the failure modes, and the safe way through each of
them across **bare-metal/systemd, Docker, OpnSense and Kubernetes/Helm**.


## What it covers

| Area | Covered |
|---|---|
| **Install** | bare-metal/systemd · Docker · Kubernetes/Helm · OpnSense · Console enrollment |
| **Bouncers** | firewall (iptables/nftables/ipset) · nginx · traefik · caddy · apache · and more |
| **WAF / AppSec** | deploy · configure · troubleshoot the AppSec component |
| **Hub** | install collections/parsers/scenarios · update · debug |
| **Configure** | acquisition · profiles & ban durations · notifications · allowlists |
| **Operate** | health checks & smoke tests · upgrades & rollback · multi-server / remote LAPI / mTLS |
| **Debug** | logs not parsing · no alerts firing · bouncer not blocking · specific errors |

## 🚀 Install

The skill loads automatically once installed. Just talk to
Claude about CrowdSec.

**On Claude**

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

## 💬 Example prompts

Once installed, Claude picks the skill up whenever your prompt involves CrowdSec:

- _"Install CrowdSec on this server and set up the nginx bouncer."_
- _"Deploy CrowdSec in my Kubernetes cluster and enroll it in the Console."_
- _"Enable the WAF / AppSec on my server."_
- _"CrowdSec doesn't detect attacks on my nginx server, why?"_
- _"There's a decision for this IP but it's not being blocked."_
- _"Migrate my fail2ban jails to CrowdSec."_

## What it does **not** do

This is an **operational** skill. It deploys, configures, and debugs CrowdSec —
it does **not author** detection content. Writing a parser, scenario, or WAF
(AppSec) rule is out of scope.

For authoring, head to the [CrowdSec Hub](https://hub.crowdsec.net) and the
[detection-engineering docs](https://docs.crowdsec.net/docs/next/local_api/intro).

## 🤝 Contributing

Issues and PRs welcome. Improvements to the reference docs and new environment
coverage are appreciated. If you see anything missing or wrong, don't hesitate to open a PR.

## 🔗 Links

- CrowdSec: <https://www.crowdsec.net>
- Documentation: <https://docs.crowdsec.net>
- Hub: <https://hub.crowdsec.net>
- Console: <https://app.crowdsec.net>

## 📄 License

MIT — see [LICENSE](LICENSE).
