#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

OUT="$ROOT/backups/platform-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/helm" "$OUT/secrets" "$OUT/resources"

kubectl get all,cm,secret,pvc,ingress -n "$NAMESPACE" -o yaml > "$OUT/resources/platform-resources.yaml" || true
helm list -n "$NAMESPACE" > "$OUT/helm-list.txt" || true

for r in $(helm list -n "$NAMESPACE" -q); do
  mkdir -p "$OUT/helm/$r"
  helm get values "$r" -n "$NAMESPACE" > "$OUT/helm/$r/values.yaml" || true
  helm get manifest "$r" -n "$NAMESPACE" > "$OUT/helm/$r/manifest.yaml" || true
done

for s in cloudflared-token garage-s3 garage-admin-secret garage-webui-secret valkey-auth; do
  kubectl get secret "$s" -n "$NAMESPACE" -o yaml > "$OUT/secrets/$s.yaml" 2>/dev/null || true
done

echo "Backup written to: $OUT"
