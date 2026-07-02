#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

if [ "$INSTALL_NATS" != "true" ]; then
  echo "Skip NATS: INSTALL_NATS=false"
  exit 0
fi

require_cmd helm
require_cmd kubectl
ensure_ns

helm repo add nats https://nats-io.github.io/k8s/helm/charts/ || true
helm repo update

helm upgrade --install "$NATS_RELEASE" nats/nats \
  -n "$NAMESPACE" \
  -f "$ROOT/helm/nats/values.yaml"

kubectl apply -f "$ROOT/manifests/nodeport/nats-nodeport.yaml"
