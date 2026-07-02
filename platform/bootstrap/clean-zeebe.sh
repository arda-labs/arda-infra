#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

helm uninstall zeebe -n "$NAMESPACE" || true
helm uninstall zeebe85 -n "$NAMESPACE" || true

kubectl delete deploy zeebe-gateway -n "$NAMESPACE" --ignore-not-found
kubectl delete sts zeebe-broker -n "$NAMESPACE" --ignore-not-found
kubectl delete svc zeebe-gateway zeebe-gateway-nodeport zeebe-broker zeebe85-zeebe-gateway-nodeport -n "$NAMESPACE" --ignore-not-found
kubectl delete cm zeebe-broker-config zeebe-gateway-config zeebe-config zeebe85-configuration zeebe85-zeebe-gateway-configuration zeebe85-camunda-platform-release -n "$NAMESPACE" --ignore-not-found
kubectl delete pvc data-zeebe-broker-0 data-zeebe85-zeebe-0 -n "$NAMESPACE" --ignore-not-found

echo "Cleaned Zeebe resources only."
