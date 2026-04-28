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
- `gateway`, `infra`, `argocd`, and `arda-prod` are the namespaces to expect

## Local Dev via APISIX

Use the shared APISIX running on `thinkcenter` when developing locally so request routing matches the deployed gateway shape more closely.

1. Open an SSH tunnel from your Windows machine:
   ```powershell
   ssh -N -L 9080:127.0.0.1:30907 hoan@thinkcenter
   ```
   This forwards `http://localhost:9080` to the APISIX `NodePort` service on `thinkcenter`.

2. Point local frontend runtime config to APISIX instead of calling services directly:
   ```js
   window.__env.apiUrl = 'http://localhost:9080/api';
   window.__env.mfeIamUrl = 'http://localhost:9080/mfe-iam';
   window.__env.mfeCommonUrl = 'http://localhost:9080/mfe-common';
   ```

3. Keep the request host as `localhost`. The APISIX route manifests in this repo accept:
   - `arda.io.vn`
   - `localhost`
   - `127.0.0.1`

4. Quick checks:
   ```powershell
   curl.exe -i -H "Host: localhost" http://localhost:9080/api/v1/me
   curl.exe -i -H "Host: localhost" http://localhost:9080/mfe-iam/remoteEntry.json
   ```

Notes:
- This setup gives local development the same gateway entrypoint shape as deployed traffic.
- It does not replace proper APISIX auth plugins; it only aligns the transport path and routing path.
