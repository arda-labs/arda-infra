#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

echo "== Preflight =="

require_cmd kubectl
require_cmd helm
require_cmd openssl
require_cmd awk
require_cmd grep

echo "kubectl: $(kubectl version --client=true 2>/dev/null | head -n1 || true)"
echo "helm: $(helm version --short 2>/dev/null || true)"

echo
echo "== Cluster access =="
kubectl cluster-info >/dev/null
echo "OK: cluster reachable"

echo
echo "== StorageClass =="
if kubectl get storageclass "$DEFAULT_STORAGE_CLASS" >/dev/null 2>&1; then
  echo "OK: StorageClass $DEFAULT_STORAGE_CLASS exists"
else
  echo "WARN: StorageClass $DEFAULT_STORAGE_CLASS not found"
  kubectl get storageclass || true
fi

echo
echo "== NodePort conflicts =="
for p in "$NATS_NODEPORT" "$VALKEY_NODEPORT" "$VALKEY_SENTINEL_NODEPORT" "$ZEEBE_GRPC_NODEPORT" "$ZEEBE_REST_NODEPORT" "$ZEEBE_METRICS_NODEPORT"; do
  if kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" "}{range .spec.ports[*]}{.nodePort}{" "}{end}{"\n"}{end}' | grep -w "$p" >/dev/null 2>&1; then
    echo "WARN: NodePort $p may already be used:"
    kubectl get svc -A -o wide | grep "$p" || true
  else
    echo "OK: NodePort $p appears free"
  fi
done

echo
echo "Preflight done."
