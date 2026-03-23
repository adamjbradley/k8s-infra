#!/bin/bash
# Local development setup using Docker Desktop Kubernetes (or kind).
# This script installs a minimal subset of the infra stack locally:
#   1. ingress-nginx (NodePort)
#   2. nginx reverse proxy (in-cluster, fronting ingress-nginx)
#   3. monitoring (Prometheus + Grafana) with reduced resources
#   4. logging (Elasticsearch + Kibana + logging operator) with reduced resources
#   5. keycloak (single replica with embedded PostgreSQL)
#
# Prerequisites:
#   - Docker Desktop with Kubernetes enabled, OR kind installed
#   - helm, kubectl on PATH
#
# Usage: ./setup.sh [component]
#   ./setup.sh          # install all components
#   ./setup.sh ingress  # install only ingress-nginx
#   ./setup.sh nginx    # install nginx reverse proxy
#   ./setup.sh keycloak # install keycloak + embedded postgres
#   ./setup.sh monitoring
#   ./setup.sh logging
#   ./setup.sh teardown # remove everything

set -e
set -o errexit
set -o nounset
set -o errtrace
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPONENT="${1:-all}"

# ---------- helpers ----------

check_prerequisites() {
  local missing=0
  for cmd in kubectl helm docker; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "ERROR: '$cmd' is required but not found on PATH."
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then exit 1; fi

  # Verify kubectl can reach a cluster
  if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: No Kubernetes cluster reachable."
    echo "  - Docker Desktop: Settings -> Kubernetes -> Enable Kubernetes"
    echo "  - kind: kind create cluster --name dpi-local"
    exit 1
  fi
  echo "Cluster reachable: $(kubectl config current-context)"
}

add_helm_repos() {
  echo "Adding Helm repos..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
  helm repo add mosip https://mosip.github.io/mosip-helm 2>/dev/null || true
  helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
  helm repo update
}

# ---------- components ----------

install_ingress() {
  echo "=== Installing ingress-nginx (NodePort) ==="
  kubectl create namespace ingress-nginx 2>/dev/null || true
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --version 4.0.18 \
    -f "$INFRA_DIR/ingress/ingress-nginx/ingress-nginx-np.values.yaml" \
    --wait
  echo "ingress-nginx installed. HTTP on NodePort 30080, HTTPS on 30443."
}

install_nginx() {
  echo "=== Installing Nginx reverse proxy (in-cluster) ==="
  kubectl apply -f "$SCRIPT_DIR/nginx-local.yaml"
  kubectl -n nginx-local rollout status deploy/nginx --timeout=60s
  echo "Nginx installed. NodePort 30000 -> forwards to ingress-nginx."
  echo "  Access: http://localhost:30000"
}

install_keycloak() {
  echo "=== Installing Keycloak (local) ==="
  # Uses official quay.io/keycloak/keycloak image in dev mode (embedded H2 DB).
  # Bitnami chart images are no longer available on Docker Hub.
  kubectl apply -f "$SCRIPT_DIR/keycloak-local.yaml"
  kubectl -n keycloak rollout status deploy/keycloak --timeout=180s
  echo "Keycloak installed."
  echo "  Admin console: kubectl -n keycloak port-forward svc/keycloak 8080:80"
  echo "  Then open: http://localhost:8080"
  echo "  Credentials: admin / admin"
  echo "  Or via ingress: http://iam.localhost:30080 (add '127.0.0.1 iam.localhost' to hosts file)"
}

