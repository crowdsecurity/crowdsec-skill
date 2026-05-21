# Debug — Decisions exist but bouncer not blocking

Canonical docs: <https://docs.crowdsec.net/docs/next/troubleshooting/intro> · bouncers index <https://docs.crowdsec.net/u/bouncers/intro>

Commands below are written for **bare-metal** (`sudo cscli …`). In docker,
prefix with `docker exec <name>`; in k8s, `kubectl exec -n <ns> <pod> --`.

`cscli decisions list` shows the ban, but the client still gets through. Ladder,
fastest checks first.

## 0 — Symmetric case: is the IP allowlisted?

```bash
sudo cscli allowlists check <ip>
```

If it matches, the bouncer is *correctly* not blocking. Allowlists are **not
retroactive** and they don't delete existing decisions — if you added an
allowlist but the IP is still banned, delete the decision too
(`cscli decisions delete -i <ip>`). See
[../configure/allowlists.md](../configure/allowlists.md).

## 1 — Decision actually active and the right scope/family

```bash
sudo cscli decisions list -o json | jq '.[] | {value:.decisions[].value, type:.decisions[].type, scope:.decisions[].scope, until:.decisions[].until}'
```

- **TTL already expired**: `until` in the past → there's nothing to enforce.
- **Scope mismatch**: a `scope: Range` decision won't show as a single-IP ban;
  a `Country`/`AS` scoped decision needs a bouncer that resolves those.
- **IPv4 vs IPv6**: you banned the v4 but the client connects over v6 (or vice
  versa). The firewall bouncer keeps **separate** `table ip crowdsec` and
  `table ip6 crowdsec6` — a v6 client is unaffected by a v4 ban, and is
  silently unprotected if `disable_ipv6: true`.

## 2 — Bouncer is registered and pulling

```bash
sudo cscli bouncers list
```

Check the **Last API pull** column is recent (within the bouncer's
`update_frequency`). The default for the firewall bouncer is `10s`, so a
brand-new decision takes up to ~10 s to reach the firewall — *not* instant.
"Not blocking" immediately after `decisions add` is usually just this latency;
wait one poll interval and retest.

- No recent pull → bouncer process down or can't reach LAPI (steps 3–4).
- Bouncer absent from the list → never registered.

## 3 — Key matches

The bouncer's config key must equal the one LAPI has. A rotated/again-`add`ed
key, or a stale copy in the bouncer config, yields **HTTP 401** on pull (visible
in the bouncer's own log). Firewall bouncer key lives in
`/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml` (`api_key:`); compare
the bouncer name in `cscli bouncers list`. Fix: `cscli bouncers add <name>` and
paste the new key into the bouncer config, or reinstall the bouncer package
(its postinst re-registers).

## 4 — Bouncer can reach LAPI

From the bouncer host:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H "X-Api-Key: <bouncer-key>" \
  http://<lapi-host>:8080/v1/decisions
```

200 = reachable+authed. Connection refused/timeout = network/firewall between
bouncer and LAPI (common with remote/containerised LAPI). 403/401 = key (step 3).

## 5 — Per-bouncer specifics

**Firewall bouncer**:

```bash
sudo nft list table ip crowdsec        # sets + chains exist?
sudo nft list set ip crowdsec crowdsec-blacklists-cscli | grep <ip>
```

- The IP must appear in a `crowdsec-blacklists-*` set (origin-specific:
  `-cscli` manual, `-crowdsec` CAPI/console push, `-CAPI` community,
  `-lists` blocklists). In the set but not blocked → confirm the
  `crowdsec-chain-input` / `crowdsec-chain-forward` chains exist with the
  `drop` lines (priority `filter - 10`). If the tables are missing entirely,
  the bouncer service isn't running: `systemctl status crowdsec-firewall-bouncer`.
- Counter not incrementing on a known-banned source you curl from →
  traffic isn't traversing the hooked chain (e.g. it's container-internal on
  Docker's own table). See [../configure/bouncers/firewall.md](../configure/bouncers/firewall.md).

**Web-server bouncer** (nginx/traefik/caddy): the bouncer trusts the *client*
IP. Behind a proxy/CDN without correct `X-Forwarded-For` trust config, it bans
the proxy or sees the wrong IP and never matches. Also check **mode**:
`captcha` mode returns a challenge page, not a 403 — "not blocking" may actually
be "serving the captcha". See [../configure/bouncers/web-servers.md](../configure/bouncers/web-servers.md).

**AppSec**: distinct from a decision bouncer — AppSec blocks by request *shape*
inband (403 from AppSec), not by IP decision. If an inband rule should 403 but
doesn't, the bouncer isn't forwarding to the AppSec endpoint, or the config is
out-of-band only. See [../appsec/troubleshoot.md](../appsec/troubleshoot.md).

## 6 — CAPI/blocklist not imported yet

If you expect a community-blocklist IP to be blocked but it isn't:

```bash
sudo cscli capi status        # enrolled + pulling?
sudo cscli decisions list -o raw | grep -c CAPI    # community decisions present?
```

A fresh engine takes a pull cycle to import the community blocklist; the
firewall bouncer then needs one more `update_frequency` to materialise it into
`crowdsec-blacklists-CAPI`.
