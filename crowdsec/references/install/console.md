# Install — Console enrollment

Canonical docs: <https://docs.crowdsec.net/docs/next/getting_started/post_installation/console> · Console app: <https://app.crowdsec.net>

The Console is the SaaS view on top of CAPI: dashboards, multi-engine overview,
managed blocklists, and **centralized allowlists pushed to every enrolled
engine**. Enrollment is of the **engine/LAPI** — bouncers are not enrolled
separately; they appear in the Console *through* their LAPI.

## 1 — Enroll the engine

Get an enrollment key from <https://app.crowdsec.net> (Security Engines → Enroll),
then on the engine:

```bash
sudo cscli console enroll YOUR-ENROLL-KEY
sudo systemctl reload crowdsec        # required for it to take effect
```

**Enrollment is two-step**: this command registers the engine, then you must
**accept the instance in the Console webapp** — until you click Accept it stays
pending and no data flows. This is the #1 "I enrolled but nothing shows up".

Useful flags (from `cscli console enroll --help`):

| Flag | Use |
|---|---|
| `--name <instance_name>` | Label this engine in the Console (default is the machine ID — set this on multi-engine fleets). |
| `--tags <t> --tags <t>` | Group/filter engines in the Console. |
| `--enable <opt>` / `--disable <opt>` | Set sharing options at enroll time (see options below). |
| `--overwrite` | Re-enroll an already-enrolled engine (e.g. moving it to another Console org). |
| `--quick` | Non-interactive enroll. |

Enrolling requires a working **CAPI registration** — the Console rides on CAPI.
If `online_api_credentials.yaml` is missing, `cscli capi register` then reload
*before* enrolling.

## 2 — Console options (the part users get wrong)

`cscli console status` shows five toggles. Default state on a fresh
enrolled engine:

| Option | Default | What it does |
|---|---|---|
| `custom` | ✅ on | Forward alerts from your custom scenarios |
| `tainted` | ✅ on | Forward alerts from tainted (locally modified) scenarios |
| `manual` | ❌ off | Forward your manual `cscli decisions add` |
| `context` | ❌ off | Forward alert context (richer detail, more data) |
| `console_management` | ❌ **off** | **Receive** decisions/allowlists *from* the Console |

The trap: **`console_management` is off by default**. Centralized blocklists and
**Console-managed allowlists only push down to the engine once it is enabled**:

```bash
sudo cscli console enable console_management
sudo systemctl reload crowdsec
```

These map to `share_*` keys in `/etc/crowdsec/console.yaml`
(`share_custom: true`, `share_tainted: true`, `share_manual_decisions: false`,
`share_context: false`) — but use `cscli console enable/disable <opt>`, not hand
edits. `all` is a valid target (`cscli console enable all`).

## 3 — Verify enrollment

```bash
sudo cscli console status     # the five toggles above
sudo cscli capi status        # connectivity — expect:
                              #   "Sharing signals is enabled"
                              #   "Pulling community blocklist is enabled"
                              #   "Pulling blocklists from the console is enabled"
```

`cscli capi status` is the **connectivity/enrollment** check (it authenticates
to `api.crowdsec.net`); `cscli console status` is the **feature-flag** check.
You usually want both. Then confirm the instance shows (and is Accepted) in the
Console webapp.

If you enabled `console_management`, confirm allowlists actually sync: add one
in the Console UI, then within a poll cycle:

```bash
sudo cscli allowlists list    # Console-pushed entries show "Managed by Console: true"
```

See [../configure/allowlists.md](../configure/allowlists.md) for the
local-vs-Console allowlist distinction.

## Per-environment notes

| Env | Enroll via |
|---|---|
| systemd / bare-metal | `sudo cscli console enroll …` then `systemctl reload crowdsec` |
| Docker | `ENROLL_KEY` (and `ENROLL_INSTANCE_NAME`/`ENROLL_TAGS`) env vars on the crowdsec container, **or** `docker exec crowdsec cscli console enroll …` then restart the container |
| Kubernetes | `config.console.enroll_key` (and name/tags) in the Helm chart values; the LAPI pod enrolls on start |

## Pitfalls

- **Forgot to Accept in the webapp** → enrolled but no data. Always finish step 1
  in the UI.
- **Token reuse across engines** without `--name` → every engine collides under
  the machine-ID default and they're indistinguishable in the Console. Set
  `--name` per engine.
- **Egress**: the engine must reach `api.crowdsec.net` (HTTPS). Behind a proxy,
  set the proxy env for the crowdsec service; behind egress filtering, allow
  that host. `cscli capi status` failing right after enroll is almost always
  egress or **clock skew** (TLS) — check `timedatectl`.
- **Expecting blocklists without `console_management`** → see §2; it's off by
  default.
- **Bouncer "enrollment"**: there is no separate bouncer enroll command;
  register bouncers normally with `cscli bouncers add` and they surface in the
  Console via the enrolled LAPI.

## Next step

Confirm detection + sharing end-to-end with
[../operate/health-check.md](../operate/health-check.md) — a triggered test
alert should appear in `cscli alerts list` *and* in the Console within a minute.
