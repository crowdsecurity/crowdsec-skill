---
verified:
  - date: 2026-05-22
    version: "1.7.8"
    env: systemd
    notes: "all 3 probes fire (whitelist removed), self-block→403, capi status; fixed remediation:false drift"
---

# Operate — Health-check

Canonical docs: <https://docs.crowdsec.net/u/getting_started/health_check>

Use this after a fresh install, after an upgrade, or any time you want to confirm the engine + bouncers + AppSec are end-to-end functional. The official guide defines **three purpose-built test scenarios** that ship with the standard hub install — no real attack traffic required.

| Test | Triggers scenario | Cooldown before retest |
|---|---|---|
| HTTP probe (web server logs → engine) | `crowdsecurity/http-generic-test` | 5 min |
| SSH probe (auth log → engine) | `crowdsecurity/ssh-generic-test` | 5 min |
| AppSec probe (request → AppSec component) | `crowdsecurity/appsec-generic-test` | 1 min |

The HTTP and AppSec probes use the **same** path: `/crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl`. A single request can trigger both if your stack has both web-log parsing and AppSec in place.

## ⚠️ Source-IP requirement

`crowdsecurity/whitelists` ships enabled by default and whitelists private ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16). **Tests from those ranges will not trigger any scenario** — the events are whitelisted at the parser stage before they reach a bucket.

Run the probes from:
- a public-IP host (laptop on tether, cloud VM, etc.) targeting your engine's public-facing service, OR
- from your phone on mobile data, OR
- temporarily disable the whitelist for testing (`cscli parsers remove crowdsecurity/whitelists` — re-install after).

Same constraint applies to the remediation self-block test at the end of this page.

---

## 1. Engine detection: HTTP

Triggers `crowdsecurity/http-generic-test`. Requires the engine to be parsing your web-server access logs (nginx, apache, etc. — `cscli parsers list` should show the matching `*-logs` parser enabled).

```bash
# From a PUBLIC IP, hit your service:
curl -I https://<your-public-service-url>/crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl

# On the engine: confirm the alert (cscli, docker exec, or kubectl exec depending on env)
sudo cscli alerts list -s crowdsecurity/http-generic-test
```

Expected: one row with `kind: crowdsec`, scope `Ip:<your-public-ip>`. The test scenarios are deliberately `remediation: false` (`type: trigger`), so they produce an **alert but no ban decision** — the alert itself is the proof the detection chain works, and the probe won't lock you out. End-to-end bouncer enforcement is proven separately in § 5.

**Common failure paths** (in order to check):
1. *No row, no parser hit* → the web server's logs aren't being read. `cscli metrics show acquisition` — does your access log show non-zero "Lines read"? If not, see [../configure/acquisition.md](../configure/acquisition.md).
2. *Logs read, 0 parsed* → wrong `type:` label vs installed parser. See [../debug/parsing.md](../debug/parsing.md).
3. *Source IP is private* → see the warning at top of page.

## 2. Engine detection: SSH

Triggers `crowdsecurity/ssh-generic-test`. Requires `crowdsecurity/sshd` collection (default in most installs).

```bash
# From a PUBLIC IP:
ssh crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl@<your-public-ip>
# Connection will fail — that's fine, the login attempt is what triggers it.

# On the engine:
sudo cscli alerts list -s crowdsecurity/ssh-generic-test
```

Expected: one row with `kind: crowdsec`. Like the HTTP probe, `ssh-generic-test` is `remediation: false` — an alert appears, but no ban (by design).

**Common failure paths:**
1. *No row* → check `cscli metrics show acquisition` for `/var/log/auth.log` (or wherever sshd logs land). On systems using journald-only logging, the file source may be empty — switch to a journald acquisition.
2. *sshd parser missing* → `cscli parsers list | grep sshd`. Install `crowdsecurity/sshd` collection if missing.

## 3. AppSec: WAF detection

Triggers `crowdsecurity/appsec-generic-test`. Requires:

- AppSec component running (`cscli metrics show appsec` shows an Engine row).
- An appsec-config that includes the `appsec-generic-test` rule. The hub `crowdsecurity/appsec-default` config does; the bare `crowdsecurity/virtual-patching` config does **not**.
- For the full chain test: a WAF-capable remediation bouncer wired to AppSec.

### 3a. Full-chain test (recommended — through a real web server + bouncer)

```bash
# From a PUBLIC IP, through your bouncer-protected web server:
curl -I https://<your-public-service-url>/crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl

# On the engine:
sudo cscli alerts list -s crowdsecurity/appsec-generic-test
```

