#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

POD="$(kubectl get pod -n "$NAMESPACE" | awk '/garage-[0-9]+/ {print $1; exit}')"

if [ -z "$POD" ]; then
  echo "Cannot find Garage pod."
  kubectl get pods -n "$NAMESPACE"
  exit 1
fi

echo "Using Garage pod: $POD"

kubectl exec -n "$NAMESPACE" "$POD" -- garage status || true

echo
echo "Trying to assign layout..."
NODE_IDS="$(kubectl exec -n "$NAMESPACE" "$POD" -- garage status 2>/dev/null | awk '/^[0-9a-f]{16,}/ {print $1}' || true)"
if [ -n "$NODE_IDS" ]; then
  for id in $NODE_IDS; do
    kubectl exec -n "$NAMESPACE" "$POD" -- garage layout assign "$id" -z dc1 -c 1G || true
  done
  kubectl exec -n "$NAMESPACE" "$POD" -- garage layout apply --version 1 || true
fi

echo
echo "Create bucket if missing: $GARAGE_BUCKET"
kubectl exec -n "$NAMESPACE" "$POD" -- garage bucket create "$GARAGE_BUCKET" || true

echo
echo "Create S3 key."
KEY_OUTPUT="$(kubectl exec -n "$NAMESPACE" "$POD" -- garage key new --name arda-app 2>/dev/null || true)"
echo "$KEY_OUTPUT"

ACCESS_KEY="$(echo "$KEY_OUTPUT" | awk '/Key ID|Access key|Garage key/ {print $NF; exit}')"
SECRET_KEY="$(echo "$KEY_OUTPUT" | awk '/Secret key|Secret/ {print $NF; exit}')"

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
  echo
  echo "Could not parse key automatically."
  echo "Run manually:"
  echo "  kubectl exec -it -n $NAMESPACE $POD -- garage key new --name arda-app"
  echo "  kubectl exec -it -n $NAMESPACE $POD -- garage bucket allow --read --write --owner $GARAGE_BUCKET <ACCESS_KEY>"
  echo "  kubectl create secret generic garage-s3 -n $NAMESPACE --from-literal=GARAGE_ENDPOINT=https://$GARAGE_S3_HOST --from-literal=GARAGE_REGION=$GARAGE_REGION --from-literal=GARAGE_BUCKET=$GARAGE_BUCKET --from-literal=GARAGE_ACCESS_KEY=<ACCESS_KEY> --from-literal=GARAGE_SECRET_KEY=<SECRET_KEY>"
  exit 0
fi

kubectl exec -n "$NAMESPACE" "$POD" -- garage bucket allow --read --write --owner "$GARAGE_BUCKET" "$ACCESS_KEY" || true

kubectl delete secret garage-s3 -n "$NAMESPACE" --ignore-not-found
kubectl create secret generic garage-s3 -n "$NAMESPACE" \
  --from-literal=GARAGE_ENDPOINT="https://$GARAGE_S3_HOST" \
  --from-literal=GARAGE_REGION="$GARAGE_REGION" \
  --from-literal=GARAGE_BUCKET="$GARAGE_BUCKET" \
  --from-literal=GARAGE_ACCESS_KEY="$ACCESS_KEY" \
  --from-literal=GARAGE_SECRET_KEY="$SECRET_KEY"

echo "Created secret: garage-s3"
