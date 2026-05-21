# Install — Kubernetes (Helm)

Canonical docs: <https://docs.crowdsec.net/docs/next/getting_started/installation/kubernetes> · chart values <https://github.com/crowdsecurity/helm-charts/tree/main/charts/crowdsec>

Operational layer over the canonical chart docs. Targets the
`crowdsec/crowdsec` Helm chart **0.24.0 (app v1.7.8)**; notes apply to kind and
**k3s v1.35.4** (single-node, Ubuntu).

## Architecture (what the chart deploys)

| Component | Workload | Role |
|---|---|---|
| **LAPI** | Deployment (`lapi`) | Local API + DB; bouncers and agents talk to it. Optional dashboard. |
| **Agent** | DaemonSet (`agent`) | One pod per node, reads other pods' logs and ships to LAPI. |
| **AppSec** | Deployment (`appsec`, *disabled by default*) | WAF listener; separate Service for bouncers to forward to. |

Bouncers are **not** in this chart — they live with the thing they protect
(ingress controller / web bouncer, or a node firewall bouncer).

## Install

```bash
helm repo add crowdsec https://crowdsecurity.github.io/helm-charts
helm repo update
kubectl create namespace crowdsec
helm install crowdsec crowdsec/crowdsec -n crowdsec -f values.yaml
```

Minimal `values.yaml` that actually works:

```yaml
container_runtime: containerd          # SEE GOTCHA 1 — chart default is "docker"
lapi:
  persistentVolume:
    data:   { enabled: false }         # dev only; keep enabled in prod (GOTCHA 3)
    config: { enabled: false }
  dashboard:
    enabled: false
agent:
  acquisition:
    - namespace: kube-system
      podName: kube-apiserver-*        # SEE GOTCHA 7 — no such pod on k3s/k0s
      program: kube-apiserver
appsec:
  enabled: true
  env:                                 # SEE GOTCHA 8 — REQUIRED, else the appsec pod crashloops
    - name: COLLECTIONS
      value: "crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules"
  acquisitions:
    - source: appsec
      listen_addr: "0.0.0.0:7422"
      path: /
      appsec_config: crowdsecurity/appsec-default
      labels:                          # SEE GOTCHA 8 — REQUIRED, else "missing labels" fatal
        type: appsec
```

> The two `appsec` additions above (`env: COLLECTIONS` and `labels:`) are **not optional** — `appsec.enabled: true` without them produces a CrashLoopBackOff, not a working WAF. See gotcha 8.

## Gotchas

### 1. `container_runtime` default is `docker`; modern clusters use `containerd`

The chart ships `container_runtime: docker`. kind, k3d, and most
managed clusters (EKS/GKE/AKS recent) run **containerd**. With the wrong value
the agent reads pod logs in the wrong format → lines read, **0 parsed**, no
alerts (the [parsing.md](../debug/parsing.md) symptom). Set
`container_runtime: containerd` unless your nodes genuinely use the Docker
runtime. Confirm with `kubectl get nodes -o wide` → CONTAINER-RUNTIME column.

### 2. Acquisition is pod-selector based, not file paths

Unlike bare-metal/Docker, `agent.acquisition` selects **pods** by
`namespace` + `podName` (glob) + `program` (which parser to apply). There is no
`/var/log/...` path. To protect an ingress controller you point it at that
controller's namespace/pod and set `program` to the matching parser (e.g.
`nginx`). `agent.additionalAcquisition` takes the classic datasource shapes
(syslog listener, kinesis, etc.) for non-pod sources.

### 3. LAPI PVCs default ON and need a StorageClass

`lapi.persistentVolume.data` (1Gi) and `.config` (100Mi) are **enabled by
default** and store registered **bouncer API keys** and LAPI credentials. With
no default StorageClass the LAPI pod stays `Pending` on an unbound PVC. kind
ships a `standard` (local-path) default SC so it works there; many bare clusters
do not — set `storageClassName` or provision a default SC. Disabling them (as
in the dev values above) means **bouncer keys reset on every LAPI restart** —
fine for dev, wrong for prod.

### 4. AppSec is a separate Deployment + Service

`appsec.enabled: true` adds an AppSec Deployment and its own Service. Bouncers
forward to the **AppSec Service DNS** (`appsec.lapiURL`/`lapiHost`/`lapiPort`
control how AppSec itself reaches LAPI, default the internal LAPI service).
`appsec.acquisitions` is the in-cluster equivalent of the bare-metal
`acquis.d/appsec.yaml` — same `source: appsec` / `listen_addr` / `appsec_config`
shape; use `crowdsecurity/appsec-default` so the health-check rule is present
(same reasoning as [../appsec/deploy.md](../appsec/deploy.md)).

### 5. RBAC / PSA

The agent needs RBAC to read pod logs cluster-wide (the chart creates the
ClusterRole/Binding). On clusters with restricted Pod Security Admission, the
DaemonSet may need a relaxed namespace label
(`pod-security.kubernetes.io/enforce: privileged|baseline`) — symptom is the
agent DaemonSet pods rejected at admission.

### 6. kind/k3d dev: disk pressure is real

kind/k3d nodes pull CrowdSec images into the node's overlay FS; a small VM
fills up and the apiserver wedges with `net/http: TLS handshake timeout`
mid-rollout — not an obvious CrowdSec error. Check `docker exec <node> df -h /`
and budget several GB free.

