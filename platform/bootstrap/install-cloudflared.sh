#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

if [ "$INSTALL_CLOUDFLARED" != "true" ]; then
  echo "Skip Cloudflared: INSTALL_CLOUDFLARED=false"
  exit 0
fi

ensure_ns

if ! kubectl get secret cloudflared-token -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Missing secret cloudflared-token."
  echo "Create it first:"
  echo "  cp secrets/examples/cloudflared-token-secret.yaml secrets/generated/cloudflared-token-secret.yaml"
  echo "  vi secrets/generated/cloudflared-token-secret.yaml"
  echo "  kubectl apply -f secrets/generated/cloudflared-token-secret.yaml"
  exit 1
fi

kubectl apply -f "$ROOT/manifests/cloudflared/cloudflared-deployment.yaml"
