#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

echo "This will uninstall NATS, Valkey, Garage, Zeebe and direct manifests in namespace: $NAMESPACE"
echo "It will NOT delete namespace automatically."
read -r -p "Continue? [y/N] " ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

helm uninstall "$NATS_RELEASE" -n "$NAMESPACE" || true
helm uninstall "$VALKEY_RELEASE" -n "$NAMESPACE" || true
helm uninstall "$GARAGE_RELEASE" -n "$NAMESPACE" || true
helm uninstall "$ZEEBE_RELEASE" -n "$NAMESPACE" || true

kubectl delete -k "$ROOT/manifests" --ignore-not-found || true

echo "Done. PVC may remain by design:"
kubectl get pvc -n "$NAMESPACE" || true
