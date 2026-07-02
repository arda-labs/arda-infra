#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

if [ "$INSTALL_ZEEBE" != "true" ]; then
  echo "Skip Zeebe: INSTALL_ZEEBE=false"
  exit 0
fi

require_cmd helm
require_cmd kubectl
ensure_ns

helm repo add camunda https://helm.camunda.io || true
helm repo update

helm upgrade --install "$ZEEBE_RELEASE" camunda/camunda-platform \
  -n "$NAMESPACE" \
  -f "$ROOT/helm/zeebe/values.yaml"

kubectl apply -f "$ROOT/manifests/nodeport/zeebe-gateway-nodeport.yaml"

echo "Zeebe installed. If chart reports secondary storage errors, keep INSTALL_ZEEBE=false until values are adjusted."