### 7. k3s/k0s have no `kube-apiserver` pod; kubeconfig is root-only

On **k3s v1.35.4**:
- k3s runs the control plane (apiserver, scheduler, controller) **embedded in the single `k3s` process** — there is **no `kube-apiserver-*` pod** in `kube-system`. The example acquisition above matches zero pods on k3s. Point `agent.acquisition` at a pod that actually exists (e.g. the ingress controller, or `svclb-traefik-*` on default k3s) with the matching `program`/parser.
- The kubeconfig at `/etc/rancher/k3s/k3s.yaml` is **mode 0600 root-only**. `helm`/`kubectl` as a normal user can't read it, and `sudo helm` fails with `repo … not found` (Helm repos are per-user, root has none). Fix: `mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config`, then run helm as your user.
- **Positive surprise vs gotcha 3:** k3s ships a `local-path` **default StorageClass**, so the LAPI PVCs (`crowdsec-db-pvc` 1Gi, `crowdsec-config-pvc` 100Mi) bind out of the box — you can keep `persistentVolume` *enabled* (prod-like) on k3s with no extra setup.

### 8. `appsec.enabled: true` alone crashloops — needs collections AND labels

Two independent fatals, both hit in sequence if you copy a bare appsec block:
- `acquis.yaml: missing labels` → the `appsec.acquisitions` entry **must** carry `labels: { type: appsec }`, exactly like the bare-metal `acquis.d/appsec.yaml`.
- `no appsec-config found for crowdsecurity/appsec-default` → the AppSec pod ships **no hub rules**; you must install the collections into it via **`appsec.env`** with a `COLLECTIONS` variable (space-separated), e.g. `crowdsecurity/appsec-virtual-patching crowdsecurity/appsec-generic-rules`. (`appsec.configs`/`appsec.rules` are for *inline custom* content, not hub installs.)

Symptom is the `crowdsec-appsec` pod in `CrashLoopBackOff` with the startup probe failing on `:6060/metrics` (the process exits before serving). Read the cause with `kubectl logs <appsec-pod> -c crowdsec-appsec --previous | grep fatal`.

## Validate

`cscli` runs inside the LAPI pod. The bundled helper supports this:

```bash
~/.claude/skills/crowdsec/scripts/diagnose.sh --env k8s --namespace crowdsec --pod <lapi-pod>
# manual equivalent:
LAPI=$(kubectl get pod -n crowdsec -l type=lapi -o name | head -1)
kubectl exec -n crowdsec $LAPI -- cscli lapi status
kubectl exec -n crowdsec $LAPI -- cscli metrics
```

WAF smoke test — **run it from inside the cluster, not via `kubectl port-forward`.**
AppSec api-key auth rejects requests arriving through
`kubectl port-forward` with `401` even when the key is valid (the same key
returns `200`/`403` over the in-cluster Service). Register a key in LAPI and
probe the Service DNS from any pod:

```bash
LAPI=$(kubectl get pod -n crowdsec -l type=lapi -o name | head -1)
KEY=$(kubectl exec -n crowdsec $LAPI -c crowdsec-lapi -- cscli bouncers add smoketest -o raw)
AG=$(kubectl get pod -n crowdsec -l type=agent -o name | head -1)
# ALLOW → 200
kubectl exec -n crowdsec $AG -c crowdsec-agent -- wget -S -q -O /dev/null \
  --header="X-Crowdsec-Appsec-Api-Key: $KEY" --header='X-Crowdsec-Appsec-Ip: 203.0.113.1' \
  --header='X-Crowdsec-Appsec-Host: t' --header='X-Crowdsec-Appsec-Verb: GET' \
  --header='X-Crowdsec-Appsec-Uri: /' http://crowdsec-appsec-service:7422/ 2>&1 | grep HTTP/
# BLOCK (CVE-2017-9841) → 403
kubectl exec -n crowdsec $AG -c crowdsec-agent -- wget -S -q -O /dev/null \
  --header="X-Crowdsec-Appsec-Api-Key: $KEY" --header='X-Crowdsec-Appsec-Ip: 203.0.113.2' \
  --header='X-Crowdsec-Appsec-Host: t' --header='X-Crowdsec-Appsec-Verb: GET' \
  --header='X-Crowdsec-Appsec-Uri: /vendor/phpunit/phpunit/src/Util/PHP/eval-stdin.php' \
  http://crowdsec-appsec-service:7422/ 2>&1 | grep HTTP/
# confirm attribution
kubectl exec -n crowdsec $(kubectl get pod -n crowdsec -l type=appsec -o name | head -1) \
  -c crowdsec-appsec -- cscli metrics show appsec
```

(The crowdsec image has `wget`, not `curl`. `wget` sends a minimal User-Agent,
so you'll also see `crowdsecurity/experimental-no-user-agent` in the metrics —
harmless for the test.)

## Teardown

```bash
helm uninstall crowdsec -n crowdsec
kubectl delete namespace crowdsec
kind delete cluster --name <name>     # dev: also reclaims the node image's disk
```

## Next step

Run the probes in [../operate/health-check.md](../operate/health-check.md)
(use the `kubectl exec … cscli` row in its per-environment table).
