#!/bin/bash
#
# llm-d Grafana Observability Setup Script
#
# This script sets up Grafana with Thanos-backed Prometheus on OpenShift
# to monitor llm-d (vLLM + EPP) workloads.
#
# Prerequisites:
#   - oc CLI logged into your OpenShift cluster
#   - Grafana Operator installed (from OperatorHub)
#   - llm-d-deployer repo cloned (for Sally's dashboard JSON)
#
# Usage:
#   ./setup.sh [--llm-d-deployer-path /path/to/llm-d-deployer]
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration -- Change these to match your environment
# ---------------------------------------------------------------------------
NAMESPACE="llm-d-monitoring"
LLM_D_DEPLOYER_PATH="${1:-/Users/njajodia/llm-d-deployer}"
DASHBOARD_JSON_PATH="${LLM_D_DEPLOYER_PATH}/quickstart/grafana/dashboards/llm-d-dashboard.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
info "Running pre-flight checks..."

command -v oc >/dev/null 2>&1 || error "oc CLI not found. Please install it first."
oc whoami >/dev/null 2>&1    || error "Not logged into OpenShift. Run 'oc login' first."

if [ ! -f "$DASHBOARD_JSON_PATH" ]; then
    warn "Sally's dashboard JSON not found at: $DASHBOARD_JSON_PATH"
    warn "The vLLM dashboard will not be created. Clone llm-d-deployer and re-run."
    warn "  git clone https://github.com/llm-d/llm-d-deployer.git"
    HAS_DASHBOARD_JSON=false
else
    info "Found Sally's dashboard JSON at: $DASHBOARD_JSON_PATH"
    HAS_DASHBOARD_JSON=true
fi

# Check Grafana Operator is installed
if ! oc get crd grafanas.grafana.integreatly.org >/dev/null 2>&1; then
    error "Grafana Operator CRD not found. Install the Grafana Operator from OperatorHub first."
fi
info "Grafana Operator is installed."

echo ""
info "============================================"
info "  llm-d Grafana Observability Setup"
info "============================================"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Create Namespace
# ---------------------------------------------------------------------------
info "Step 1/7: Creating namespace '${NAMESPACE}'..."
oc apply -f "${MANIFESTS_DIR}/01-namespace.yaml"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Create Grafana Instance
# ---------------------------------------------------------------------------
info "Step 2/7: Creating Grafana instance..."
oc apply -f "${MANIFESTS_DIR}/02-grafana-instance.yaml"

# Wait for Grafana pod to be ready
info "  Waiting for Grafana pod to start (this takes ~30-60 seconds)..."
for i in $(seq 1 60); do
    if oc get pods -n "$NAMESPACE" -l app=grafana --no-headers 2>/dev/null | grep -q "Running"; then
        info "  Grafana pod is running."
        break
    fi
    sleep 2
done
echo ""

# ---------------------------------------------------------------------------
# Step 3: Create ServiceAccount + Permanent Token
# ---------------------------------------------------------------------------
info "Step 3/7: Creating ServiceAccount and permanent token..."
oc apply -f "${MANIFESTS_DIR}/03-serviceaccount.yaml"

# Wait for token to be populated
info "  Waiting for token to be generated..."
for i in $(seq 1 30); do
    TOKEN=$(oc get secret grafana-thanos-token -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -n "$TOKEN" ]; then
        info "  Permanent token created successfully."
        break
    fi
    sleep 2
done

if [ -z "${TOKEN:-}" ]; then
    error "Failed to get token from secret. Check: oc get secret grafana-thanos-token -n $NAMESPACE"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 4: Create ClusterRoleBinding
# ---------------------------------------------------------------------------
info "Step 4/7: Granting cluster-monitoring-view role..."
oc apply -f "${MANIFESTS_DIR}/04-clusterrolebinding.yaml"
echo ""

# ---------------------------------------------------------------------------
# Step 5: Create GrafanaDatasource (with real token injected)
# ---------------------------------------------------------------------------
info "Step 5/7: Creating GrafanaDatasource (Thanos Querier)..."
sed "s|TOKEN_PLACEHOLDER|${TOKEN}|g" "${MANIFESTS_DIR}/05-datasource.yaml" | oc apply -f -
echo ""

# ---------------------------------------------------------------------------
# Step 6: Create Dashboard -- EPP Routing and Pool Health
# ---------------------------------------------------------------------------
info "Step 6/7: Creating dashboard: EPP Routing and Pool Health..."
oc apply -f "${MANIFESTS_DIR}/06-dashboard-epp-routing-and-pool-health.yaml"
echo ""

# ---------------------------------------------------------------------------
# Step 7: Create Dashboard -- vLLM Latency, Throughput, and Cache
# ---------------------------------------------------------------------------
if [ "$HAS_DASHBOARD_JSON" = true ]; then
    info "Step 7/7: Creating dashboard: vLLM Latency, Throughput, and Cache..."

    # Create ConfigMap from Sally's JSON (replacing datasource variable)
    if oc get configmap vllm-latency-throughput-and-cache-json -n "$NAMESPACE" >/dev/null 2>&1; then
        warn "  ConfigMap already exists, deleting and recreating..."
        oc delete configmap vllm-latency-throughput-and-cache-json -n "$NAMESPACE"
    fi

    # Two replacements:
    # 1. ${DS_PROMETHEUS} -> prometheus  (datasource UID)
    # 2. vllm: -> kserve_vllm:          (RHOAI uses kserve_ prefix for vLLM metrics)
    sed 's/${DS_PROMETHEUS}/prometheus/g' "$DASHBOARD_JSON_PATH" | \
        sed 's/vllm:/kserve_vllm:/g' | \
        oc create configmap vllm-latency-throughput-and-cache-json \
        --from-file=dashboard.json=/dev/stdin \
        -n "$NAMESPACE"

    # Create the GrafanaDashboard CR
    oc apply -f "${MANIFESTS_DIR}/07-dashboard-vllm-latency-throughput-and-cache.yaml"
else
    warn "Step 7/7: SKIPPED -- Sally's dashboard JSON not found."
    warn "  To add it later, clone llm-d-deployer and run:"
    warn "    sed 's/\${DS_PROMETHEUS}/prometheus/g' /path/to/llm-d-dashboard.json | \\"
    warn "      oc create configmap vllm-latency-throughput-and-cache-json \\"
    warn "      --from-file=dashboard.json=/dev/stdin -n $NAMESPACE"
    warn "    oc apply -f manifests/07-dashboard-vllm-latency-throughput-and-cache.yaml"
fi
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
info "============================================"
info "  Setup Complete!"
info "============================================"
echo ""

# Get Grafana Route
GRAFANA_URL=$(oc get route -n "$NAMESPACE" -l app=grafana -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "not-found")

info "Grafana URL:      https://${GRAFANA_URL}"
info "Username:         admin"
info "Password:         admin123"
echo ""

info "Resources created:"
echo ""
oc get grafana,grafanadatasource,grafanadashboard -n "$NAMESPACE" 2>/dev/null
echo ""

info "Dashboards:"
info "  1. EPP Routing and Pool Health   -- What the EPP/routing layer sees"
info "  2. vLLM Latency, Throughput, and Cache -- What the vLLM model server is doing"
echo ""
info "To tear down everything:  ./teardown.sh"
