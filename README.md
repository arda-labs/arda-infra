# Arda Platform Infra

This repository is the runtime and GitOps source of truth for the Arda platform.

## Structure

- `/bootstrap`: ArgoCD root app and cluster bootstrap entry point.
- `/argocd`: App and Project definitions for ArgoCD.
- `/apps`: Cluster runtime manifests and APISIX route configuration.
- `/infrastructure`: Cluster-wide namespaces and storage.

## Repository Boundary

`arda-infra` owns Kubernetes manifests, ArgoCD applications, APISIX routes, environment overlays, ingress, and deploy-time configuration.

Application source code stays in `arda-labs/arda`:

- frontend code under `apps/frontend-micro`
- Go services under `apps/backend-go`
- Java services under `apps/backend-java`
- shared application libraries under `libs`

Do not put application implementation code in this repository. Do not put production Kubernetes runtime state in the application repository.

Environment-specific behavior should live in overlays. Local tunnel support for the shared APISIX on `thinkcenter` is allowed in the active gateway route manifests, while production-oriented namespaces and workloads stay isolated.

## Getting Started

1. **Prerequisites**: k3s on `thinkcenter`.
2. **Bootstrap**:
   ```bash
   ./scripts/bootstrap.sh
   ```

## Current Model

The active platform model is:

- local uses APISIX tunnel traffic to `thinkcenter`
- prod runs on k3s on `thinkcenter`
- no separate dev environment
- ArgoCD manages cluster state from Git
- `gateway`, `infra`, `identity`, `argocd`, and `arda-apps` are the namespaces to expect
- `identity` is reserved for Zitadel and future auth platform components

Zitadel is bootstrapped from the official `https://charts.zitadel.com` Helm chart.

- release name `zitadel-core`
- namespace `identity`
- bootstrap secret `zitadel-masterkey` from `scripts/create-zitadel-secret.sh`

## APISIX Dashboard

APISIX 3.16 ships the Dashboard as an embedded Admin UI. The old standalone `apisix-dashboard` Helm chart is deprecated, so this repo keeps the Admin UI enabled on the existing `apisix-admin` service instead of installing a second dashboard workload.

The dashboard is intentionally kept on the internal ClusterIP Admin service. Do not expose `apisix-admin` through Cloudflare Tunnel or the public APISIX gateway unless Cloudflare Access or equivalent protection is in front of it.

From Windows:

```powershell
.\scripts\apisix-dashboard.ps1
```

From Linux on `thinkcenter`:

```bash
./scripts/apisix-dashboard.sh
```

Then open:

```text
http://127.0.0.1:9180/ui/
```

The script prints the Admin API key because the embedded UI authenticates to APISIX through the Admin API.

References:
- https://apisix.apache.org/docs/apisix/dashboard/
- https://apisix.apache.org/docs/helm-chart/apisix-dashboard/

## Local Dev via APISIX

For local development, use the standalone APISIX gateway under `local/apisix`. It routes local frontend and backend processes through the same public path shape used by the cluster.

1. Start APISIX:
   ```powershell
   cd D:\Github\arda-labs\arda-infra\local\apisix
   docker compose up -d
   ```

2. Run local services:
   - IAM backend: `http://localhost:8000`
   - MDM backend: `http://localhost:8001`
   - Shell MFE: `http://localhost:3000`
   - IAM MFE: `http://localhost:3002`
   - MDM MFE: `http://localhost:3001`

3. Point local frontend runtime config to APISIX instead of calling services directly:
   ```js
   window.__env.apiUrl = 'http://localhost:9080/api';
   window.__env.apiPath = '/v1';
   window.__env.mfeIamUrl = 'http://localhost:9080/mfe-iam';
   window.__env.mfeMdmUrl = 'http://localhost:9080/mfe-mdm';
   ```

4. Open the shell through APISIX:
   ```text
   http://localhost:9080
   ```

5. Quick checks:
   ```powershell
   curl.exe -i http://localhost:9080/api/v1/me
   curl.exe -i http://localhost:9080/api/v1/mdm/code-sets
   curl.exe -i -H "Host: localhost" http://localhost:9080/mfe-iam/remoteEntry.json
   curl.exe -i -H "Host: localhost" http://localhost:9080/mfe-mdm/remoteEntry.json
   ```

Notes:
- APISIX runs in standalone YAML mode and does not need etcd or Admin API.
- API paths are rewritten from `/api/v1/*` to service-native `/v1/*`.
