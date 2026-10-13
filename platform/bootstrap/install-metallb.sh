#!/usr/bin/env bash
set -euo pipefail

# LAN VIPs through MetalLB L2. Only Services with
# loadBalancerClass: metallb.io/l2 are served; Traefik stays on k3s ServiceLB.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

if [ "$INSTALL_METALLB" != "true" ]; then
  echo "Skip MetalLB: INSTALL_METALLB=false"
  exit 0
fi

require_cmd helm
require_cmd kubectl

helm repo add metallb https://metallb.github.io/metallb || true
helm repo update metallb

helm upgrade --install "$METALLB_RELEASE" metallb/metallb \
  -n "$METALLB_NAMESPACE" --create-namespace \
  --version "$METALLB_CHART_VERSION" \
  -f "$ROOT/helm/metallb/values.yaml" \
  --wait

# The pool's validating webhook is served by the controller; wait for it before
# applying, or the apply fails with "connection refused".
kubectl -n "$METALLB_NAMESPACE" rollout status deploy/"$METALLB_RELEASE"-controller --timeout=120s
kubectl apply -f "$ROOT/manifests/metallb/pool.yaml"
