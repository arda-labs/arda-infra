# CNI migration: Flannel to Cilium

## Why

The cluster ran the K3s-embedded Flannel VXLAN fabric. Flannel does not implement
the Kubernetes NetworkPolicy API, so **every NetworkPolicy object in this
cluster was accepted by the apiserver and enforced by nothing** — including the
eight that the Argo CD chart ships and the one the Valkey chart ships.

That mattered because the application tier has no authentication of its own.
Each service trusts `X-User-Id` / `X-Tenant-Id` / `X-Permissions` as delivered by
`auth-gateway`, and no service verifies a signature on those headers. The only
control was the Ingress, and the thing the Ingress was protecting — the flat
pod network — had no isolation. Any pod in any namespace could open a socket to
`finance-service:8080`, present a forged tenant header, and read or write the
ledger.

Cilium is the smallest change that makes the policy layer real. The policies
themselves live in `k8s/network-policies/` and are enforced only after this
migration completes.

## Read this before running anything

This replaces the CNI under a running three-node control plane that also hosts
etcd. The failure mode is a cluster that cannot reach its own API server.

- Take a fresh etcd snapshot first: `platform/bootstrap/backup.sh`.
- Do it in a maintenance window.
- Do not merge the `k8s/network-policies/` change until step 5 is done. Argo CD
  auto-syncs `k8s/` with `prune: true`; if the policies land first they are inert
  (harmless), but if they land while Cilium is half-installed they will deny
  traffic against a datapath that does not exist yet.
- Keep a shell open on each node (`ssh hoan@192.168.10.201..203`, see
  `docs/agent-access.md`). If the network breaks, fall back to
  `qm guest exec <vmid>` or the console on the Proxmox host `192.168.10.200`.

## Rollout

### 1. Disable Flannel, on every node

On `k3s-node1`, `k3s-node2`, `k3s-node3`:

```yaml
# /etc/rancher/k3s/config.yaml
flannel-backend: none
```

Then restart k3s on that node and wait for `Ready` before moving to the next:

```bash
sudo systemctl restart k3s
kubectl get nodes          # all three must be Ready before continuing
```

Doing one node at a time keeps the control plane quorum: three control-plane
nodes tolerate one member restarting at a time.

After this the cluster has no CNI. Pods keep running on their existing network
namespace but **new pods cannot be scheduled** — that is the expected
intermediate state, not a fault.

### 2. Install Cilium

```bash
export CILIUM_ACK_FLANNEL_DISABLED=true
./platform/bootstrap/install-cilium.sh
```

The script refuses to run without the acknowledgement, refuses to run if any
node is not `Ready`, and refuses to run if the live node count does not match
`CILIUM_EXPECTED_NODES` in `platform/config/platform.env` — a partial agent
rollout would leave the missing nodes with no datapath at all.

Chart values: `platform/helm/cilium/values.yaml` (pinned to 1.20.2).

### 3. Confirm the datapath

```bash
kubectl -n kube-system get pods -l k8s-app=cilium      # 3 Running
kubectl -n kube-system exec ds/cilium -- cilium status
kubectl -n kube-system logs ds/cilium -l agent | tail -40
```

Delete a pod in each namespace and confirm it gets an address and reaches its
peers:

```bash
kubectl -n arda-app delete pod -l app=iam-service
kubectl -n arda-app logs -l app=iam-service --tail=20
```

### 4. Verify application traffic end to end

Not just pods starting — real requests, because a policy gap and a datapath gap
look different and only one of them is fixed by this document.

```bash
# Login must mint a session
curl -sS -o /dev/null -w '%{http_code}\n' https://api.arda.io.vn/api/auth/me

# The gateway must still reach IAM through its own service mesh rules
kubectl -n arda-app exec deploy/auth-gateway -- \
  wget -qO- http://iam-service:8080/health/ready

# Observability must not go dark: a broken scrape path is silent
#   Grafana -> Explore -> VictoriaMetrics -> arda-services -> any service
kubectl -n monitoring exec deploy/vmsingle -- \
  wget -qO- 'http://localhost:8428/api/v1/query?query=up'
```

Confirm the dashboards in `k8s/monitoring/dashboards/` still have data, and that
Gatus still reports every endpoint green on the status page. A silently broken
scrape path looks exactly like a healthy quiet cluster.

### 5. Apply the policies

Only now.

```bash
kubectl apply -k k8s/network-policies
```

Or let Argo CD sync them on the next merge to `main`.

Watch for denials immediately afterwards — Cilium counts them:

```bash
kubectl -n kube-system exec ds/cilium -- cilium policy get
kubectl -n kube-system exec ds/cilium -- cilium monitor --type drop | tail -20
```

A non-zero drop count right after rollout means an allowlist is missing a real
traffic edge. Add it, do not widen the default-deny.

## Rollback

The policies are independent of the CNI, so they can be removed first without
touching the datapath:

```bash
kubectl delete -k k8s/network-policies
```

To go back to Flannel:

1. `helm uninstall cilium -n kube-system` (the chart installs into `kube-system`,
   not `platform`; confirm with `helm list -A | grep cilium`).
2. On every node, remove `flannel-backend: none` from
   `/etc/rancher/k3s/config.yaml` and restart k3s.
3. `kubectl get nodes` — all three Ready.
4. Re-run `platform/bootstrap/install-cilium.sh`'s preflight expectations for
   whatever comes next; the cluster is back to having no network policy
   enforcement, so treat the policies as absent until this is retried.

If the cluster is unreachable after step 1, the nodes still have the old
`/var/lib/rancher/k3s/agent/etc/cni/net.d` content only if Cilium did not take
`cni.exclusive`. With `exclusive: true` the conflist is Cilium's, so a failed
rollback means booting a node without networking and fixing the config on the
console.

## What is still not covered

These namespaces have no policies yet. They are helm-owned rather than
kustomize-owned, so they are a separate change:

| Namespace | Contents | Why it matters |
| --- | --- | --- |
| `platform` | NATS, Valkey, Garage, Zeebe, Elasticsearch, Gotenberg, cloudflared | `cloudflared` holds the tunnel token; the data-tier ports are reachable from anywhere in the cluster |
| `auth` | Ory Hydra, Kratos | The public Hydra port is reachable from any pod, and Hydra's admin API must stay closed to everything but `auth-gateway` |
| `kube-system` | Traefik, Argo CD, CNI | Argo CD can create a `ClusterRoleBinding`; see `argocd/project.yaml` |
| `default` | nothing deployed | Should be default-deny for hygiene |

Until those land, only the four namespaces in `k8s/network-policies/` are
isolated.
