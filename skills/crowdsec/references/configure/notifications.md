---
verified:
  - date: 2026-05-26
    version: "1.7.8"
    env: systemd
    notes: "cscli notifications test/list; http plugin 400 on bad template; render-to-sink via nc+jq (catches missing-comma)"
---

# Configure — Notifications (http/email/slack)

Canonical docs: <https://docs.crowdsec.net/docs/next/local_api/notification_plugins/intro>

Notifications fire when a **profile** matches an alert and routes it to a named
plugin. Two moving parts: the plugin **config** (`/etc/crowdsec/notifications/*.yaml`)
and the **profile** wiring (`/etc/crowdsec/profiles.yaml`). The plugin binaries
live in `/usr/lib/crowdsec/plugins/` (`notification-http`, `-slack`, `-email`,
`-splunk`, `-sentinel`, `-file`).

## Wire a plugin into a profile

A plugin only fires if a profile names it. In `profiles.yaml`:

```yaml
notifications:
  - http_default      # must equal the `name:` field in the plugin yaml
```

The `name:` in the plugin config and the string in `profiles.yaml` must match
exactly, or the alert is generated but nothing is sent (no error). After editing
either file: `sudo systemctl reload crowdsec`. See [profiles.md](profiles.md).

## Test without waiting for a real attack

Don't trigger a live ban to check a webhook. Two cscli paths:

```bash
sudo cscli notifications test http_default     # send a synthetic alert to ONE plugin
sudo cscli notifications list                  # plugins cscli can see
sudo cscli notifications reinject <alert-id>   # replay a REAL past alert through profiles
```

`test` spawns the plugin with its on-disk config and pushes a generic alert —
the fastest loop for iterating on a template or URL.

## The #1 failure: a broken template fails silently-ish

A template that renders **invalid JSON** (or a payload the endpoint rejects) does
**not** crash CrowdSec. You get one line and nothing delivered:

```
level=warning msg="HTTP server returned non 200 status code: 400" @module=http-plugin
```

Critically, **CrowdSec never logs the rendered body** — only the status code. So
"why is my Discord/Slack/webhook silent" can't be answered from the engine logs
alone. The fix is to **see what was actually sent**:

### Render-to-sink: the debugging technique

Point the plugin at a local listener that captures the request, then fire a test.
`nc` + `jq` is enough — no server to write. Set `url: http://127.0.0.1:9999/` in
the plugin yaml, then in **one shell** capture a single request, keep only the body
(everything after the blank line), and validate it:

```bash
nc -l 9999 | sed '1,/^\r\{0,1\}$/d' | jq .
```

In **another shell** trigger it:

```bash
sudo cscli notifications test http_default
```

`jq` pretty-prints the rendered payload if it's valid JSON, or pinpoints the bug if
not — e.g. a **missing comma** between two keys yields
`jq: parse error: Expected separator between values` (the same defect makes the real
endpoint return 400). `nc` serves the one request and exits; the plugin logs a
transport error since it gets no proper HTTP reply, but you already have the body.

(For a persistent capture or to also exercise the response code, the `file` plugin
— `notification-file` writing the rendered output to a path — is a no-network
alternative for the same "what did it render" question.)

Common template bugs:

- Missing comma / trailing comma between JSON fields.
- A value typed as a string where the API wants a literal — e.g. Discord rejects
  `"inline": "false"` (string); it must be `"inline": false` (boolean).
- Redefining a variable already bound at the top of the template (`{{$alert := .}}`
  inside a `range` that already set context) — harmless to render but a frequent
  red herring; the real break is almost always the JSON shape.

## Per-environment notes

| Env | What changes |
|---|---|
| **systemd / bare-metal** | Recipes as-is. Plugin binaries from the package; `notification_dir` is `/etc/crowdsec/notifications/`. |
| **Docker / compose** | `docker compose exec crowdsec cscli notifications test <name>`. Mount or bake the plugin yaml; the `crowdsecurity/crowdsec` image ships the same plugin binaries. |
| **Kubernetes / Helm** | Configure via the chart's `config.notifications` / extra volumes; `kubectl exec -n <ns> <lapi-pod> -- cscli notifications test <name>`. Notifications fire from the **LAPI** pod (where profiles run), not the agents. |

## Pitfalls

- **Plugin binary not executable** → plugin never loads. The package sets the bit;
  hand-copied binaries may not. Check `/usr/lib/crowdsec/plugins/` perms.
- **Name mismatch** between `profiles.yaml` and the plugin `name:` → silent no-send.
- **`group_wait`/`group_threshold`/`max_retry`** in the plugin yaml batch and delay
  sends — a "missing" notification may just be batched. For dedup of repeated bans,
  tune these rather than expecting one message per event.
