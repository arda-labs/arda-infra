# API edge routing

Last updated: 2026-08-22

## Production topology

```text
Browser
├── https://arda.io.vn
│   └── Cloudflare Workers Static Assets (shell + MFE remotes)
└── https://api.arda.io.vn/api/*
    └── Cloudflare edge/WAF
        └── Cloudflare Tunnel `thinkcenter-promox`
            └── auth-gateway.arda-app.svc.cluster.local:8080
                └── Arda backend services
```

`api.arda.io.vn` is a proxied CNAME to the existing tunnel. It does not have a
Workers route, so API traffic does not invoke `arda-shell`. Cloudflare proxy,
WAF, DDoS protection, and Tunnel remain in the request path.

The remotely managed Tunnel owns this public-hostname rule:

```text
api.arda.io.vn -> http://auth-gateway.arda-app.svc.cluster.local:8080
```

Tunnel ingress is account state and is not reconciled by Argo CD. When changing
it in Cloudflare, update this document in the same change.

## Traefik dynamic routing

`traefik/dynamic.yml` defines the internal routing layer between
`auth-gateway` and individual services. Routers (`iam-api`, `mdm-api`,
`platform-public`/`platform-api`, `workflow-api`, `iam-public`) forward
service-specific path prefixes, and the `arda-forward-auth` middleware enforces
forward-auth through the gateway. Services not listed there (crm, finance,
hrm, media, notification, ai) are reached through auth-gateway's own proxy
routes (`k8s/apps/auth-gateway.yaml`). `mdm-service` has a Traefik router and
service entry but no dedicated `k8s/apps` manifest yet — it is a scaffold.

## Migration compatibility

During migration, `arda.io.vn/api/*` remains available through two controls:

- a more-specific Cloudflare Workers route with no script, which bypasses the
  wildcard `arda-shell` Worker route;
- the existing Tunnel path rule for `arda.io.vn` `/api/*`.

This lets older frontend builds continue working without Worker invocations.
Remove the legacy path only after deployed clients use `api.arda.io.vn` and
observability shows no meaningful traffic on the old hostname.

## Browser security contract

The browser origin is `https://arda.io.vn`; the API origin is
`https://api.arda.io.vn`. Auth Gateway therefore owns credentialed CORS:

```text
Access-Control-Allow-Origin: https://arda.io.vn
Access-Control-Allow-Credentials: true
Vary: Origin
```

Preflight supports `GET, POST, PUT, PATCH, DELETE, OPTIONS` and the headers used
by the frontend HTTP client. Wildcard CORS origins are not allowed with session
cookies.

OAuth state stores only a safe relative return path. Auth Gateway resolves that
path against `FRONTEND_ORIGIN=https://arda.io.vn`; it must never resolve a
post-login redirect against the API callback origin.

Session and device cookies remain host-only. OAuth starts and completes on the
API hostname, so broadening cookie scope to `.arda.io.vn` is unnecessary.

## OAuth dependencies

Hydra must use:

```text
login:   https://api.arda.io.vn/api/auth/login
consent: https://api.arda.io.vn/api/auth/consent
```

The `arda-shell` OAuth client must include:

```text
https://api.arda.io.vn/api/auth/callback
```

After changing `auth/values-hydra.yaml` and `auth/setup.sh`, reconcile the live
Hydra release/client; editing Git alone does not mutate an existing Hydra OAuth
client.

## Deployment order

1. Add the Tunnel hostname and proxied DNS CNAME for `api.arda.io.vn`.
2. Deploy Auth Gateway with CORS and the API callback allowlist.
3. Reconcile Hydra URLs and the `arda-shell` client redirect URIs.
4. Deploy the frontend API-origin resolver.
5. Verify login, logout, session refresh, SSE notifications, media, and one
   read/write flow for each business service.
6. Keep the legacy no-script route until old frontend traffic drains.

## Verification

```bash
curl -fsS https://api.arda.io.vn/api/platform/public/branding

curl -i -X OPTIONS https://api.arda.io.vn/api/auth/me \
  -H 'Origin: https://arda.io.vn' \
  -H 'Access-Control-Request-Method: GET'
```

The preflight response must be `204` and include the credentialed CORS headers.
An authenticated browser check must confirm that `arda_sid` is stored for
`api.arda.io.vn` and sent only with API requests.

## Rollback

1. Keep or restore the no-script route for `arda.io.vn/api/*`.
2. Roll the frontend back to relative `/api/*` URLs.
3. Restore Hydra login/consent and callback configuration to `arda.io.vn` if
   auth was already cut over.
4. Remove `api.arda.io.vn` DNS/Tunnel routing only after clients are rolled back.

## Follow-up protection

Configure WAF rate limits per API family and method. Keep application-level
limits, pagination, query timeouts, and database connection limits; Cloudflare
controls do not replace backend overload protection.

Workers VPC was evaluated but is not used here. It is useful when a Worker must
call private services, whereas this design intentionally keeps API requests out
of the Worker execution path.
