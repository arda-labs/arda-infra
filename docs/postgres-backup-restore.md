# PostgreSQL backup and restore

`database/pg-main.yaml` uses the Barman Cloud CNPG-I plugin to archive WAL and
create physical backups in the dedicated Garage bucket `arda-postgres-backups`.
The daily `ScheduledBackup` runs at 02:00 UTC and `immediate: true` asks CNPG to
create the first base backup when the schedule is created. Garage is a different
storage system from the `pg-main` PVCs, but it is still inside this cluster; it
does not protect against loss of the whole cluster or its Garage data.

## One-time setup

1. Create the bucket and a dedicated Garage S3 key. Do not reuse the application
   media key. Use Garage's admin interface or run these commands in the Garage
   pod as an operator:

   ```sh
   /garage bucket create arda-postgres-backups
   /garage key create arda-postgres-backup
   /garage bucket allow --read --write --owner arda-postgres-backups --key <ACCESS_KEY_ID>
   ```

   Store the returned key ID and secret in the organization's secret manager.
   Never paste them into Git, chat, tickets, or command output. The bucket may
   be created on first use by S3 clients, but creating it and granting access
   explicitly makes the Garage ownership boundary reviewable.

2. Create the database namespace Secret out of band. The template is
   [`database/pg-main-backup-secret.example.yaml`](../database/pg-main-backup-secret.example.yaml);
   replace both placeholders only in a secure local copy, apply it, then remove
   the populated copy. For Windows PowerShell, a temporary env file avoids
   putting the secret values in shell history or printing them:

   ```powershell
   $secretFile = Join-Path $env:TEMP ("pg-main-backup-{0}.env" -f [guid]::NewGuid())
   $accessKey = Read-Host "Garage access key ID"
   $secretValue = Read-Host "Garage secret access key" -AsSecureString
   $secretPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretValue)
   try {
     $secretPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPtr)
     [IO.File]::WriteAllLines($secretFile, @("ACCESS_KEY_ID=$accessKey", "ACCESS_SECRET_KEY=$secretPlain"), [Text.UTF8Encoding]::new($false))
     kubectl -n database create secret generic pg-main-backup-s3 --from-env-file=$secretFile --dry-run=client -o yaml |
       kubectl apply -f -
   } finally {
     if (Test-Path -LiteralPath $secretFile) { Remove-Item -LiteralPath $secretFile -Force }
     [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr)
     Remove-Variable secretPlain, accessKey, secretValue -ErrorAction SilentlyContinue
   }
   ```

   Run this only from a secured operator workstation. The temporary file holds
   plaintext briefly and is deleted in `finally`; the Secret is created in the
   `database` namespace. Confirm Kubernetes Secret encryption at rest is enabled
   for the cluster.

3. Review and merge the GitOps change, then let Argo CD install cert-manager
   before the Barman Cloud plugin. The plugin chart requires cert-manager and
   CNPG 1.26 or later. This cluster was read-only inspected at CNPG 1.30.1.
   Confirm both Argo Applications are Healthy and the `ObjectStore` CRD is
   established before syncing the database Application. If the database sync
   raced ahead of plugin installation and reports a missing CRD, retry it after
   the plugin is Healthy.

4. After the `pg-main` Cluster has the plugin and the Secret is present, verify
   the first backup and WAL archiving:

   ```powershell
   kubectl -n database get scheduledbackup pg-main-daily
   kubectl -n database get backup
   kubectl -n database get cluster pg-main
   kubectl -n database describe objectstore pg-main-backup
   ```

   Proceed only when a backup has phase `completed`, the Cluster reports the
   expected healthy state, and WAL objects are visible in the Garage bucket.
   Argo health alone does not prove that Garage accepted a backup.

## Restore drill into the isolated namespace

The repo provisions `database-restore` with default-deny ingress and only the
DNS, Kubernetes API, and Garage S3 egress needed by a restore. Use a separate
Garage key with read-only access for the restore store. Create
`database-restore/pg-main-backup-restore-s3` with the same two Secret keys as
the production Secret; do not reuse a read-write key for the restore operation.

Create the read-only ObjectStore and a one-instance recovery Cluster in a
temporary manifest outside the tracked GitOps tree:

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: pg-main-backup-restore
  namespace: database-restore
spec:
  configuration:
    destinationPath: s3://arda-postgres-backups/
    endpointURL: http://garage.platform.svc.cluster.local:3900
    s3Credentials:
      accessKeyId:
        name: pg-main-backup-restore-s3
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: pg-main-backup-restore-s3
        key: ACCESS_SECRET_KEY
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-main-restore-drill
  namespace: database-restore
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.0
  bootstrap:
    recovery:
      source: pg-main-backup
  externalClusters:
    - name: pg-main-backup
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-main-backup-restore
          serverName: pg-main
  storage:
    storageClass: local-path
    size: 10Gi
```

Apply the temporary manifest only after the read-only Secret exists and the
plugin is Healthy. Observe it without changing the source cluster:

```powershell
kubectl apply -f .\pg-main-restore-drill.yaml
kubectl -n database-restore get cluster,pods
kubectl -n database-restore get pods -w
kubectl -n database-restore get cluster pg-main-restore-drill -o yaml
```

Checklist:

- The recovery Cluster reaches healthy state and its PostgreSQL pod is Ready.
- Application-level checks on the restored database confirm expected schemas,
  representative row counts, and a recent recovery point. Do not print PII.
- The original `database/pg-main` Cluster and its PVCs remain untouched.
- Record completion time, source backup ID, observed recovery point, and any
  missing data in the operational record without credentials or PII.
- After review, remove only the drill Cluster and PVCs, the read-only Secret,
  and the temporary manifest according to the operator's retention procedure.
  Verify the selected PVC names belong to `database-restore` before any deletion.

The first real backup and restore remain operator-run steps. This repository
change only renders desired state; it does not create credentials, sync Argo CD,
or touch the cluster.
