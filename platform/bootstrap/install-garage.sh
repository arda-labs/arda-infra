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

helm repo add garage https://garagehq.deuxfleurs.fr/_releases/helm-charts/ || true
helm repo update || true

if helm search repo garage/garage >/dev/null 2>&1; then
  GARAGE_CHART="garage/garage"
elif [ -d "$ROOT/charts/garage" ]; then
  GARAGE_CHART="$ROOT/charts/garage"
else
  echo "Cannot find Garage Helm chart."
  echo "Put your existing Garage chart at: $ROOT/charts/garage"
  exit 1
fi

"$ROOT/bootstrap/create-secrets.sh"

helm upgrade --install "$GARAGE_RELEASE" "$GARAGE_CHART" \
  -n "$NAMESPACE" \
  -f "$ROOT/helm/garage/values.yaml"

echo "Applying Garage helper manifests..."
for f in \
  "$ROOT/manifests/garage/garage-admin-svc.yaml" \
  "$ROOT/manifests/garage/garage-webui.yaml" \
  "$ROOT/manifests/garage/garage-webui-ingress.yaml" \
  "$ROOT/manifests/garage/garage-s3-ingress.yaml"
do
  [ -f "$f" ] && kubectl apply -f "$f" || true
done

echo
echo "Next:"
echo "  ./bootstrap/init-garage.sh"
