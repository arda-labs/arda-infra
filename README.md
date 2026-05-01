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
│   ├── notification-service/
│   ├── mfe-shell/
│   ├── mfe-iam/
│   ├── mfe-mdm/
│   └── mfe-ntf/
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
- Redpanda/Kafka runs in namespace `arda-apps`.
- Environment overlays are currently named `dev`.

## Current Applications

| Application | Path | Namespace |
| --- | --- | --- |
| `iam-service` | `apps/iam-service/overlays/dev` | `arda-apps` |
| `mdm-service` | `apps/mdm-service/overlays/dev` | `arda-apps` |
| `notification-service` | `apps/notification-service/overlays/dev` | `arda-apps` |
| `mfe-shell` | `apps/mfe-shell/overlays/dev` | `arda-apps` |
| `mfe-iam` | `apps/mfe-iam/overlays/dev` | `arda-apps` |
| `mfe-mdm` | `apps/mfe-mdm/overlays/dev` | `arda-apps` |
| `mfe-ntf` | `apps/mfe-ntf/overlays/dev` | `arda-apps` |
| `redpanda` | `apps/base/redpanda` | `arda-apps` |
| `cloudflared` | `apps/ingress/cloudflared/overlays` | `infra` |
| `zitadel-routes` | `apps/identity/zitadel/base` | `identity` |

## Gateway Routes

| Path | Target |
| --- | --- |
| `/*` | `mfe-shell` |
| `/mfe-iam/*` | `mfe-iam` |
| `/mfe-mdm/*` | `mfe-mdm` |
| `/mfe-ntf/*` | `mfe-ntf` |
| `/api/v1/*` | `iam-service` |
| `/api/v1/mdm/*` | `mdm-service` |
| `/api/v1/notifications/*` | `notification-service` |

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
| Notification backend | `http://localhost:8002` |
| Shell MFE | `http://localhost:3000` |
| IAM MFE | `http://localhost:3002` |
| MDM MFE | `http://localhost:3001` |
| NTF MFE | `http://localhost:3003` |

Shell runtime config:

```js
window.__env.apiUrl = 'http://localhost:9080/api';
window.__env.apiPath = '/v1';
window.__env.mfeIamUrl = 'http://localhost:9080/mfe-iam';
window.__env.mfeMdmUrl = 'http://localhost:9080/mfe-mdm';
window.__env.mfeNtfUrl = 'http://localhost:9080/mfe-ntf';
```

Quick checks:

```powershell
curl.exe -i http://localhost:9080/api/v1/me
curl.exe -i http://localhost:9080/api/v1/mdm/code-sets
curl.exe -i http://localhost:9080/api/v1/notifications/templates
curl.exe -i http://localhost:9080/mfe-iam/remoteEntry.json
curl.exe -i http://localhost:9080/mfe-mdm/remoteEntry.json
curl.exe -i http://localhost:9080/mfe-ntf/remoteEntry.json
```

## Verify Manifests

```powershell
kubectl kustomize apps\base\redpanda
kubectl kustomize apps\iam-service\overlays\dev
kubectl kustomize apps\mdm-service\overlays\dev
kubectl kustomize apps\notification-service\overlays\dev
kubectl kustomize apps\mfe-shell\overlays\dev
kubectl kustomize apps\mfe-iam\overlays\dev
kubectl kustomize apps\mfe-mdm\overlays\dev
kubectl kustomize apps\mfe-ntf\overlays\dev
```

## Redpanda / Kafka

The dev cluster runs a single-node Redpanda broker for platform events.

Internal bootstrap address:

```text
redpanda.arda-apps.svc.cluster.local:9092
```

Install or sync the ArgoCD application:

```powershell
kubectl apply -f argocd\apps\redpanda.yaml
```

Quick cluster-side check:

```powershell
kubectl -n arda-apps exec statefulset/redpanda -- rpk cluster info --brokers redpanda.arda-apps.svc.cluster.local:9092
kubectl -n arda-apps exec statefulset/redpanda -- rpk topic list --brokers redpanda.arda-apps.svc.cluster.local:9092
```

Notification events topic:

```text
arda.notification.events.v1
```

Manual test event:

```powershell
'{"eventId":"manual-login-001","sourceService":"IAM","eventType":"SECURITY_LOGIN","correlationId":"manual-login-001","templateCode":"IAM_SECURITY_LOGIN","recipientType":"USER","recipientId":"user-001","channels":["IN_APP"],"language":"vi","payload":{"login_time":"2026-05-01 09:00","ip_address":"127.0.0.1"},"priority":10}' |
  kubectl -n arda-apps exec -i statefulset/redpanda -- rpk topic produce arda.notification.events.v1 --brokers redpanda.arda-apps.svc.cluster.local:9092
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
