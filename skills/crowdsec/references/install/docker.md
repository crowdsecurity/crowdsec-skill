---
verified:
  - date: 2026-07-10
    version: "1.7.8"
    env: docker
    notes: "compose up on empty cs-config volume; acquis.d must be read-write (a :ro submount aborts boot with rsync exit 23); /etc/crowdsec persists creds+enrollment across down&&up; COLLECTIONS install on boot; /logs/auth.log container-path acquisition; 8081:8080 coexistence; bouncers add; teardown -v"
---

# Install — Docker / docker-compose

Canonical docs: <https://docs.crowdsec.net/docs/next/getting_started/installation/docker> · image reference <https://docs.crowdsec.net/u/getting_started/installation/#docker>

Operational layer over the canonical image docs. Targets
`crowdsecurity/crowdsec:latest` (engine v1.7.8) via compose.

## Minimal working compose

```yaml
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest      # pin to a minor in prod, e.g. :v1.7
    container_name: crowdsec
    environment:
      COLLECTIONS: "crowdsecurity/sshd crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules"
      GID: "${GID:-1000}"
    volumes:
      - cs-config:/etc/crowdsec
      - cs-data:/var/lib/crowdsec/data
      - /var/log/auth.log:/logs/auth.log:ro          # host log, read-only
      - ./acquis.d:/etc/crowdsec/acquis.d            # your acquisition — must be read-write (§6)
    ports:
      - "8081:8080"      # LAPI (see port-conflict note)
      - "7423:7422"      # AppSec (only if you run the WAF)
    restart: unless-stopped
volumes:
  cs-config:
  cs-data:
```

Bring up: `docker compose up -d`. The image installs the `COLLECTIONS` on
startup — and re-runs the install on **every** start, not just the first (see
§2). `sshd`, `appsec-virtual-patching`, and `appsec-generic-rules` all end up
`enabled` after startup.

**Persist both volumes — they hold different state.** `cs-config:/etc/crowdsec`
holds `console.yaml` and the `local_api_credentials.yaml` /
`online_api_credentials.yaml` files; `cs-data:/var/lib/crowdsec/data` holds the
DB (decisions, alerts). `docker restart` keeps everything, but
`docker compose down && up` — or an image upgrade — *recreates* the container and
loses whatever isn't on a volume. Without `cs-config`, a container recreated after
`cscli console enroll` comes back **un-enrolled** (you re-enroll and re-accept);
see [console.md](console.md). The canonical Docker doc lists
`crowdsec-config:/etc/crowdsec` among the paths that must be persisted.

## Gotchas

### 1. Acquisition paths are *container* paths, not host paths

This is the #1 Docker mistake. You mount `/var/log/auth.log` to
`/logs/auth.log` — your acquisition file must reference the **in-container**
path:

```yaml
# acquis.d/sshd.yaml
filenames:
  - /logs/auth.log        # NOT /var/log/auth.log
labels: { type: syslog }
source: file
```

A path that exists on the host but isn't mounted reads **0 lines** — the source
simply doesn't appear in the metrics (the agent log carries a
`No matching files for pattern <path>` warning, so it's not entirely silent).
Verify with `docker exec crowdsec cscli metrics show acquisition`.

To read *other containers'* logs instead of host files, use the built-in Docker
datasource (`datasource_docker` is compiled in). This requires mounting the
Docker socket (`/var/run/docker.sock:/var/run/docker.sock:ro`) and adding an
acquisition like:

> [!WARNING]
> Mounting `/var/run/docker.sock` gives the container root-equivalent control
> over the Docker host, even when mounted `:ro`. Only do this on trusted hosts.
> If possible, prefer lower-privilege alternatives such as mounting specific
> log files, using a least-privileged log shipper, or running CrowdSec outside
> Docker.

```yaml
# acquis.d/docker.yaml
source: docker
container_name:
  - web            # or container_name_regexp / use_container_labels
labels:
  type: nginx
```

crowdsec subscribes to Docker events, tails the container's stdout/stderr, and
scenarios fire on the containerized workload. The engine runs as root so it can
read the socket; a non-root container needs the `docker` group via `GID`.

### 2. Hub env vars install on *every* boot — but never *uninstall*

`COLLECTIONS`/`PARSERS`/`SCENARIOS` (and the other hub env vars) are processed on
**every** container start, not just the first — the entrypoint runs
`cscli <type> install` for each listed item each time (skipping items you've
tainted or made local). So **adding** an item and recreating the container
(`docker compose up -d`) *does* install it, even on a persisted
`cs-config:/etc/crowdsec` volume.

