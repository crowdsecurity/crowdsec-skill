# Privacy Policy

**Plugin:** `crowdsec` (CrowdSec skills for Claude Code)
**Maintainer:** CrowdSec — <https://github.com/crowdsecurity>
**Last updated:** 2026-06-11

## Summary

This plugin collects no personal data. It is a set of documentation skills and
helper scripts that run **locally** inside Claude Code on your machine. It does not transmit 
data CrowdSec or any third party on its own.

## What the plugin is

The plugin ships Markdown reference documentation and a small number of
stdlib-only helper scripts (e.g. report generation and diagnostics). Nothing in
the plugin runs in the background, and it has no server-side component. The
maintainer never receives any data as a result of you installing or using it.

## Third-party services (acting on the skill's guidance)

The plugin's purpose is to help you operate **your own** CrowdSec deployment.
When you follow its guidance — or run its helper scripts — Claude Code or those
scripts may contact CrowdSec services **using credentials you supply**, for
example:

- Your CrowdSec **engine** (Local API) and the bouncers attached to it.
- The CrowdSec **Central API (CAPI)** and the **Hub**, for community blocklists
  and hub content.
- The CrowdSec **Service API (SAPI)** at `admin.api.crowdsec.net`, authenticated
  with your organisation's `x-api-key`.
- The CrowdSec **Console** at `app.crowdsec.net`, for enrollment.

These communications are between **your environment and CrowdSec's services**,
initiated by you, using your own credentials. They are governed by CrowdSec's
product Terms and Privacy Policy — see <https://www.crowdsec.net/privacy-policy>
— not by this plugin.

## Changes to this policy

If this policy changes, the updated version will be published in this repository
with a new "Last updated" date.

## Contact

Questions about this policy: open an issue at
<https://github.com/crowdsecurity/crowdsec-skill/issues>.
