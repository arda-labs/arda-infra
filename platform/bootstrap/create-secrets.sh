#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env
ensure_ns

if ! kubectl get secret valkey-auth -n "$NAMESPACE" >/dev/null 2>&1; then
  VALKEY_PASSWORD="$(openssl rand -base64 32 | tr -d '\r\n')"
  kubectl create secret generic valkey-auth -n "$NAMESPACE" \
    --from-literal=password="$VALKEY_PASSWORD" \
    --from-literal=valkey-password="$VALKEY_PASSWORD"
  echo "Created secret: valkey-auth"
else
  echo "Exists: valkey-auth"
fi

if ! kubectl get secret garage-admin-secret -n "$NAMESPACE" >/dev/null 2>&1; then
  GARAGE_ADMIN_TOKEN="$(openssl rand -hex 32)"
  kubectl create secret generic garage-admin-secret -n "$NAMESPACE" \
    --from-literal=GARAGE_ADMIN_TOKEN="$GARAGE_ADMIN_TOKEN"
  echo "Created secret: garage-admin-secret"
else
  echo "Exists: garage-admin-secret"
fi

echo "Cloudflared secret is not auto-generated."