The catch is the other direction: **removing** an item from the env var does
**not** uninstall it. To remove, use the matching
`DISABLE_COLLECTIONS`/`DISABLE_PARSERS`/… env var, or
`docker exec crowdsec cscli collections remove …`. Post-boot you can manage the
hub directly with `docker exec crowdsec cscli collections install …` then
`docker compose restart`.

### 3. Port conflict with a host-installed engine

If a bare-metal CrowdSec already owns `8080`/`7422` (the container won't bind
them), map to free host ports as above (`8081:8080`,
`7423:7422`). Bouncers and `cscli -u` then target the mapped host port. This is
the normal coexistence pattern while migrating host→container.

### 4. AppSec must listen on `0.0.0.0` inside the container

The AppSec acquisition must set `listen_addr: 0.0.0.0:7422` (not `127.0.0.1`)
or the published port reaches nothing. Confirm with a host
`curl http://127.0.0.1:7423/` against a `7423:7422` mapping (`allow: 200` / `block: 403`).

### 5. Other env-in-container realities

- **`GID`**: the official image runs the engine as **root**, so plain
  bind-mounted log *files* are read regardless of `GID` (root bypasses group
  perms — a `GID` mismatch does **not** silently zero out a file mount on the
  default image). `GID` matters when you run the container as non-root, or for
  group-restricted **sockets**: set it to the owning group (e.g. `docker` for
  the `source: docker` socket, or the journald log group) or those reads fail.
- **Time skew**: a container with a wrong clock fails CAPI TLS
  (`cscli capi status` errors). Containers normally inherit host time — only an
  issue with custom runtimes.
- **IPv6**: the AppSec/firewall behaviour mirrors bare-metal; container
  networking is v4 by default unless you enable v6 on the daemon/network.

### 6. `acquis.d` must be read-write when `/etc/crowdsec` is a persisted volume

Mount `./acquis.d` **read-write** (as the compose above does), not `:ro`. On a
fresh `cs-config` volume the entrypoint rsyncs its staging config into
`/etc/crowdsec` and `chown`s everything under it, including the `acquis.d`
submount. A `:ro` bind there makes that `chown` fail and the container dies on
first boot:

```
rsync: [generator] chown "/etc/crowdsec/acquis.d" failed: Read-only file system (30)
rsync error: some files/attrs were not transferred (see previous errors) (code 23)
```

The container exits **23** and never starts. This only affects the `acquis.d`
submount *inside* the persisted `/etc/crowdsec` volume — host-log mounts elsewhere
(e.g. `/logs/auth.log:ro`) are untouched.

## Bouncer key bootstrap

```bash
# create a key for an external bouncer (web server, firewall, AppSec)
docker exec crowdsec cscli bouncers add my-bouncer -o raw
```

Use that key in the bouncer's config. For declarative bootstrap, the image also
honours `BOUNCER_KEY_<name>` env vars (the named bouncer appears in
`cscli bouncers list` on boot); `cscli bouncers add` post-hoc is simplest for
one-offs.

**Endpoint depends on where the bouncer runs:**

- *On the host* → the **mapped** host ports: `api_url: http://<host>:8081`,
  `appsec_url: http://<host>:7423`.
- *In a container on the same compose network* → the crowdsec **service name +
  internal** ports: `api_url: http://crowdsec:8080`,
  `appsec_url: http://crowdsec:7422` (the unmapped container ports — don't use
  the published `8081`/`7423` from inside the network).

> **lua/OpenResty bouncers in a container need a DNS `resolver`.** The nginx lua
> bouncer resolves `crowdsec` via lua cosockets, which ignore the system
> resolver. Without an explicit `resolver 127.0.0.11;` (Docker's embedded DNS)
> in the nginx `http` context, every LAPI pull and AppSec check fails with
> `no resolver defined to resolve "crowdsec"` and the bouncer silently falls
> back. Add that directive (or pin a fixed IP) for any containerized lua bouncer.

## Management & diagnostics

Every `cscli` command works via `docker exec crowdsec cscli …`. The bundled
helper supports this directly:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/diagnose.sh --env docker --container crowdsec
```

(Detects `Environment: docker`; captures version plus the full forensic
support archive from inside the container.)

## Teardown

```bash
docker compose down -v        # -v removes the named config+data volumes
```

## Next step

Run the probes in [../operate/health-check.md](../operate/health-check.md)
(use the `docker exec crowdsec cscli …` row in its per-environment table) before
trusting the deployment.
