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

if [ -f "$ROOT/charts/garage/Chart.yaml" ]; then
  GARAGE_CHART="$ROOT/charts/garage"
else
  require_cmd git
  GARAGE_SRC="$ROOT/runtime/garage-src"
  GARAGE_CHART="$GARAGE_SRC/script/helm/garage"
  if [ ! -f "$GARAGE_CHART/Chart.yaml" ]; then
    if [ -d "$GARAGE_SRC/.git" ]; then
      git -C "$GARAGE_SRC" pull --ff-only
    elif [ -e "$GARAGE_SRC" ]; then
      echo "Garage source exists but is not a Git checkout: $GARAGE_SRC" >&2
      exit 1
    else
      git clone --depth 1 https://git.deuxfleurs.fr/Deuxfleurs/garage "$GARAGE_SRC"
    fi
  fi
fi

if [ ! -f "$GARAGE_CHART/Chart.yaml" ]; then
  echo "Garage Helm chart not found: $GARAGE_CHART" >&2
  exit 1
fi

"$ROOT/bootstrap/create-secrets.sh"

helm upgrade --install "$GARAGE_RELEASE" "$GARAGE_CHART" \
  -n "$NAMESPACE" \
  -f "$ROOT/helm/garage/values.yaml"

ADMIN_TOKEN="$(kubectl get secret garage-admin-secret -n "$NAMESPACE" -o jsonpath='{.data.GARAGE_ADMIN_TOKEN}' | base64 -d)"
CONFIG_TMP="$(mktemp)"
PATCHED_TMP="$(mktemp)"
kubectl get configmap "$GARAGE_RELEASE-config" -n "$NAMESPACE" -o jsonpath='{.data.garage\.toml}' > "$CONFIG_TMP"
if grep -q '^admin_token[[:space:]]*=' "$CONFIG_TMP"; then
  awk -v token="$ADMIN_TOKEN" '
    /^admin_token[[:space:]]*=/ { print "admin_token = \"" token "\""; next }
    { print }
  ' "$CONFIG_TMP" > "$PATCHED_TMP"
elif grep -q '^\[admin\][[:space:]]*$' "$CONFIG_TMP"; then
  awk -v token="$ADMIN_TOKEN" '
    /^\[admin\][[:space:]]*$/ { print; print "admin_token = \"" token "\""; next }
    { print }
  ' "$CONFIG_TMP" > "$PATCHED_TMP"
else
  cat "$CONFIG_TMP" > "$PATCHED_TMP"
  printf '\n[admin]\nadmin_token = "%s"\n' "$ADMIN_TOKEN" >> "$PATCHED_TMP"
fi
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
  "$ROOT/manifests/garage/garage-s3-cors-middleware.yaml" \
  "$ROOT/manifests/garage/garage-s3-ingress.yaml"
do
  [ -f "$f" ] && kubectl apply -f "$f" || true
done

kubectl rollout restart deployment/garage-webui -n "$NAMESPACE" >/dev/null 2>&1 || true
kubectl rollout status deployment/garage-webui -n "$NAMESPACE" --timeout=120s >/dev/null 2>&1 || true

echo
echo "Next:"
echo "  ./bootstrap/init-garage.sh"