install_monitoring() {
  echo "=== Installing Monitoring (local) ==="
  local NS=cattle-monitoring-system
  kubectl create namespace "$NS" 2>/dev/null || true

  echo "Installing monitoring CRDs..."
  helm upgrade --install rancher-monitoring-crd mosip/rancher-monitoring-crd \
    -n "$NS" --wait

  echo "Installing monitoring stack..."
  helm upgrade --install rancher-monitoring mosip/rancher-monitoring \
    -n "$NS" \
    -f "$INFRA_DIR/monitoring/values.yaml" \
    -f "$SCRIPT_DIR/monitoring-values-local.yaml" \
    --set global.cattle.clusterId=local \
    --set grafana.global.cattle.clusterId=local
  echo "Monitoring installed."
  echo "  Grafana: kubectl -n $NS port-forward svc/rancher-monitoring-grafana 3000:80"
  echo "  Prometheus: kubectl -n $NS port-forward svc/rancher-monitoring-prometheus 9090:9090"
}

install_logging() {
  echo "=== Installing Logging (local) ==="
  local NS=cattle-logging-system
  kubectl create namespace "$NS" 2>/dev/null || true

  echo "Installing Elasticsearch + Kibana..."
  helm upgrade --install elasticsearch mosip/elasticsearch \
    -n "$NS" \
    -f "$INFRA_DIR/logging/es_values.yaml" \
    -f "$SCRIPT_DIR/logging-values-local.yaml" \
    --version 17.9.25 \
    --set image.repository="mosipint/elasticsearch" \
    --set image.tag="7.17.2-debian-10-r4" \
    --set kibana.image.repository="mosipint/kibana" \
    --set kibana.image.tag="7.17.2-debian-10-r0" \
    --set kibana.image.pullPolicy="IfNotPresent" \
    --wait --timeout 5m

  echo "Installing logging CRDs..."
  helm upgrade --install rancher-logging-crd mosip/rancher-logging-crd \
    -n "$NS" --wait

  echo "Installing logging operator..."
  helm upgrade --install rancher-logging mosip/rancher-logging \
    -n "$NS" \
    -f "$INFRA_DIR/logging/values.yaml"

  echo "Logging installed."
  echo "  Kibana: kubectl -n $NS port-forward svc/elasticsearch-kibana 5601:5601"
}

teardown() {
  echo "=== Tearing down local stack ==="
  helm uninstall rancher-logging      -n cattle-logging-system    2>/dev/null || true
  helm uninstall rancher-logging-crd  -n cattle-logging-system    2>/dev/null || true
  helm uninstall elasticsearch        -n cattle-logging-system    2>/dev/null || true
  kubectl delete -f "$SCRIPT_DIR/keycloak-local.yaml"            2>/dev/null || true
  helm uninstall rancher-monitoring   -n cattle-monitoring-system 2>/dev/null || true
  helm uninstall rancher-monitoring-crd -n cattle-monitoring-system 2>/dev/null || true
  helm uninstall ingress-nginx        -n ingress-nginx            2>/dev/null || true
  kubectl delete -f "$SCRIPT_DIR/nginx-local.yaml"               2>/dev/null || true
  kubectl delete namespace keycloak                 2>/dev/null || true
  kubectl delete namespace cattle-logging-system    2>/dev/null || true
  kubectl delete namespace cattle-monitoring-system 2>/dev/null || true
  kubectl delete namespace ingress-nginx            2>/dev/null || true
  echo "Teardown complete."
}

# ---------- main ----------

check_prerequisites

case "$COMPONENT" in
  teardown)
    teardown
    ;;
  ingress)
    add_helm_repos
    install_ingress
    ;;
  nginx)
    install_nginx
    ;;
  keycloak)
    add_helm_repos
    install_keycloak
    ;;
  monitoring)
    add_helm_repos
    install_monitoring
    ;;
  logging)
    add_helm_repos
    install_logging
    ;;
  all)
    add_helm_repos
    install_ingress
    install_nginx
    install_keycloak
    install_monitoring
    install_logging
    ;;
  *)
    echo "Unknown component: $COMPONENT"
    echo "Usage: $0 [all|ingress|nginx|keycloak|monitoring|logging|teardown]"
    echo ""
    echo "For MOSIP components, see mosip-infra/deployment/v3/local/"
    exit 1
    ;;
esac

echo ""
echo "Done! Use 'kubectl get pods -A' to check status."
