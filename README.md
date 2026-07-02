# arda-infra

GitOps desired state for the Arda k3s cluster.

## Layout

```text
argocd/   ArgoCD project and applications
auth/     Ory Hydra/Kratos values and bootstrap scripts
dev/      Local dev endpoint examples
k8s/      Arda application manifests
traefik/  Traefik dynamic/static examples
```

Secrets should not be committed as raw values. Use Kubernetes Secret references,
SealedSecrets, SOPS, or ExternalSecrets before moving production credentials here.

## Cutover

```bash
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

## Workflow runtime

Arda targets Zeebe 8.5 through the Zeebe Gateway. `workflow-service` is the
Arda-facing facade for process APIs and is configured with `ZEEBE_ADDR` in
`k8s/apps/workflow-service.yaml`.

This repo should not deploy Camunda Tasklist, Operate, or Optimize for product
UX. Arda-owned workflow, task, process admin, and monitoring screens live in
`arda-mfe` and call Arda APIs.
