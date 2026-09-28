# AiGiare gateway

The AiGiare API gateway is a private fork of
[QuantumNous/new-api](https://github.com/QuantumNous/new-api) deployed as a
single replica in the `aigiare-gw` namespace. It is the relay that turns an
upstream provider key into an AiGiare-issued API key, with per-token billing,
quota, rate limiting and a customer console.

## Why it is not in `arda-app`

The Arda application tier is default-deny and grants every traffic edge
explicitly, because several of its services have no authentication of their own
and trust headers forwarded by `auth-gateway`. This workload is the opposite:

- it is reachable from the public internet;
- it holds customer balances and API credentials;
- it runs third-party code under a licence that requires attribution;
- it needs egress to upstream hosts that cannot be enumerated in advance.

Putting it in `arda-app` would mean either widening that namespace's policy
with grants nothing in Arda needs, or accepting a public-facing third-party
workload inside the trust boundary of the finance, loan and deposit services.
`aigiare-gw` has its own default-deny set in
`k8s/network-policies/aigiare-gw/policies.yaml` where the only non-obvious rule
is the internet egress grant, scoped by excluding every private range.

## Image

The upstream release image is used **unmodified**:

```text
calciumion/new-api:v1.0.0-rc.40
```

Nothing in this deployment patches new-api, so there is nothing to build, no
fork to keep in sync, and no pipeline to own. Argo CD Image Updater resolves
the tag to a digest and writes it back, which is what
`platform/policy/canary-policy-v1.json` requires
(`immutable-digest-or-commit-sha`). The image is public, so no pull secret is
needed.

To change version, update the tag in `k8s/gateway/aigiare-gateway.yaml` and
the matching `imageName` in `argocd/image-updater.yaml` in the same commit.
They must agree or Image Updater will not track it.

A local clone of the upstream source is still useful for reading the code, but
it is not a build input. new-api's console already ships a Vietnamese locale
(`web/src/i18n/locales/vi.json`), so no frontend work is needed for the UI.

## Prerequisites

Before the first sync, two things are cluster-local and must exist:

```bash
# 1. role and database on pg-main
GATEWAY_DATABASE_PASSWORD='<password>' bash k8s/bootstrap-gateway-database.sh

# 2. runtime secret
kubectl create secret generic aigiare-gw-secrets -n aigiare-gw \
  --from-literal=SQL_DSN='<role>:<password>@pg-main-rw.database.svc.cluster.local:5432/<database>?sslmode=disable' \
  --from-literal=REDIS_CONN_STRING='redis://:<valkey-password>@valkey-master.platform.svc.cluster.local:6379/3' \
  --from-literal=SESSION_SECRET='<random-32-bytes-hex>' \
  --from-literal=CRYPTO_SECRET='<random-32-bytes-hex>'
```

`SESSION_SECRET` is not optional in practice: new-api generates a random value
when it is absent, which logs every customer out on every restart.
`CRYPTO_SECRET` keys cache digests and defaults to `SESSION_SECRET`, which is
only safe while a single node shares Valkey.

`valkey-master` is the bitnami primary Service for the `valkey` release.
Confirm the name against the live cluster; the Arda apps use a Sentinel URL
instead, which new-api cannot parse.

## Deployment order

1. Add the Tunnel public-hostname rule and the proxied DNS CNAME for
   `api.aigiare.com` in the Cloudflare Zero Trust dashboard, then record it in
   `docs/aigiare-gateway-edge-routing.md`. This step is not in Git.
2. Run the database bootstrap and create the runtime secret.
3. `kubectl apply -k k8s` and let the `arda-backend` Application sync.
4. Register the first account through the console. The first account created
   becomes the root administrator.
5. Add the upstream channel, then run the verification below.

## Verification

Use a real upstream key, not the built-in channel test, and check the
failover path explicitly:

```bash
# readiness is DB-backed
curl -fsS https://api.aigiare.com/api/status

# OpenAI-compatible relay
curl -fsS https://api.aigiare.com/v1/chat/completions \
  -H "Authorization: Bearer sk-<customer-key>" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model>","messages":[{"role":"user","content":"ping"}]}'

# Claude native protocol, which is what Claude Code speaks
curl -fsS https://api.aigiare.com/v1/messages \
  -H "x-api-key: sk-<customer-key>" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{"model":"<model>","max_tokens":64,"messages":[{"role":"user","content":"ping"}]}'
```

The test that matters most: **disable the primary channel and repeat the
request.** The request must still succeed by failing over to the backup
channel. If it does not, the deployment is a single point of failure and the
backup channel was decorative.

Then confirm `kubectl -n aigiare-gw rollout restart deploy/aigiare-gateway`
does not invalidate existing customer keys.

## Deviations from cluster conventions

Deliberate and load-bearing. Do not "fix" these without understanding why.

| Convention | Here | Why |
| --- | --- | --- |
| `readOnlyRootFilesystem: true` | `false` | Upstream image sets `WORKDIR /data` and writes logs plus the SQLite fallback database there |
| `/health/live` and `/health/ready` probes | `/api/status`, plus a TCP liveness probe | new-api exposes no liveness endpoint; a DB-backed liveness probe would turn a Postgres blip into a restart loop on the only replica |
| Images from `ghcr.io/arda-labs/*` | `calciumion/new-api`, no pull secret | Third-party public image. Pinned to a numbered release and resolved to a digest by Image Updater, so it is as immutable as the rest |
| `replicas: 2` with pod anti-affinity | `1`, `strategy: Recreate` | `canary-policy-v1.json` requires a rollout to start at exactly one replica; session and rate-limit state is not yet proven shared |
| No internet egress grant | `allow-egress-internet` | A relay must reach hosts that do not exist yet |

## Local database and Valkey

`k8s/bootstrap-app-databases.sh` is not reused. That script gives every Arda
service role the same `APP_DATABASE_PASSWORD`, which is correct for one
product sharing one trust boundary. This gateway is a separate product, so it
gets its own credential, and losing its database must not be reachable from an
Arda service connection.

Valkey is shared and runs with `persistence.enabled: false`, so a Valkey pod
restart drops the gateway's cache. PostgreSQL remains the source of truth for
users, tokens, channels and quota, so this degrades rather than loses data —
but per-key rate-limit counters reset with it.

## Licence

new-api is AGPL-3.0 with additional terms. Modified versions that present a
user interface must keep the notice *"Frontend design and development by New
API contributors."* and a visible link to
<https://github.com/QuantumNous/new-api>. Because this deployment is offered
over the network, the corresponding source must be available to the people
interacting with it — which is the `agr-gateway` repository, published for
that reason. This deployment does not modify the code; the only divergence is
the addition of the build workflow and the Kubernetes manifests.
