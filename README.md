# Arda Infrastructure

This repository is the GitOps and runtime source of truth for Arda.

Updated: 2026-04-30

## Boundary

`arda-infra` owns:

- ArgoCD applications and projects.
- Kubernetes manifests and Kustomize overlays.
- APISIX gateway and route configuration.
- Cloudflared ingress.
- Zitadel runtime routing.
- Deploy-time ConfigMaps, Secret references, image tags, and namespaces.
- Local standalone APISIX for workstation integration checks.

Application implementation code stays in `arda-labs/arda`:

- frontend under `apps/frontend-micro`;
- Go services under `apps/backend-go`;
- Java/Kotlin prototypes under `apps/backend-java`;
- shared application libraries under `libs`.

## Structure

```text
arda-infra/
├── argocd/
│   ├── apps/
│   └── projects/
├── apps/
│   ├── gateway/apisix/
│   ├── identity/zitadel/
│   ├── ingress/cloudflared/
│   ├── iam-service/
│   ├── mdm-service/
│   ├── mfe-shell/
│   ├── mfe-iam/
│   └── mfe-mdm/
├── bootstrap/
├── infrastructure/
├── local/apisix/
└── scripts/
```

## Current Model

- The shared runtime cluster is K3s on `thinkcenter`.
- Application workloads run in namespace `arda-apps`.
- Gateway workloads run in namespace `gateway`.
- Identity workloads run in namespace `identity`.
- Cloudflared runs in namespace `infra`.
- ArgoCD runs in namespace `argocd`.
- Environment overlays are currently named `dev`.

## Current Applications

| Application | Path | Namespace |
| --- | --- | --- |
| `iam-service` | `apps/iam-service/overlays/dev` | `arda-apps` |
| `mdm-service` | `apps/mdm-service/overlays/dev` | `arda-apps` |
| `mfe-shell` | `apps/mfe-shell/overlays/dev` | `arda-apps` |
| `mfe-iam` | `apps/mfe-iam/overlays/dev` | `arda-apps` |
| `mfe-mdm` | `apps/mfe-mdm/overlays/dev` | `arda-apps` |
| `cloudflared` | `apps/ingress/cloudflared/overlays` | `infra` |
| `zitadel-routes` | `apps/identity/zitadel/base` | `identity` |

## Gateway Routes

| Path | Target |
| --- | --- |
| `/*` | `mfe-shell` |
| `/mfe-iam/*` | `mfe-iam` |
| `/mfe-mdm/*` | `mfe-mdm` |
| `/api/v1/*` | `iam-service` |
| `/api/v1/mdm/*` | `mdm-service` |

API paths are rewritten from `/api/<path>` to `/<path>`.

## Local APISIX

For local development, use the standalone APISIX gateway under `local/apisix`.
It routes local frontend and backend processes through the same public path
shape used by the cluster.

```powershell
cd D:\Github\arda-labs\arda-infra\local\apisix
docker compose up -d
```

Run local services:

| Process | URL |
| --- | --- |
| IAM backend | `http://localhost:8000` |
| MDM backend | `http://localhost:8001` |
| Shell MFE | `http://localhost:3000` |
| IAM MFE | `http://localhost:3002` |
| MDM MFE | `http://localhost:3001` |

Shell runtime config:

```js
window.__env.apiUrl = 'http://localhost:9080/api';
window.__env.apiPath = '/v1';
window.__env.mfeIamUrl = 'http://localhost:9080/mfe-iam';
window.__env.mfeMdmUrl = 'http://localhost:9080/mfe-mdm';
```

Quick checks:

```powershell
curl.exe -i http://localhost:9080/api/v1/me
curl.exe -i http://localhost:9080/api/v1/mdm/code-sets
curl.exe -i http://localhost:9080/mfe-iam/remoteEntry.json
curl.exe -i http://localhost:9080/mfe-mdm/remoteEntry.json
```

## Verify Manifests

```powershell
kubectl kustomize apps\iam-service\overlays\dev
kubectl kustomize apps\mdm-service\overlays\dev
kubectl kustomize apps\mfe-shell\overlays\dev
kubectl kustomize apps\mfe-iam\overlays\dev
kubectl kustomize apps\mfe-mdm\overlays\dev
```

## APISIX Dashboard

APISIX 3.16 ships an embedded Admin UI. This repo keeps the Admin UI internal
on the `apisix-admin` service.

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

Do not expose `apisix-admin` publicly without an access-control layer.
