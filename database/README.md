# Database

PostgreSQL cluster manifests for Arda.

## Components

- `pg-main.yaml`: CloudNativePG `Cluster` named `pg-main` in namespace `database`.
- `nodeport/pg-nodeport.yaml`: optional local/dev NodePort on `30432`.

## Setup

Install the CloudNativePG operator first, then apply the cluster:

```bash
kubectl apply -k database
```

For local development only, expose the primary instance with NodePort:

```bash
kubectl apply -k database/nodeport
```

The in-cluster service used by apps is:

```text
pg-main-rw.database.svc.cluster.local:5432
```

## Notes

- Keep the CloudNativePG operator version pinned in the machine/bootstrap docs.
- Do not expose `database/nodeport` on shared or public clusters unless firewall rules are already in place.
- The NodePort uses `externalTrafficPolicy: Local` so the client address
  survives to the pod; NetworkPolicy `allow-ingress-from-dev-workstation`
  (`k8s/network-policies/database`) admits only the developer workstation
  `/32`. Only the node running the primary answers, so list all three nodes:

  ```text
  postgres://<user>:<password>@192.168.10.201:30432,192.168.10.202:30432,192.168.10.203:30432/<db>?sslmode=disable&target_session_attrs=read-write&connect_timeout=3
  ```

- `kubectl apply -k database/nodeport` is manual: neither Argo Application
  includes this directory.
