# Configure — Hub management

Canonical docs: <https://docs.crowdsec.net/docs/next/getting_started/post_installation/console_hub> · `cscli hub` reference <https://docs.crowdsec.net/docs/next/cscli/cscli_hub>

The hub is the catalog of detection content. Items come in types — **parsers**,
**scenarios**, **postoverflows**, **contexts**, **appsec-configs**, **appsec-rules** — and
**collections**, which are curated bundles of the others.

## Collections vs items

Install a **collection** and it pulls every item it depends on. Installing
`crowdsecurity/wordpress` downloads and enables its scenarios:

```bash
sudo cscli collections install crowdsecurity/wordpress
#  scenarios: crowdsecurity/http-bf-wordpress_bf, crowdsecurity/http-wordpress_user-enum,
#             crowdsecurity/http-wordpress_wpconfig
#  collections: crowdsecurity/wordpress
#  Run 'sudo systemctl reload crowdsec' for the new configuration to be effective.
```

Prefer collections over hand-picking items — they track the dependencies for you. Reach for
individual `cscli parsers/scenarios/postoverflows/appsec-rules install <name>` only when you
need one item a collection doesn't include.

## Inventory — `cscli hub list`

```bash
sudo cscli hub list            # everything, grouped by type
sudo cscli hub list -o raw     # CSV: name,status,version,description,type
sudo cscli scenarios list      # one type
```

The first line summarizes what's loaded; the **Status** column is what you read during
debugging:

| Icon / status | Meaning |
|---|---|
| `✔️ enabled` | Pristine hub item, tracked, up to date. |
| `⚠️ enabled,tainted` | Hub item whose on-disk content no longer matches the hub version (someone edited it). Version shows `?`. |
| `🏠 enabled,local` | A local item not tracked by the hub (e.g. your own, **or** a hub item whose symlink was clobbered — see Pitfalls). |
| (missing / disabled) | Not installed or installed-but-disabled. |

## Update vs upgrade

Two different verbs — users conflate them:

```bash
sudo cscli hub update     # refresh the catalog INDEX (what versions exist). No item changes.
#  e.g. "Nothing to do, the hub index is up to date."
sudo cscli hub upgrade    # update INSTALLED items to the latest indexed version.
sudo systemctl reload crowdsec
```

Always `update` before `upgrade`, or `upgrade` won't see new versions. `upgrade` **skips
tainted and local items** rather than clobbering them:

```
level=warning msg="scenarios:crowdsecurity/http-wordpress_wpconfig is tainted, use '--force' to overwrite"
```

## Tainted items — detect and fix

An item becomes **tainted** when its content diverges from the hub version. `cscli hub list`
flags it `⚠️ tainted`, a collection that contains it reports `… is tainted by scenarios:…`,
and inspect confirms:

```bash
sudo cscli scenarios inspect crowdsecurity/http-wordpress_wpconfig | grep -E 'tainted|local_version'
#  local_version: '?'
#  tainted: true
sudo cscli scenarios inspect --diff crowdsecurity/http-wordpress_wpconfig   # shows exactly what changed
```

**Fix — restore the pristine hub version** by reinstalling with `--force`:

```bash
sudo cscli scenarios install crowdsecurity/http-wordpress_wpconfig --force
sudo systemctl reload crowdsec
```

This discards the local edits. If you needed those edits, move them to an override first
(below).

## The right way to customize — `_custom/` overrides

**Never edit a hub-managed file to change its behavior.** Hub items live in
`/etc/crowdsec/hub/...` and are symlinked into `/etc/crowdsec/{parsers,scenarios,...}/`;
editing them taints the item and your change is lost on the next `--force` upgrade.

Instead, drop an override file in the sibling `_custom/` directory for that type
(`scenarios/.../_custom/`, `parsers/.../_custom/`, etc.). Overrides are merged on top of the
hub item by `name`, survive upgrades, and keep the hub item pristine. See
[../debug/triage.md](../debug/triage.md) § Hard don'ts and the SKILL.md Hard don'ts list.

To remove a collection and its pulled items:

```bash
sudo cscli collections remove crowdsecurity/wordpress --force
sudo systemctl reload crowdsec
```

## Pitfalls

- **`update` ≠ `upgrade`.** `update` only refreshes the index; `upgrade` changes items.
- **`sudo sed -i` on a hub item breaks the symlink.** `sed -i` writes a *new* file, replacing
  the symlink with a plain file — the item flips to `🏠 local` and detaches from the hub
  entirely (no more upgrades). If you must inspect/edit, never edit in place; use a `_custom/`
  override. To recover a clobbered item, delete the stray file and reinstall it.
- **Editing the symlink target taints, doesn't detach.** Appending to the hub target file
  (e.g. `tee -a`) keeps the symlink but marks the item `⚠️ tainted`; `--force` reinstall
  restores it.
- **Forgetting to reload.** Every hub change needs `systemctl reload crowdsec` (or container
  recreate / `helm upgrade`) to take effect.
- **`upgrade` silently skips your local/tainted items** — by design. Reconcile them
  deliberately with `--force` (after saving any edits to an override).

## Per-environment notes

| Env | What changes |
|---|---|
| **systemd / bare-metal** | `cscli hub …` / `cscli <type> …` as above, then `systemctl reload crowdsec`. |
| **Docker / compose** | Install items declaratively at start with `COLLECTIONS=`, `PARSERS=`, `SCENARIOS=`, `POSTOVERFLOWS=` env vars. Items installed only via `docker exec … cscli` are lost on container recreate unless `/etc/crowdsec` is persisted — prefer the env vars for reproducibility. |
| **Kubernetes / Helm** | Declare hub items in the chart values (e.g. agent `collections`); `helm upgrade --reset-then-reuse-values`. Avoid imperative `cscli install` inside pods — it won't survive a reschedule. |
