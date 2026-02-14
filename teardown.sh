#!/bin/bash
#
# Tear down the llm-d Grafana Observability stack
#
set -euo pipefail

NAMESPACE="llm-d-monitoring"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
info "Tearing down llm-d Grafana Observability..."
echo ""

# Delete in reverse order
info "Deleting dashboards..."
oc delete -f "${MANIFESTS_DIR}/07-dashboard-vllm-latency-throughput-and-cache.yaml" --ignore-not-found
oc delete -f "${MANIFESTS_DIR}/06-dashboard-epp-routing-and-pool-health.yaml" --ignore-not-found

info "Deleting ConfigMap (vLLM dashboard JSON)..."
oc delete configmap vllm-latency-throughput-and-cache-json -n "$NAMESPACE" --ignore-not-found

info "Deleting datasource..."
oc delete -f "${MANIFESTS_DIR}/05-datasource.yaml" --ignore-not-found

info "Deleting ClusterRoleBinding..."
oc delete -f "${MANIFESTS_DIR}/04-clusterrolebinding.yaml" --ignore-not-found

info "Deleting ServiceAccount and token..."
oc delete -f "${MANIFESTS_DIR}/03-serviceaccount.yaml" --ignore-not-found

info "Deleting Grafana instance..."
oc delete -f "${MANIFESTS_DIR}/02-grafana-instance.yaml" --ignore-not-found

warn "Namespace '${NAMESPACE}' is NOT deleted (in case you have other resources there)."
warn "To delete it manually: oc delete namespace ${NAMESPACE}"

echo ""
info "Teardown complete."
