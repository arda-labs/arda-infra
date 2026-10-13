# Database

PostgreSQL cluster manifests for Arda.

## Components

- `pg-main.yaml`: CloudNativePG `Cluster` named `pg-main` in namespace `database`.
- `loadbalancer/pg-main-lb.yaml`: LAN VIP `192.168.10.210:5432` for the primary (dev tools, agent MCP).

## Setup

Install the CloudNativePG operator first, then apply the cluster:

```bash
kubectl apply -k database
```

For LAN access from the developer workstation, expose the primary on the
MetalLB VIP (needs `platform/bootstrap/install-metallb.sh` first):

```bash
kubectl apply -k database/loadbalancer
```

The in-cluster service used by apps is:

```text
pg-main-rw.database.svc.cluster.local:5432
```

## Notes

- Keep the CloudNativePG operator version pinned in the machine/bootstrap docs.
- Do not expose `database/loadbalancer` on shared or public clusters unless firewall rules are already in place.
- The VIP Service uses `externalTrafficPolicy: Local`: MetalLB announces
  `192.168.10.210` only from the node holding the primary, so the VIP follows
  a CNPG failover, and the client address survives to the pod, where
  NetworkPolicy `allow-ingress-from-dev-workstation`
  (`k8s/network-policies/database`) admits only the developer workstation
  `/32`:

  ```text
  postgres://<user>:<password>@192.168.10.210:5432/<db>?sslmode=disable
  ```

- `kubectl apply -k database/loadbalancer` is manual: neither Argo Application
  includes this directory.
