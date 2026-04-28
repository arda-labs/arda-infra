#!/bin/bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

if ! kubectl get namespace identity >/dev/null 2>&1; then
  kubectl create namespace identity
fi

if ! kubectl -n identity get secret zitadel-masterkey >/dev/null 2>&1; then
  masterkey="$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)"
  kubectl -n identity create secret generic zitadel-masterkey \
    --from-literal=masterkey="$masterkey"
fi
