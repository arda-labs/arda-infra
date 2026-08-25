# arda-infra

GitOps desired state for the Arda k3s cluster.

## Layout

```text
argocd/   ArgoCD project and applications
auth/     Ory Hydra/Kratos values and bootstrap scripts
database/ CloudNativePG PostgreSQL cluster manifests
dev/      Local dev endpoint examples
platform/ Shared platform runtime bootstrap: NATS, Valkey, Garage, Cloudflared, Zeebe
k8s/      Arda backend/frontend application manifests
docs/     Edge routing and operational architecture notes
traefik/  Traefik dynamic/static examples
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
images are published from `arda-be`; frontend images are published from
`arda-mfe`.

Production API edge routing is documented in
[`docs/api-edge-routing.md`](docs/api-edge-routing.md). The frontend is served
from `arda.io.vn`; browser APIs use `api.arda.io.vn` through Cloudflare Tunnel.

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
