# Arda Auth Stack

This folder deploys the Ory auth dependencies for the k3s dev cluster:

- Hydra: OAuth2/OIDC server.
- Kratos: identity, password login, and Kratos browser/API sessions.
- IAM app integration: `setup.sh` can patch the `iam-service` deployment with
`SUPERADMIN_INITIAL_PASSWORD` so the Ory seed identity can be created.

The actual Arda authorization model lives in `iam-service`, not in Hydra or
Kratos. A working superadmin therefore needs both sides:

- Kratos identity: `superadmin@arda.local` can authenticate.
- IAM user: `superadmin@arda.local` has `SUPER_ADMIN` and wildcard permission.

`iam-service` creates/reconciles the IAM side on startup. This folder prepares
the Ory side and passes the bootstrap password to `iam-service`.

## Files

```text
auth/
  setup.sh
  values-hydra.yaml
  values-kratos.yaml
  identity.schema.json
  auth-admin-nodeport.yaml
  clients/arda-shell.json
```

## Defaults

```text
AUTH_NAMESPACE=auth
SUPERADMIN_EMAIL=superadmin@arda.local
SUPERADMIN_INITIAL_PASSWORD=<provide-through-local-secret-manager>
HYDRA_DATABASE_DSN=<provide-through-local-secret-manager>
KRATOS_DATABASE_DSN=<provide-through-local-secret-manager>
HYDRA_DATABASE_PASSWORD=<provide-through-local-secret-manager>
KRATOS_DATABASE_PASSWORD=<provide-through-local-secret-manager>
HYDRA_SYSTEM_SECRET=<provide-through-local-secret-manager>
HYDRA_COOKIE_SECRET=<provide-through-local-secret-manager>
KRATOS_DEFAULT_SECRET=<provide-through-local-secret-manager>
KRATOS_COOKIE_SECRET=<provide-through-local-secret-manager>
DEV_ADMIN_EMAIL=admin@arda.local
```

For dev, the script also seeds `admin@arda.local` with the same password because
older local IAM seed data still contains that account. Always set
`SUPERADMIN_INITIAL_PASSWORD` and the Ory database/system secrets from a local
secret manager before running the script; there are no committed defaults.

## Usage

Deploy or reconcile auth:

```bash
cd arda-infra/auth
chmod +x setup.sh
SUPERADMIN_INITIAL_PASSWORD='<secret>' \
HYDRA_DATABASE_DSN='<dsn>' KRATOS_DATABASE_DSN='<dsn>' \
HYDRA_DATABASE_PASSWORD='<secret>' KRATOS_DATABASE_PASSWORD='<secret>' \
HYDRA_SYSTEM_SECRET='<secret>' HYDRA_COOKIE_SECRET='<secret>' \
KRATOS_DEFAULT_SECRET='<secret>' KRATOS_COOKIE_SECRET='<secret>' \
./setup.sh deploy
```

Reset only Hydra/Kratos databases, then redeploy and reseed:

```bash
./setup.sh reset
```

Seed only the Ory identities:

```bash
SUPERADMIN_INITIAL_PASSWORD='<secret>' ./setup.sh client
```

## What `setup.sh deploy` Does

1. Installs or upgrades Hydra and Kratos in namespace `auth`.
2. Creates the `arda-shell` Hydra OAuth client.
3. Imports Kratos seed identities:
   - `superadmin@arda.local`
   - `admin@arda.local`
4. Creates admin NodePorts:
   - Hydra Admin: `30445`
   - Kratos Admin: `30446`
5. If `deploy/iam-service` exists in namespace `arda-app`, creates/updates
   secret `iam-service-secrets`, sets env from it, and restarts `iam-service`.

After `iam-service` restarts, the expected identities are:

```text
superadmin@arda.local / password supplied through the secret manager
admin@arda.local      / password supplied through the secret manager
```

## Flow

```text
App
-> Hydra /oauth2/auth
-> https://api.arda.io.vn/api/auth/login
-> FE /login?login_challenge=...
-> Login app uses Kratos login
-> auth-gateway accepts Hydra login/consent
-> https://api.arda.io.vn/api/auth/callback?code=...
-> auth-gateway session + IAM authorization context
```

The session cookie is host-only to `api.arda.io.vn`. The frontend at
`https://arda.io.vn` calls the API with credentials and Auth Gateway allows that
exact CORS origin.

## Checks

```bash
kubectl get pods -n auth
kubectl get svc -n auth | grep -E 'hydra|kratos'
kubectl get deploy -n arda-app iam-service
kubectl get secret -n arda-app iam-service-secrets
```

Check the Hydra client:

```bash
kubectl exec -n auth deploy/hydra -- \
  hydra get oauth2-client arda-shell \
  --endpoint http://127.0.0.1:4445
```
