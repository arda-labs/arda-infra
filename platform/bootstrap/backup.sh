#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

: "${NAMESPACE:?NAMESPACE must be set in platform.env}"
require_cmd kubectl
require_cmd helm
require_cmd sha256sum
require_cmd find
require_cmd sort

OUT="$ROOT/backups/platform-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT/helm" "$OUT/secrets" "$OUT/resources"

BACKUP_INCLUDE_SECRETS="${BACKUP_INCLUDE_SECRETS:-false}"
case "$BACKUP_INCLUDE_SECRETS" in
  true|false) ;;
  *) echo "BACKUP_INCLUDE_SECRETS must be true or false" >&2; exit 1 ;;
esac

cat > "$OUT/backup-metadata.env" <<EOF
BACKUP_FORMAT=platform-snapshot-v2
BACKUP_CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BACKUP_NAMESPACE=$NAMESPACE
BACKUP_INCLUDE_SECRETS=$BACKUP_INCLUDE_SECRETS
EOF

kubectl get all,cm,pvc,ingress -n "$NAMESPACE" -o yaml > "$OUT/resources/platform-resources.yaml"
helm list -n "$NAMESPACE" > "$OUT/helm-list.txt"

for r in $(helm list -n "$NAMESPACE" -q); do
  mkdir -p "$OUT/helm/$r"
  helm get values "$r" -n "$NAMESPACE" > "$OUT/helm/$r/values.yaml"
  helm get manifest "$r" -n "$NAMESPACE" > "$OUT/helm/$r/manifest.yaml"
done

if [ "$BACKUP_INCLUDE_SECRETS" = "true" ]; then
  require_cmd age
  : "${BACKUP_AGE_RECIPIENT:?Set BACKUP_AGE_RECIPIENT to encrypt secret snapshots}"
  for s in cloudflared-token garage-s3 garage-admin-secret garage-webui-secret valkey-auth; do
    kubectl get secret "$s" -n "$NAMESPACE" -o yaml \
      | age -r "$BACKUP_AGE_RECIPIENT" > "$OUT/secrets/$s.yaml.age"
  done
else
  rmdir "$OUT/secrets"
fi

(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 sha256sum
) > "$OUT/SHA256SUMS"

echo "Backup written to: $OUT"
