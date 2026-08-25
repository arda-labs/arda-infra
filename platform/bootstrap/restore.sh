#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

usage() {
  cat >&2 <<'EOF'
Usage: restore.sh --source <backup-directory> [--target-namespace <isolated-namespace>]

This command verifies a platform snapshot and prints the next safe restore steps.
It never applies a snapshot and it rejects the production namespace as a target.
Database restore is a separate service-owned procedure and is not implied by this
platform resource snapshot.
EOF
  exit 2
}

SOURCE=""
TARGET_NAMESPACE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || usage
      SOURCE="$2"
      shift 2
      ;;
    --target-namespace)
      [ "$#" -ge 2 ] || usage
      TARGET_NAMESPACE="$2"
      [ -n "$TARGET_NAMESPACE" ] || { echo "Target namespace must not be empty" >&2; exit 1; }
      shift 2
      ;;
    *) usage ;;
  esac
done

[ -n "$SOURCE" ] || usage
case "$SOURCE" in
  /*) ;;
  *) SOURCE="$ROOT/$SOURCE" ;;
esac
[ -d "$SOURCE" ] || { echo "Backup directory not found: $SOURCE" >&2; exit 1; }
[ -f "$SOURCE/SHA256SUMS" ] || { echo "Missing SHA256SUMS: $SOURCE" >&2; exit 1; }
[ -f "$SOURCE/backup-metadata.env" ] || { echo "Missing backup metadata: $SOURCE" >&2; exit 1; }

require_cmd sha256sum
(
  cd "$SOURCE"
  sha256sum -c SHA256SUMS
)

if [ -n "$TARGET_NAMESPACE" ] && [ "$TARGET_NAMESPACE" = "platform" ]; then
  echo "Refusing restore target namespace platform; use an isolated namespace." >&2
  exit 1
fi

echo "Backup verification passed: $SOURCE"
if [ -n "$TARGET_NAMESPACE" ]; then
  echo "Requested isolated target: $TARGET_NAMESPACE"
else
  echo "No target namespace supplied; verification only."
fi
echo "Next steps require an operator-reviewed Helm/database restore plan."
echo "This snapshot does not contain plaintext Kubernetes Secret data."
