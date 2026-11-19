#!/usr/bin/env bash
set -euo pipefail

# Back up the Sealed Secrets private keys, encrypted with age.
#
#   BACKUP_AGE_RECIPIENT=age1... platform/bootstrap/backup-sealing-key.sh [out-dir]
#
# Without these keys every secrets/**/*.sealed.yaml in Git is unreadable after
# the cluster is lost. The controller renews its key every 30 days and keeps
# the old ones, so run this after the first sync AND after every renewal
# (monthly), and store the .age file OFF the cluster: password manager or the
# R2 bucket used for Postgres backups. Never commit it.
#
# Restore: docs/secret-management.md §5.

command -v kubectl >/dev/null 2>&1 || { echo "Missing command: kubectl" >&2; exit 1; }
command -v age >/dev/null 2>&1 || { echo "Missing command: age" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "Missing command: sha256sum" >&2; exit 1; }
: "${BACKUP_AGE_RECIPIENT:?Set BACKUP_AGE_RECIPIENT (age public key) to encrypt the key backup}"

CONTROLLER_NS="${SEALED_SECRETS_CONTROLLER_NAMESPACE:-kube-system}"
OUT_DIR="${1:-.}"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/sealed-secrets-keys-$(date -u +%Y%m%dT%H%M%SZ).yaml.age"

count="$(kubectl get secret -n "$CONTROLLER_NS" -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l | tr -d ' ')"
if [ "$count" -eq 0 ]; then
  echo "No sealing keys found in $CONTROLLER_NS; is the controller installed?" >&2
  exit 1
fi

# Plaintext goes straight from kubectl into age; it never touches the disk.
kubectl get secret -n "$CONTROLLER_NS" -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  | age -r "$BACKUP_AGE_RECIPIENT" > "$OUT"

sha256sum "$OUT" > "$OUT.sha256"
echo "Backed up $count sealing key(s) to $OUT (age-encrypted). Move it off the cluster now."
