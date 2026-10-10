# AiGiare gateway edge routing

Last updated: 2026-09-28

## Production topology

```text
Client
└── https://api.aigiare.com
    └── Cloudflare edge/WAF
        └── Cloudflare Tunnel `thinkcenter-promox`
            └── aigiare-gateway.aigiare-gw.svc.cluster.local:3000
                └── upstream AI providers (public internet)
```

This is a separate product from Arda and does not share a namespace, a
NetworkPolicy set, or a database with it. The only shared resources are the
`database` and `platform` namespaces, and the gateway reaches them through
explicit grants in `k8s/network-policies/`.

## Tunnel ingress is account state

The public-hostname rule is configured in the Cloudflare Zero Trust dashboard
and is **not** reconciled by Argo CD. Argo CD owns the Service, the Deployment
and the Ingress object; it cannot own this rule.

Add it manually:

```text
api.aigiare.com -> http://aigiare-gateway.aigiare-gw.svc.cluster.local:3000
```

plus a proxied CNAME for `api.aigiare.com` pointing at the tunnel, and update
this file in the same change. This mirrors how `api.arda.io.vn` is wired, and
`docs/api-edge-routing.md` records that rule for the same reason.

## The Ingress object is a second path, not the primary one

`k8s/gateway/ingress.yaml` declares `api.aigiare.com` on the `traefik` ingress
class. The tunnel does not have to traverse Traefik, but keeping the hostname
in Git gives a second way in during a tunnel outage and keeps the public
hostname declared somewhere reviewable. Both sources — `cloudflared` pods in
`platform` and the Traefik controller in `kube-system` — are granted on port
3000 in `k8s/network-policies/aigiare-gw/policies.yaml`.

## Client IP and rate limiting

`TRUSTED_PROXIES` is deliberately left empty in the Deployment. Empty means
new-api trusts loopback and RFC 1918, which covers the cloudflared pod network
and therefore lets Cloudflare's `X-Forwarded-For` chain resolve to the real
client IP — which is what per-IP rate limiting and abuse controls key on.

Setting it to a narrower CIDR that does not cover the cloudflared pods would
make every request appear to come from one address and disable per-IP limiting
without any visible error. Only narrow it after confirming the live pod CIDR.

## Egress

This is the only namespace in the cluster granted origin egress to the public
internet, and it is required: a relay has to reach upstream providers that
cannot be enumerated in advance. The grant excludes RFC 1918, link-local, CGNAT
and the node network, so the gateway cannot reach the banking services, the
data tier, or the Kubernetes API. See `allow-egress-internet` in
`k8s/network-policies/aigiare-gw/policies.yaml`.

## Database

Role and database are created out of band by `k8s/bootstrap-gateway-database.sh`,
not by Argo CD, because the `pg-main` Cluster is managed by the `arda-database`
Application with `prune: true` and hand-made objects in the `database`
namespace are not safe to declare in git. The role is `LOGIN` only, not a
superuser.

## Known gaps

- **No Gatus check for this endpoint.** `k8s/monitoring/gatus.yaml` has no
  entry for `api.aigiare.com` because the `monitoring` namespace has no egress
  grant to the public internet — only DNS, the node network, and the
  Kubernetes API. That also means the three existing `arda-public` checks
  (`web-app`, `api-gateway`, `docs-site`) cannot currently resolve or connect
  under the committed default-deny. This is a pre-existing gap in the
  NetworkPolicy work, not something introduced by the gateway, and it needs a
  decision before any public check can be added.
- **Valkey failover.** `REDIS_CONN_STRING` points at `valkey-master`, not
  Sentinel, because new-api has no Sentinel-aware client. A Valkey primary
  failover breaks the connection until the pod restarts. Acceptable at one
  replica; revisit if this ever scales out.
- **Upstream reachability unverified.** Nothing in this repo proves that the
  cluster's egress can reach the intended upstream host, or from which region
  it leaves. Verify from inside a pod before adding channels.
