# Local APISIX Gateway

Standalone APISIX for local development. It does not need etcd or the Admin API.

## Ports

- APISIX: `http://localhost:9080`
- IAM service: `http://localhost:8000`
- MDM service: `http://localhost:8001`
- Notification service: `http://localhost:8002`
- Shell MFE: `http://localhost:3000`
- IAM MFE: `http://localhost:3002`
- MDM MFE: `http://localhost:3001`

## Run

```powershell
cd D:\Github\arda-labs\arda-infra\local\apisix
docker compose up -d
```

## Routes

- `/api/v1/mdm/*` -> `host.docker.internal:8001`, rewritten to `/v1/mdm/*`
- `/api/v1/notifications/*` -> `host.docker.internal:8002`, rewritten to `/v1/notifications/*`
- `/api/v1/*` -> `host.docker.internal:8000`, rewritten to `/v1/*`
- `/mfe-mdm/*` -> `host.docker.internal:3001`
- `/mfe-iam/*` -> `host.docker.internal:3002`
- `/*` -> `host.docker.internal:3000`
