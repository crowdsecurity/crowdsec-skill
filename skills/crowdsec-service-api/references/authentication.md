---
verified:
  - date: 2026-07-29
    version: "1.70.52"
    env: sapi
    notes: "GET /info key validation against production SAPI (ENTERPRISE key)"
---

# SAPI — Authentication & key handling

Canonical docs: <https://docs.crowdsec.net/u/console/service_api/getting_started> · quickstart <https://docs.crowdsec.net/u/console/service_api/authentication> · Python SDK <https://docs.crowdsec.net/u/console/service_api/sdks/python>
OpenAPI: `GET /info` — <https://admin.api.crowdsec.net/v1/docs>

SAPI is a **premium** feature. Every call authenticates with the `x-api-key`
header. The only exception is the integration *content* endpoint, which uses HTTP
Basic auth with credentials minted per integration — see
[integrations.md](./integrations.md).

## Create an API key

In the Console (<https://app.crowdsec.net>): **Settings → Service API Keys →
Create API Key**. Name it, set permissions, create. **The key is shown once** —
copy it immediately.

## Key resolution (how this skill reads it)

Resolve from the environment variable first, then an optional local file. Never
echo the key, never write it to a log, a config under version control, or any
working directory.

```bash
B=https://admin.api.crowdsec.net/v1
KEY="${CROWDSEC_SAPI_KEY:-$(cat ~/.config/crowdsec/sapi_key 2>/dev/null)}"
```

Store it in one file, readable only by you:
```bash
install -m 0600 /dev/stdin ~/.config/crowdsec/sapi_key <<<'YOUR-KEY'
```

## Validate — always the first call

```bash
curl -s -H "x-api-key: $KEY" "$B/info"
# → {"organization_id":"…","subscription_type":"ENTERPRISE","api_key_name":"…"}
```

`subscription_type` confirms the plan; `organization_id` confirms **which tenant**
subsequent mutations will change. A `401 {"message":"Unauthorized"}` means the key
is wrong, revoked, or the header name is misspelled (it is `x-api-key`).

## Typed alternative — Python SDK

For scripted/automated use there is an official SDK instead of raw curl:

```bash
pip install crowdsec-service-api
```
```python
from crowdsec_service_api import Info, Server, ApiKeyAuth
client = Info(base_url=Server.production_server.value, auth=ApiKeyAuth(api_key=KEY))
print(client.get_me_info())
```

SDK reference: <https://docs.crowdsec.net/u/console/service_api/sdks/python>. It
exposes `Blocklists`, `Allowlists`, `Integrations`, `Metrics`, `Info` and raises
`httpx.HTTPStatusError` on API errors.

## Security notes

- Treat the key like a password. If it lands in a shell history, a ticket, or any
  message, **rotate it** (Console → Settings → Service API Keys).
- One key = one organization's blast radius. Mutations affect every engine/bouncer
  subscribed to the lists in that org.
