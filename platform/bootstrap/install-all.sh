#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

"$ROOT/bootstrap/preflight.sh"
ensure_ns
"$ROOT/bootstrap/create-secrets.sh"

"$ROOT/bootstrap/install-nats.sh"
"$ROOT/bootstrap/install-valkey.sh"
"$ROOT/bootstrap/install-garage.sh"
"$ROOT/bootstrap/install-cloudflared.sh"
"$ROOT/bootstrap/install-zeebe.sh"

echo
echo "Done. Current status:"
"$ROOT/bootstrap/status.sh"
