#!/usr/bin/env bash
# diagnose.sh — CrowdSec first-look triage.
#
# Wraps `cscli support dump --fast` (the official forensic snapshot) and emits a
# curated, human-readable text report. The underlying zip archive is preserved
# on disk so you can hand it to CrowdSec support without re-running anything.
#
# What ends up where:
#   - Canonical archive: /tmp/crowdsec-support-<timestamp>.zip (or --archive)
#   - Text report:       stdout (or --output)
#
# What the archive contains (curated, in addition to the text report you read):
#   prometheus + human metrics · system info · redacted config · profiles ·
#   all acquisition files · hub state · bouncers / agents · LAPI / CAPI / PAPI
#   status · pprof goroutine + heap (CPU skipped under --fast) · full log files
#   · version · feature flags · crash dumps.
#
# Usage:
#   ./diagnose.sh                                      # auto-detect env
#   ./diagnose.sh --env systemd
#   ./diagnose.sh --env docker --container crowdsec
#   ./diagnose.sh --env k8s --namespace crowdsec --pod crowdsec-agent-xxxx
#   ./diagnose.sh --log-lines 500                      # text-report log tail
#   ./diagnose.sh --output /tmp/report.txt             # also write report to file
#   ./diagnose.sh --archive /tmp/my-snapshot.zip       # custom archive location
#   ./diagnose.sh --full-cpu-profile                   # disable --fast (30 s CPU sample)
#
# Exit codes:
#   0  success
#   1  CrowdSec not found in any environment, or support dump failed
#   2  bad usage / argument error

set -uo pipefail

ENV_OVERRIDE=""
DOCKER_CONTAINER=""
K8S_NAMESPACE=""
K8S_POD=""
LOG_LINES=200
OUT_FILE=""
ARCHIVE=""
SUPPORT_DUMP_FLAGS="--fast"

usage() {
    sed -n '2,30p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) ENV_OVERRIDE="${2:-}"; shift 2 ;;
        --container) DOCKER_CONTAINER="${2:-}"; shift 2 ;;
        --namespace) K8S_NAMESPACE="${2:-}"; shift 2 ;;
        --pod) K8S_POD="${2:-}"; shift 2 ;;
        --log-lines) LOG_LINES="${2:-200}"; shift 2 ;;
        --output) OUT_FILE="${2:-}"; shift 2 ;;
        --archive) ARCHIVE="${2:-}"; shift 2 ;;
        --full-cpu-profile) SUPPORT_DUMP_FLAGS=""; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${ARCHIVE:-/tmp/crowdsec-support-${TS}.zip}"
EXTRACTED="$(mktemp -d "/tmp/crowdsec-support-${TS}-XXXX")"
trap 'rm -rf "$EXTRACTED"' EXIT

# ---- output plumbing ----
if [[ -n "$OUT_FILE" ]]; then
    exec > >(tee "$OUT_FILE")
fi

section() { printf '\n==> %s\n' "$*"; }
subsection() { printf '\n--- %s ---\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- environment detection ----
detect_env() {
    if [[ -n "$ENV_OVERRIDE" ]]; then
        echo "$ENV_OVERRIDE"; return
    fi
    if have systemctl && systemctl list-unit-files crowdsec.service >/dev/null 2>&1 \
            && systemctl is-enabled crowdsec.service >/dev/null 2>&1; then
        echo systemd; return
    fi
    if have docker && docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
            | grep -qE '(^|/)(crowdsec)([: ]|$)'; then
        echo docker; return
    fi
    if have kubectl && kubectl get pods -A 2>/dev/null \
            | awk '{print $2}' | grep -qiE 'crowdsec'; then
        echo k8s; return
    fi
    echo unknown
}

ENVKIND="$(detect_env)"

# ---- env-specific invocation primitives ----
case "$ENVKIND" in
    systemd)
        if [[ "$EUID" -eq 0 ]]; then
            CSCLI=(cscli)
        else
            CSCLI=(sudo -n cscli)
        fi
        FETCH_ARCHIVE() {
            "${CSCLI[@]}" support dump $SUPPORT_DUMP_FLAGS -f "$ARCHIVE" >&2
        }
        ;;
    docker)
        if [[ -z "$DOCKER_CONTAINER" ]]; then
            DOCKER_CONTAINER="$(docker ps --format '{{.Names}} {{.Image}}' \
                | awk '/(^|\/)crowdsec([: ]|$)/{print $1; exit}')"
        fi
        if [[ -z "$DOCKER_CONTAINER" ]]; then
            echo "could not identify crowdsec container; pass --container <name>" >&2
            exit 1
        fi
        CSCLI=(docker exec "$DOCKER_CONTAINER" cscli)
        FETCH_ARCHIVE() {
            local in_container="/tmp/crowdsec-support-${TS}.zip"
            docker exec "$DOCKER_CONTAINER" cscli support dump $SUPPORT_DUMP_FLAGS -f "$in_container" >&2
            docker cp "$DOCKER_CONTAINER:$in_container" "$ARCHIVE" >&2
            docker exec "$DOCKER_CONTAINER" rm -f "$in_container" 2>/dev/null || true
        }
        ;;
    k8s)
        if [[ -z "$K8S_NAMESPACE" ]]; then
            K8S_NAMESPACE="$(kubectl get pods -A 2>/dev/null \
                | awk '/crowdsec/{print $1; exit}')"
        fi
        if [[ -z "$K8S_POD" ]]; then
            K8S_POD="$(kubectl get pods -n "$K8S_NAMESPACE" 2>/dev/null \
                | awk '/crowdsec/ && !/bouncer/ {print $1; exit}')"
        fi
        if [[ -z "$K8S_POD" ]]; then
            echo "could not identify crowdsec pod; pass --namespace and --pod" >&2
            exit 1
        fi
        CSCLI=(kubectl exec -n "$K8S_NAMESPACE" "$K8S_POD" -- cscli)
        FETCH_ARCHIVE() {
            local in_pod="/tmp/crowdsec-support-${TS}.zip"
            kubectl exec -n "$K8S_NAMESPACE" "$K8S_POD" -- \
                cscli support dump $SUPPORT_DUMP_FLAGS -f "$in_pod" >&2
            kubectl cp "$K8S_NAMESPACE/$K8S_POD:$in_pod" "$ARCHIVE" >&2
            kubectl exec -n "$K8S_NAMESPACE" "$K8S_POD" -- rm -f "$in_pod" 2>/dev/null || true
        }
        ;;
    unknown|*)
        echo "CrowdSec not detected in systemd, docker, or k8s." >&2
        echo "If installed elsewhere, re-run with --env <systemd|docker|k8s>" >&2
        exit 1
        ;;
