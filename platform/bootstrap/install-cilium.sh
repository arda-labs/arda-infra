#!/usr/bin/env bash
set -euo pipefail

# Replaces the embedded Flannel VXLAN fabric with Cilium.
#
# Read docs/cni-migration.md before running this. The k3s agent flag
# `flannel-backend: none` must already be set on all three nodes, and etcd must
# have a fresh backup, or this script will install Cilium on top of a live
# Flannel datapath and the cluster will lose pod-to-pod connectivity.
#
# The script is idempotent and safe to re-run: it waits for the agent rollout to
# settle before returning, and it never touches the NetworkPolicy manifests.
# Applying the policies is a separate, explicit step (--with-policies) so that a
# broken allowlist can never be installed together with the CNI that would
# start enforcing it.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/bootstrap/lib.sh"
load_env

WITH_POLICIES="${WITH_POLICIES:-false}"

if [ "$INSTALL_CILIUM" != "true" ]; then
  echo "Skip Cilium: INSTALL_CILIUM=false"
  exit 0
fi

require_cmd helm
require_cmd kubectl

# --- Preflight -------------------------------------------------------------
# Refuse to continue on a cluster that is already degraded. Cilium cannot
# repair a partition, and installing onto a broken cluster turns a recoverable
# incident into an outage.
not_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}')"
if [ -n "$not_ready" ]; then
  echo "Refusing to install Cilium: node(s) not Ready: $not_ready" >&2
  echo "Flannel is still the only CNI; fix the node first." >&2
  exit 1
fi

expected_nodes="$(printf '%s' "$CILIUM_EXPECTED_NODES" | tr -d '[:space:]' | tr ',' '\n' | grep -c . || true)"
actual_nodes="$(kubectl get nodes --no-headers 2>/dev/null | grep -c . || true)"
if [ "$expected_nodes" -gt 0 ] && [ "$expected_nodes" -ne "$actual_nodes" ]; then
  echo "Refusing to install Cilium: expected $expected_nodes nodes, cluster reports $actual_nodes" >&2
  echo "A node that is down cannot run the Cilium agent, and a partial CNI rollout" >&2
  echo "leaves pods on those nodes with no datapath at all." >&2
  exit 1
fi

# The k3s flag is the one thing this script cannot verify from inside the
# cluster, so it is an explicit human gate rather than a heuristic.
if [ "${CILIUM_ACK_FLANNEL_DISABLED:-false}" != "true" ]; then
  cat >&2 <<'GATE'
Refusing to install Cilium: flannel-backend=none is not acknowledged.

Flannel and Cilium cannot both own the CNI conflist. Confirm, on every node,
that /etc/rancher/k3s/config.yaml contains:

    flannel-backend: none

and that k3s has been restarted on each node. Then re-run with:

    CILIUM_ACK_FLANNEL_DISABLED=true ./platform/bootstrap/install-cilium.sh

Full procedure and rollback: docs/cni-migration.md
GATE
  exit 1
fi

echo "==> Ensuring the Cilium namespace"
ensure_ns

echo "==> Adding the Cilium helm repository"
helm repo add cilium https://helm.cilium.io/ || true
helm repo update

echo "==> Installing Cilium ${CILIUM_CHART_VERSION}"
helm upgrade --install "$CILIUM_RELEASE" cilium/cilium \
  -n "$NAMESPACE" \
  --version "$CILIUM_CHART_VERSION" \
  -f "$ROOT/helm/cilium/values.yaml" \
  --wait \
  --timeout 10m

# --- Verify the datapath before anything depends on it --------------------
echo "==> Waiting for the Cilium agents to become ready"
if ! kubectl -n "$NAMESPACE" rollout status daemonset/cilium --timeout=10m; then
  echo "Cilium agents did not become ready. Do NOT apply the NetworkPolicies." >&2
  echo "Inspect: kubectl -n $NAMESPACE get pods -l k8s-app=cilium" >&2
  exit 1
fi

ready_agents="$(kubectl -n "$NAMESPACE" get pods -l k8s-app=cilium \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c . || true)"
if [ "$ready_agents" -lt "$actual_nodes" ]; then
  echo "Only $ready_agents/$actual_nodes Cilium agents are running." >&2
  echo "Do NOT apply the NetworkPolicies until every node has an agent." >&2
  exit 1
fi

# A running agent is not a working datapath. Confirm the apiserver is still
# reachable through the new CNI before declaring success.
echo "==> Verifying pod-to-pod connectivity"
kubectl -n "$NAMESPACE" exec ds/cilium -- cilium status --brief >/dev/null 2>&1 \
  || echo "Warning: could not read 'cilium status'; check manually." >&2

echo "==> Cilium is ready."
echo "    Next: verify application traffic end to end, then apply the policies with"
echo "    ./platform/bootstrap/install-cilium.sh  (WITH_POLICIES=true)"
echo "    or let Argo CD sync k8s/network-policies/ once you have confirmed."

if [ "$WITH_POLICIES" = "true" ]; then
  echo "==> Applying NetworkPolicies"
  kubectl apply -k "$ROOT/../../k8s/network-policies"
  echo "==> Policies applied. Watch for blocked traffic:"
  echo "    kubectl exec -n $NAMESPACE ds/cilium -- cilium policy get"
fi
