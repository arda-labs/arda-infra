# arda-infra

GitOps desired state for the Arda k3s cluster.

## Layout

```text
argocd/          ArgoCD project and applications
auth/            Ory Hydra/Kratos values and bootstrap scripts
database/        CloudNativePG PostgreSQL cluster manifests
dev/             Local dev endpoint examples + read-only MCP wrappers (Grafana, Postgres)
platform/        Shared platform runtime bootstrap: NATS, Valkey, Garage, Cloudflared, Zeebe
k8s/             Arda backend application manifests
k8s/monitoring/  Observability stack: VictoriaMetrics, Grafana, Loki/Alloy, Gatus
scripts/         CI invariant checks (check-secret-hygiene.mjs, check-canary-policy.mjs, check-operational-gates.mjs)
docs/            Edge routing and operational architecture notes
traefik/         Traefik dynamic/static examples
```

Secrets should not be committed as raw values. Use Kubernetes Secret references,
SealedSecrets, SOPS, or ExternalSecrets before moving production credentials here.

## Cutover

```bash
# prerequisite: install CloudNativePG operator, then verify its CRDs exist
kubectl get crd clusters.postgresql.cnpg.io

kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml
kubectl -n argocd create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<pat-with-read-packages> \
  --docker-email=<email>
kubectl apply -k argocd
```

Argo CD applications in `argocd/apps` sync manifests from this repo. Backend
images are published from `arda-be`. The frontend is not deployed from this
repository: `arda-mfe` builds and deploys it to Cloudflare Workers.

Production API edge routing is documented in
[`docs/api-edge-routing.md`](docs/api-edge-routing.md). The frontend is served
from `arda.io.vn`; browser APIs use `api.arda.io.vn` through Cloudflare Tunnel.

Cloudflare Workers serve `arda.io.vn`: worker `arda-shell` owns
`arda.io.vn/*` and each remote owns `arda.io.vn/mfes/<app>/*`. The former
in-cluster frontend (`k8s/frontend`, Application `arda-frontend`, namespace
`arda-web`) was removed on 2026-10-12; it had not been applied since the
ThinkCentre recovery.

For a non-Argo local setup, apply the database and platform runtime first:

```bash
kubectl apply -k database
cd platform
bash bootstrap/setup-permissions.sh
./bootstrap/install-all.sh
```

Then bootstrap databases and auth before deploying app workloads:

```bash
cd ../auth
./setup.sh reset
cd ..
bash k8s/bootstrap-app-databases.sh
kubectl apply -k k8s
```

The database bootstrap enables the CNPG-provided `vector` extension in the
service-owned `ai` database before the AI service's Goose migrations run. The
application role remains non-superuser.

## AI assistant deployment

The Olorin assistant runs as two workloads in `k8s/apps`:

- `ai-service` — Go service owning the AG-UI stream (`/api/ai/agent`),
  conversations, approvals, and the `ai` database.
- `auth-gateway` — proxies `/api/ai/**` to `ai-service`;
  `COPILOTKIT_RUNTIME_URL=http://ai-service:8080`.

The former internal Node.js `ai-runtime` deployment was removed from
`k8s/apps/kustomization.yaml` and pruned by ArgoCD; do not re-add it. Details:
`arda-be/docs/ai/go-native-copilotkit.md`.

Optional local-only Postgres NodePort:

```bash
kubectl apply -k database/nodeport
```

## Workflow runtime

Arda targets Zeebe 8.5 through the Zeebe Gateway. `workflow-service` is the
Arda-facing facade for process APIs and is configured with `ZEEBE_ADDR` in
`k8s/apps/workflow-service.yaml`.

This repo should not deploy Camunda Tasklist, Operate, or Optimize for product
UX. Arda-owned workflow, task, process admin, and monitoring screens live in
`arda-mfe` and call Arda APIs.

## Monitoring and logs

The `monitoring` namespace runs the observability stack: VictoriaMetrics
(scrapes every service and the cluster itself, 30 days retention), Grafana
(single UI for dashboards and Grafana Alerting — `vmalert` was retired), Loki +
Alloy (central container logs, 14 days, JSON fields promoted to labels and
structured metadata), Gatus (20 black-box endpoint checks, status page,
Telegram) and node-exporter / kube-state-metrics / kubelet cAdvisor for cluster
and per-pod metrics.

Manifests live in `k8s/monitoring/`, dashboard JSON in
`k8s/monitoring/dashboards/` (kustomize generator), alert rules in
`k8s/monitoring/grafana-alerting.yaml` (reload provisioning through the Grafana
admin API after edits — Argo sync alone does not apply provisioning changes).
Runbook, access requirements and LogQL examples:
[`docs/monitoring.md`](docs/monitoring.md). Read-only agent access (kubectl,
Grafana MCP, Postgres MCP): [`docs/agent-access.md`](docs/agent-access.md).
