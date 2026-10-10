#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env
require_cmd kubectl

# Provision before application startup: ARDA_EVENTS must not claim AI_EVENTS
# subjects. Existing streams and their records are preserved on repeat runs.
box="deployment/${NATS_RELEASE}-box"
kubectl -n "$NAMESPACE" rollout status "$box" --timeout=180s
if kubectl -n "$NAMESPACE" exec "$box" -- nats --server "nats://${NATS_RELEASE}:4222" stream info ARDA_EVENTS >/dev/null 2>&1; then
  echo "ARDA_EVENTS already exists; preserving its configuration and records"
  exit 0
fi
kubectl -n "$NAMESPACE" exec -i "$box" -- sh -c 'cat > /tmp/arda-events-stream.json' < "$ROOT/manifests/nats/arda-events-stream.json"
kubectl -n "$NAMESPACE" exec "$box" -- nats --server "nats://${NATS_RELEASE}:4222" stream add --config /tmp/arda-events-stream.json --defaults
