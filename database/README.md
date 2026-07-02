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
