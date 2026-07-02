#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

load_env() {
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/config/platform.env"
  set +a
}

ensure_ns() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1" >&2
    exit 1
  }
}

apply_file_if_exists() {
  local file="$1"
  if [ -f "$file" ]; then
    kubectl apply -f "$file"
  else
    echo "Skip missing file: $file"
  fi
}