Expected: alert with `kind: crowdsec` (the AppSec scenario aggregates the rule match into a normal alert — not a `kind: waf` direct-block alert, since `appsec-generic-test` is an **out-of-band** rule). The web request itself returns the bouncer's "allow" code (200) — out-of-band rules do not return 403 from AppSec. See [../appsec/overview.md](../appsec/overview.md) for the inband-vs-out-of-band distinction.

### 3b. Component-only test (no bouncer / web server yet)

If you haven't wired a bouncer to AppSec yet, reuse the `curl` recipe in
[../appsec/deploy.md](../appsec/deploy.md) § Smoke-test, substituting
`-H "X-Crowdsec-Appsec-Uri: /crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl"` and a
public test IP. Expected: HTTP 200 (out-of-band → no inband block), then the
scenario alert appears after the signal-push interval (several seconds).

**Common failure paths:**
1. *Rule not installed*: `cscli appsec-rules list | grep appsec-generic-test`. If missing, install the `crowdsecurity/appsec-virtual-patching` collection — it pulls the test rule, parser, scenarios, and the `crowdsecurity/appsec-default` config that wires them together.
2. *Wrong appsec-config*: confirm the acquisition's `appsec_config:` points to a config that includes `appsec-generic-test` (either directly or via a glob). `crowdsecurity/appsec-default` does; `crowdsecurity/virtual-patching` alone does **not**.
3. *Probe sent before listener up*: AppSec listener takes 1–2 s after reload.
4. *Private source IP*: same whitelist applies. Use a public test IP.
5. *Alert delay*: out-of-band rules emit events that aggregate into the scenario; the alert appears after the next signal push (several seconds). Wait ~15 s before declaring failure.

## 4. CAPI connectivity

```bash
sudo cscli capi status
```

Expected: `You can successfully interact with Central API (CAPI)`. If it fails, see <https://docs.crowdsec.net/u/getting_started/health_check> § Connectivity Troubleshooting (typical causes: missing `online_api_credentials.yaml` — `cscli capi register` then reload; egress firewall to `api.crowdsec.net`; HTTP proxy).

## 5. End-to-end remediation (bouncer self-block)

This proves bouncers actually enforce decisions. **Risk: you will block your own access for the duration of the test.** Run it from a different public IP than the one you'll ban, or set a very short duration.

```bash
# Find the public IP you want to ban (NOT the IP you're connected from)
TEST_IP=$(curl -s api.ipify.org)         # IP of the host running curl — adjust as needed

# Add a 1-minute ban
sudo cscli decisions add --ip "$TEST_IP" --duration 1m --reason "health-check self-block test"

# Wait for the bouncer to pull (usually within ~10 s of its poll interval)
sleep 15

# From a host with that IP, try your service:
curl -I https://<your-public-service-url>/
# Expected: HTTP 403 (or captcha challenge, if your bouncer is in captcha mode)

# After 1 minute the decision expires; confirm:
sudo cscli decisions list
```

If the request still goes through after a successful add → the bouncer isn't polling fast enough, isn't enforcing, or doesn't have the right scope. See [../debug/bouncer-not-blocking.md](../debug/bouncer-not-blocking.md).

## Automating the health-check

There's no built-in `cscli health-check` subcommand. The pattern that works:

```bash
# From a public-IP test runner, hit the probes:
curl -I "https://${SERVICE}/crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl"
ssh "crowdsec-test-NtktlJHV4TfBSK3wvlhiOBnl@${SERVICE_HOST}" -o ConnectTimeout=5 || true

# Then, on the engine host (or via docker exec / kubectl exec):
sleep 15   # allow alerts to push

for scenario in \
        crowdsecurity/http-generic-test \
        crowdsecurity/ssh-generic-test \
        crowdsecurity/appsec-generic-test; do
    n=$(sudo cscli alerts list -s "$scenario" -o json 2>/dev/null | jq 'length')
    printf "%-40s alerts=%s\n" "$scenario" "$n"
done
```

A `n > 0` for each line you expect to pass = healthy.

## Per-environment cscli invocation

The verifications use `cscli` against the engine. Adjust the prefix per environment:

| Env | Run cscli as |
|---|---|
| systemd / bare-metal | `sudo cscli ...` |
| Docker | `docker exec crowdsec cscli ...` |
| Kubernetes | `kubectl exec -n <ns> $(kubectl get pods -n <ns> -l k8s-app=crowdsec,type=lapi -o name) -- cscli ...` |

[`scripts/diagnose.sh`](../../scripts/diagnose.sh) wraps these per-env invocations, so a single run captures everything the health-check needs alongside the full forensic archive.
