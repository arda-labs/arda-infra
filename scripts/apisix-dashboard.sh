#!/usr/bin/env bash
set -euo pipefail

LOCAL_PORT="${LOCAL_PORT:-9180}"
NAMESPACE="${NAMESPACE:-gateway}"
SERVICE="${SERVICE:-svc/apisix-admin}"

admin_key="$(
  kubectl -n "$NAMESPACE" get configmap apisix -o jsonpath='{.data.config\.yaml}' |
    awk '
      $1 == "-" && $2 == "name:" && $3 ~ /^"?admin"?$/ { in_admin = 1; next }
      in_admin && $1 == "key:" { gsub(/"/, "", $2); key = $2; next }
      in_admin && $1 == "role:" && $2 == "admin" { print key; exit }
    '
)"

echo "APISIX Dashboard: http://127.0.0.1:${LOCAL_PORT}/ui/"
if [ -n "$admin_key" ]; then
  echo "Admin API key: ${admin_key}"
else
  echo "Admin API key: inspect ConfigMap gateway/apisix if the UI asks for it."
fi
echo "Press Ctrl+C to stop the tunnel."

kubectl -n "$NAMESPACE" port-forward "$SERVICE" "${LOCAL_PORT}:9180"
