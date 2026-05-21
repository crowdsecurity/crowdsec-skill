# Bouncers — Firewall (nftables / iptables / ipset)

Canonical docs: <https://docs.crowdsec.net/u/bouncers/firewall>

The firewall bouncer pulls decisions from LAPI and drops banned IPs at the host
firewall. **Installing it mutates host firewall state** — confirm with the user
first. The notes below target a 1.7.x box with the nftables bouncer 0.0.34.

## 1 — Pick the backend package

There are **two** real packages plus a meta-package. Install the one matching
your host's firewall, not the bare `crowdsec-firewall-bouncer`:

| Package | Use when |
|---|---|
| `crowdsec-firewall-bouncer-nftables` | Modern Debian/Ubuntu/RHEL (nft, or `iptables` symlinked to `iptables-nft`). **Default choice.** |
| `crowdsec-firewall-bouncer-iptables` | Legacy `iptables-legacy` + `ipset` hosts |

Detect the backend:

```bash
ls -l /etc/alternatives/iptables   # → iptables-nft means use the nftables pkg
nft list ruleset >/dev/null 2>&1 && echo "nft available"
```

```bash
sudo DEBIAN_FRONTEND=noninteractive apt install -y crowdsec-firewall-bouncer-nftables
```

> **Gotcha:** the package postinst can pop a debconf dialog (e.g. a
> "pending kernel upgrade" notice) that *hangs* a non-interactive/SSH-piped
> install with `Failed to open terminal … giving up!`. Always set
> `DEBIAN_FRONTEND=noninteractive` for unattended installs.

## 2 — Registration is automatic

The postinst **auto-registers the bouncer** — you do **not** need
`cscli bouncers add`. Result:

- A bouncer named `cs-firewall-bouncer-<timestamp>` appears in
  `sudo cscli bouncers list` (type `crowdsec-firewall-bouncer`, api-key auth).
- The key + LAPI URL are written to
  `/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`
  (`api_url: http://127.0.0.1:8080/`, `mode: nftables`,
  `update_frequency: 10s`, `deny_action: DROP`, `disable_ipv6: false`).
- `systemctl is-active crowdsec-firewall-bouncer` → `active` (and `enabled`).

If you *also* run `cscli bouncers add` you create a second, unused key — skip it.
Only register manually when the bouncer runs on a **different host** than LAPI
(then set `api_url` to the remote LAPI and paste the manual key into the yaml).

## 3 — What it creates in nftables

The bouncer builds its **own** tables, isolated from your existing ruleset:

```
table ip  crowdsec        # IPv4
table ip6 crowdsec6       # IPv6 (unless disable_ipv6: true)
```

Inside each: one **set per decision origin** and two chains —

- Sets: `crowdsec-blacklists-CAPI` (community blocklist),
  `crowdsec-blacklists-crowdsec` (CAPI/console scenario pushes),
  `crowdsec-blacklists-cscli` (manual `cscli decisions add`),
  `crowdsec-blacklists-lists` (subscribed blocklists). Each is a timeout set —
  elements carry the decision TTL and expire automatically.
- Chains: `crowdsec-chain-input` (`hook input`) and `crowdsec-chain-forward`
  (`hook forward`), both at **`priority filter - 10`** with `policy accept`,
  each line `ip saddr @crowdsec-blacklists-<origin> … drop`.

Why this matters operationally:
- **No conflict with UFW/firewalld/Docker.** The bouncer owns separate tables;
  it does not edit yours. `priority filter - 10` (i.e. -10) runs it *before*
  the standard `filter` table (priority 0), so a later ACCEPT can't un-drop a
  banned IP.
- The `forward` chain means routed/bridged traffic (containers, VMs behind this
  host) is also filtered — not just traffic to local sockets.
- `policy accept` on the chains: anything not in a set passes straight through;
  the bouncer never default-denies.

## 4 — Verify it actually blocks

```bash
# add a short manual ban
sudo cscli decisions add --ip 192.0.2.66 --duration 4m --reason fw-test
sleep 12                                  # update_frequency default is 10s

sudo cscli decisions list | grep 192.0.2.66
sudo nft list set ip crowdsec crowdsec-blacklists-cscli | grep 192.0.2.66
sudo nft list chain ip crowdsec crowdsec-chain-input     # drop line present
```

Expected: the IP is a set element and the input chain drops `@…-cscli`. To prove
a real packet drop, ban a host you can curl *from* and confirm the connection
times out, then `nft list table ip crowdsec | grep -A2 'counter name "crowdsec-blacklists-cscli"'`
shows the counter incrementing.

Clean up the test ban:

```bash
sudo cscli decisions delete -i 192.0.2.66
```

(The set element disappears within `update_frequency`.)

## 5 — Pitfalls

- **Latency = `update_frequency`** (default 10s). A new decision is *not*
  instant at the firewall; tune the field down if you need faster, at the cost
  of more LAPI polling.
- **IPv6 silently unprotected** if you install on an IPv6 host but leave
  `disable_ipv6: true` (some images default it on). Banned v6 addresses then
  pass — check `nft list table ip6 crowdsec6` exists and is populated.
- **Decision count vs. nft set size**: nft sets are dynamic (no fixed size
  ceiling like the old `ipset` `maxelem`). With the legacy `-iptables` package
  you *can* hit the `ipset` `maxelem` (default 65536) when subscribed to large
  blocklists — bump it in the bouncer config or move to the nftables backend.
- **Containers**: traffic between containers via the host bridge transits the
  `forward` hook (covered). Traffic on a Docker user-defined network using
  `DOCKER-USER` is in Docker's own table — the bouncer's separate table still
  sees the `forward` hook, but verify with a real banned-source request if
  container-to-container blocking matters.
- **"Banned but still reachable"** → almost always `update_frequency` not
  elapsed, `disable_ipv6` masking a v6 client, or the bouncer service stopped.
  Full decision tree: [../../debug/bouncer-not-blocking.md](../../debug/bouncer-not-blocking.md).

## Teardown

```bash
sudo systemctl stop crowdsec-firewall-bouncer
sudo DEBIAN_FRONTEND=noninteractive apt purge -y crowdsec-firewall-bouncer-nftables
sudo nft list table ip crowdsec  >/dev/null 2>&1 && sudo nft delete table ip crowdsec
sudo nft list table ip6 crowdsec6 >/dev/null 2>&1 && sudo nft delete table ip6 crowdsec6
sudo cscli bouncers delete cs-firewall-bouncer-<timestamp>
```

## Next step

Confirm the full detection→decision→block loop with the self-block remediation
test in [../../operate/health-check.md](../../operate/health-check.md).
