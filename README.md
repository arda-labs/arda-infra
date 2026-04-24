# Arda Production-Ready Infra (arda-infra)

This repository follows the structure of a professional GitOps ecosystem.

## Structure

- `/bootstrap`: Entry point for cluster management.
- `/argocd`: App and Project definitions for ArgoCD.
- `/apps`: Core service manifests.
  - `/gateway`: APISIX configuration.
  - `/ingress`: Cloudflare Tunnel configuration.
  - `/mfe-shell`: MFE host application.
  - `/services`: Microservices (crm, etc.).
- `/infrastructure`: Cluster-wide namespaces and storage.

## Getting Started

1. **Prerequisites**: A K8s cluster and a Cloudflare Tunnel token.
2. **Secrets**:
   ```bash
   kubectl create namespace infra
   kubectl create secret generic cloudflared-token --from-literal=token=YOUR_TOKEN -n infra
   ```
3. **Bootstrap**:
   ```bash
   ./scripts/bootstrap.sh
   ```

## GitFlow Logic

- **Dev**: `arda-dev` namespace, tracks `develop` branch.
- **Prod**: `arda-prod` namespace, tracks `main` branch.
