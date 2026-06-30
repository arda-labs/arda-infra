# arda-infra

GitOps desired state for the Arda k3s cluster.

## Layout

```text
argocd/   ArgoCD project and applications
auth/     Ory Hydra/Kratos values and bootstrap scripts
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

Keep the copied deployment files in `arda-be` until ArgoCD is confirmed to sync
from this repo, then delete the old copies in a separate cleanup commit.
