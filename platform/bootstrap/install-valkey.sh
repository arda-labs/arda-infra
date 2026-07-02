#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

if [ "$INSTALL_VALKEY" != "true" ]; then
  echo "Skip Valkey: INSTALL_VALKEY=false"
  exit 0
fi

require_cmd helm
require_cmd kubectl
ensure_ns

helm repo add bitnami https://charts.bitnami.com/bitnami || true
helm repo update

kubectl get secret valkey-auth -n "$NAMESPACE" >/dev/null 2>&1 || "$ROOT/bootstrap/create-secrets.sh"

helm upgrade --install "$VALKEY_RELEASE" bitnami/valkey \
  -n "$NAMESPACE" \
  -f "$ROOT/helm/valkey/values.yaml"

kubectl apply -f "$ROOT/manifests/nodeport/valkey-nodeport.yaml"