esac

# ---- collect the canonical archive ----
echo "Collecting cscli support dump → $ARCHIVE  (this can take 5–10 s)" >&2
if ! FETCH_ARCHIVE; then
    echo "ERROR: cscli support dump failed; archive at $ARCHIVE may be incomplete" >&2
    exit 1
fi

# Ensure the file is readable for unzip even when written under sudo
if [[ -f "$ARCHIVE" && ! -r "$ARCHIVE" ]]; then
    sudo -n chmod 644 "$ARCHIVE" 2>/dev/null || true
fi

if ! unzip -q "$ARCHIVE" -d "$EXTRACTED"; then
    echo "ERROR: could not unzip $ARCHIVE" >&2
    exit 1
fi

# Helper: pull text out of a known archive file if it exists
ARC() {  # ARC <relative-path-in-archive>
    local p="$EXTRACTED/$1"
    [[ -f "$p" ]] && cat "$p" || echo "(missing from archive: $1)"
}

# Helper: run a live cscli command (for things `support dump` doesn't capture)
run() { "${CSCLI[@]}" "$@" 2>&1; }

# ---- header ----
section "CrowdSec diagnose"
echo "Date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Host:        $(hostname)"
echo "Environment: $ENVKIND"
case "$ENVKIND" in
    docker) echo "Container:   $DOCKER_CONTAINER" ;;
    k8s)    echo "Namespace:   $K8S_NAMESPACE"; echo "Pod:         $K8S_POD" ;;
esac
echo "Archive:     $ARCHIVE   (full forensic snapshot — send this to support)"

# ---- service state (systemd only — implicit elsewhere) ----
if [[ "$ENVKIND" == "systemd" ]]; then
    section "Service state (systemd)"
    systemctl is-active crowdsec 2>&1 || true
    systemctl is-enabled crowdsec 2>&1 || true
    subsection "Recent unit log (journalctl)"
    journalctl -u crowdsec --no-pager -n 30 --output=short 2>&1 || true
fi

# ---- read from the archive ----
section "Version"
ARC "version.txt"

section "Feature flags"
ARC "features.txt"

section "Effective configuration (redacted)"
ARC "config/crowdsec.yaml"

section "Acquisition files"
for f in "$EXTRACTED/config/acquis/"*; do
    [[ -e "$f" ]] || continue
    # the archive encodes paths by replacing / with ___
    real_name="$(basename "$f" | sed 's|___|/|g')"
    subsection "$real_name"
    cat "$f"
done

section "Metrics (acquisition + parsers + scenarios + buckets + appsec)"
ARC "metrics/metrics.human"

section "Hub overview"
ARC "hub.txt"

section "LAPI status"
ARC "lapi_status.txt"

section "CAPI status"
ARC "capi_status.txt"

section "PAPI status"
ARC "papi_status.txt"

section "Bouncers"
ARC "lapi/bouncers.txt"

section "Machines (agents registered to LAPI)"
ARC "lapi/agents.txt"

# ---- live cscli for things the archive does not include ----
section "Alerts (last 50)  [live cscli]"
run alerts list -l 50

section "Decisions (active)  [live cscli]"
run decisions list

section "Simulation status  [live cscli]"
run simulation status

section "Allowlists  [live cscli]"
run allowlists list

# ---- log tails (from the archive — full files live in the zip) ----
section "Agent log tail (last $LOG_LINES lines)"
if [[ -f "$EXTRACTED/log/crowdsec.log" ]]; then
    tail -n "$LOG_LINES" "$EXTRACTED/log/crowdsec.log"
else
    echo "(no agent log in archive)"
fi

section "LAPI log tail (last $LOG_LINES lines)"
if [[ -f "$EXTRACTED/log/crowdsec_api.log" ]]; then
    tail -n "$LOG_LINES" "$EXTRACTED/log/crowdsec_api.log"
else
    echo "(no LAPI log in archive)"
fi

section "End of report"
echo "Full forensic archive saved at: $ARCHIVE"
echo "Includes pprof goroutine/heap dumps, prometheus metrics, full logs."
