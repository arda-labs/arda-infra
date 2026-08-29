# Inventory

## NATS

- Chart: `nats/nats`
- Values: `helm/nats/values.yaml`
- NodePort: `manifests/nodeport/nats-nodeport.yaml`

## Valkey

- Chart: `bitnami/valkey`
- Values: `helm/valkey/values.yaml`
- Secret: `valkey-auth`
- NodePort: `manifests/nodeport/valkey-nodeport.yaml`

## Garage

- Chart: `garage/garage`
- Values: `helm/garage/values.yaml`
- Admin token secret: `garage-admin-secret`
- S3 app secret: `garage-s3`
- WebUI/Ingress: `manifests/garage/`

## Cloudflared

- Manifest: `manifests/cloudflared/cloudflared-deployment.yaml`
- Secret: `cloudflared-token`

## Zeebe

- Chart: `camunda/camunda-platform`
- Values: `helm/zeebe/values.yaml`
- Chart version pinned by `ZEEBE_CHART_VERSION` in `config/platform.env`.
