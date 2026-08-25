#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${APP_NAMESPACE:-arda-app}"
SECRET_NAME="${APP_SECRET_NAME:-arda-app-secrets}"
REQUIRE_MTLS="${REQUIRE_MTLS:-true}"

command -v kubectl >/dev/null 2>&1 || { echo "Missing command: kubectl" >&2; exit 1; }

required_keys=(
    ARDA_SERVICE_AUTH_SECRET
    AI_DATABASE_DSN
    IAM_DATABASE_DSN
  PLATFORM_DATABASE_DSN
  FINANCE_DATABASE_DSN
  MEDIA_DATABASE_DSN
  WORKFLOW_DATABASE_DSN
  CRM_DATABASE_DSN
  HRM_DATABASE_DSN
  NOTIFICATION_DATABASE_DSN
  REDIS_URL
  NATS_URL
)

for key in "${required_keys[@]}"; do
  value="$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o "jsonpath={.data.$key}" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    echo "Missing non-empty key: $NAMESPACE/$SECRET_NAME:$key" >&2
    exit 1
  fi
done

if [[ "$REQUIRE_MTLS" == "true" ]]; then
  for service in crm iam platform workflow hrm finance media notification; do
    secret="arda-grpc-tls-$service"
    kubectl get secret "$secret" -n "$NAMESPACE" >/dev/null
    for key in ca.crt tls.crt tls.key; do
      value="$(kubectl get secret "$secret" -n "$NAMESPACE" -o "jsonpath={.data.$key}" 2>/dev/null || true)"
      if [[ -z "$value" ]]; then
        echo "Missing non-empty key: $NAMESPACE/$secret:$key" >&2
        exit 1
      fi
    done
  done
fi

echo "Runtime secret references OK: $NAMESPACE/$SECRET_NAME"
