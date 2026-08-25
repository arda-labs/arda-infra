# Argo CD

Argo CD owns deployment sync for Arda app manifests:

```text
GitHub Actions -> build images -> push GHCR
Argo CD        -> sync manifests from Git -> k3s
```

Argo CD does not build images. It only reconciles Kubernetes manifests.

## Install Argo CD

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
```

Port-forward the UI:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open `https://localhost:8080`.

## Private GitHub Repo Access

Create a GitHub PAT with the minimum repo read access needed for private repos.
For classic tokens this usually means `repo`. For fine-grained tokens, grant
read-only `Contents` access to `arda-be`, `arda-mfe`, and `arda-infra`.

Create Argo CD repo credentials:

```bash
kubectl -n argocd create secret generic arda-github-repo-creds \
  --from-literal=type=git \
  --from-literal=url=https://github.com/arda-labs \
  --from-literal=username=<github-user> \
  --from-literal=password=<github-pat> \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n argocd label secret arda-github-repo-creds \
  argocd.argoproj.io/secret-type=repo-creds --overwrite
```

## Apply Arda Applications

```bash
cd arda-infra
kubectl apply -k argocd
```

This creates:

- `AppProject/arda`
- `Application/arda-backend`
- `Application/arda-frontend`

## Required Runtime Secrets

Argo CD will create app resources, but runtime secrets are still cluster-local.
Create them before syncing apps:

```bash
kubectl -n arda-app create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<pat-with-read-packages> \
  --docker-email=<email>

kubectl -n arda-web create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<pat-with-read-packages> \
  --docker-email=<email>
```

Also create `arda-app-secrets` and `iam-service-secrets` as described in
`../../arda-be/docs/ghcr-k3s-deployment.md`. Before syncing, verify every
database key referenced by a Deployment exists, including
`HRM_DATABASE_DSN`; a missing key intentionally leaves that workload in
`CreateContainerConfigError` rather than activating a database fallback.
The AI workload additionally requires `AI_DATABASE_DSN`; it runs Goose
migrations for the service-owned `ai` database at startup and fails closed when
the key is absent.

`arda-app-secrets` must include `ARDA_SERVICE_AUTH_SECRET`, a random value of at
least 32 characters shared only by the Arda workloads that participate in
internal gRPC calls. It is injected through `secretKeyRef`; do not put it in a
manifest, ConfigMap, image or Git history. Rotate it through a coordinated
rolling deployment because old and new workload tokens overlap for one minute.

Internal gRPC also requires one cluster-local mTLS Secret per workload:
`arda-grpc-tls-crm`, `arda-grpc-tls-iam`, `arda-grpc-tls-platform`,
`arda-grpc-tls-workflow`, `arda-grpc-tls-hrm`, `arda-grpc-tls-finance`,
`arda-grpc-tls-media`, and `arda-grpc-tls-notification`.
Each Secret contains only `ca.crt`, `tls.crt`, and `tls.key`, is mounted
read-only at `/var/run/arda-grpc-tls`, and must be provisioned through the
approved secret-management process. See
`../../arda-be/docs/refactor-program/09-mtls-runbook.md`; generated certificate
material must never be committed to Git or placed in a ConfigMap.

For in-cluster Valkey, point app secrets at Sentinel instead of the `6379`
service so writers always resolve the current primary:

```bash
kubectl create secret generic arda-app-secrets -n arda-app \
  --from-literal=IAM_DATABASE_DSN='<iam-dsn>' \
  --from-literal=AI_DATABASE_DSN='<ai-dsn>' \
  --from-literal=PLATFORM_DATABASE_DSN='<platform-dsn>' \
  --from-literal=FINANCE_DATABASE_DSN='<finance-dsn>' \
  --from-literal=MEDIA_DATABASE_DSN='<media-dsn>' \
  --from-literal=WORKFLOW_DATABASE_DSN='<workflow-dsn>' \
  --from-literal=CRM_DATABASE_DSN='<crm-dsn>' \
  --from-literal=HRM_DATABASE_DSN='<hrm-dsn>' \
  --from-literal=NOTIFICATION_DATABASE_DSN='<notification-dsn>' \
  --from-literal=ARDA_SERVICE_AUTH_SECRET='<random-value-at-least-32-chars>' \
  --from-literal=REDIS_URL='redis-sentinel://:<valkey-password>@valkey.platform.svc.cluster.local:26379/myprimary' \
  --from-literal=NATS_URL='nats://<nats-endpoint>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Image Tags

The current manifests use the `main` tag for simplicity. After GitHub Actions
pushes a new `main` image, restart the deployment or later add Argo CD Image
Updater / SHA-tag manifest updates.
