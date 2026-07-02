#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

echo "== Namespace: $NAMESPACE =="
kubectl get ns "$NAMESPACE" || true

echo
echo "== Helm releases =="
helm list -n "$NAMESPACE" || true

echo
echo "== Workloads =="
kubectl get deploy,sts,ds -n "$NAMESPACE" -o wide || true

echo
echo "== Pods =="
kubectl get pods -n "$NAMESPACE" -o wide || true

echo
echo "== Services =="
kubectl get svc -n "$NAMESPACE" || true

echo
echo "== PVC =="
kubectl get pvc -n "$NAMESPACE" || true

echo
echo "== Ingress =="
kubectl get ingress -n "$NAMESPACE" || true

echo
echo "== Quick health hints =="
kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1, $2, $3}' || true
