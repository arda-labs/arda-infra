#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

if [ "$INSTALL_GARAGE" != "true" ]; then
  echo "Skip Garage: INSTALL_GARAGE=false"
  exit 0
fi

require_cmd helm
require_cmd kubectl
ensure_ns

if helm search repo garage/garage >/dev/null 2>&1; then
  GARAGE_CHART="garage/garage"
elif [ -d "$ROOT/charts/garage" ]; then
  GARAGE_CHART="$ROOT/charts/garage"
else
  require_cmd git
  GARAGE_SRC="$ROOT/runtime/garage-src"
  GARAGE_CHART="$GARAGE_SRC/script/helm/garage"
  if [ ! -d "$GARAGE_CHART" ]; then
    rm -rf "$GARAGE_SRC"
    git clone --depth 1 https://git.deuxfleurs.fr/Deuxfleurs/garage "$GARAGE_SRC"
  fi
fi

"$ROOT/bootstrap/create-secrets.sh"

helm upgrade --install "$GARAGE_RELEASE" "$GARAGE_CHART" \
  -n "$NAMESPACE" \
  -f "$ROOT/helm/garage/values.yaml"

ADMIN_TOKEN="$(kubectl get secret garage-admin-secret -n "$NAMESPACE" -o jsonpath='{.data.GARAGE_ADMIN_TOKEN}' | base64 -d)"
CONFIG_TMP="$(mktemp)"
PATCHED_TMP="$(mktemp)"
kubectl get configmap "$GARAGE_RELEASE-config" -n "$NAMESPACE" -o jsonpath='{.data.garage\.toml}' > "$CONFIG_TMP"
awk -v token="$ADMIN_TOKEN" '
  $0 == "[admin]" { in_admin=1; found=0; print; next }
  in_admin && $0 ~ /^admin_token[[:space:]]*=/ { print "admin_token = \"" token "\""; found=1; next }
  in_admin && $0 ~ /^\[/ {
    if (!found) print "admin_token = \"" token "\""
    in_admin=0
  }
  { print }
  END {
    if (in_admin && !found) print "admin_token = \"" token "\""
  }
' "$CONFIG_TMP" > "$PATCHED_TMP"
kubectl create configmap "$GARAGE_RELEASE-config" -n "$NAMESPACE" \
  --from-file=garage.toml="$PATCHED_TMP" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart "statefulset/$GARAGE_RELEASE" -n "$NAMESPACE"
rm -f "$CONFIG_TMP" "$PATCHED_TMP"

kubectl create secret generic garage-webui-secret -n "$NAMESPACE" \
  --from-literal=GARAGE_ADMIN_TOKEN="$ADMIN_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Applying Garage helper manifests..."
for f in \
  "$ROOT/manifests/garage/garage-admin-svc.yaml" \
  "$ROOT/manifests/garage/garage-webui.yaml" \
  "$ROOT/manifests/garage/garage-webui-ingress.yaml" \
  "$ROOT/manifests/garage/garage-s3-ingress.yaml"
do
  [ -f "$f" ] && kubectl apply -f "$f" || true
done

kubectl rollout restart deployment/garage-webui -n "$NAMESPACE" >/dev/null 2>&1 || true
kubectl rollout status deployment/garage-webui -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 || true

echo
echo "Next:"
echo "  ./bootstrap/init-garage.sh"
