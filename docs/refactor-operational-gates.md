# Refactor operational gates

This is the evidence checklist for Phase 8/9. A code review or a green pod
readiness probe is not sufficient evidence for these gates.

Notification outbox startup is fail-closed: the workload must have a required
`NATS_URL`, connect to JetStream, and initialize the `ARDA_EVENTS` stream before
serving traffic. A missing or unavailable broker is a rollout failure, not a
reason to leave events pending silently.

## Canary

The machine-readable release policy is
`platform/policy/canary-policy-v1.json`; `scripts/check-canary-policy.mjs`
validates its one-replica, immutable-image, halt-threshold and recovery rules.

1. Deploy an immutable image digest to one replica only.
2. Route a declared test cohort; never duplicate non-idempotent commands.
3. Compare the canary and baseline by route, status, tenant/cohort, p50/p95/p99,
   database latency, upstream latency, error code, and saturation.
4. Halt on the agreed error/latency/budget threshold and restore the previous
   image digest using the same GitOps unit.
5. Record image digest, cohort, start/end time, request IDs, dashboards, and
   rollback result in the migration ledger.

## Backup and restore

For every service-owned PostgreSQL database:

- verify the latest backup checksum, age, retention and encryption;
- restore into an isolated database/namespace, never over production;
- apply migrations and run service health plus representative read/write
  reconciliation checks;
- verify tenant counts, critical state transitions, outbox rows and audit rows;
- record RPO/RTO measurements and the exact backup/restore commands.

Use the existing `platform/bootstrap/backup.sh` and `restore.sh` only with an
explicit archive/target plan. `backup.sh` now writes a format/namespace
metadata file and SHA256 checksums for every artifact. It excludes Secret data
by default and requires `BACKUP_INCLUDE_SECRETS=true` plus an `age` recipient
before producing encrypted Secret snapshots. `restore.sh` verifies an explicit
archive and refuses the `platform` namespace; it is intentionally verification
only until an operator chooses the Helm and service-owned database restore
procedure. A platform resource snapshot is not a PostgreSQL backup.

## Event durability

For JetStream-backed outboxes, evidence must include a committed outbox row,
the PubAck and stable `Nats-Msg-Id`, a consumer acknowledgement after local
commit, duplicate delivery deduplication, retry delay, DLQ placement, and a
scoped replay. Replays require an operator identity, event ID/tenant filter,
bounded time range and an audit record.

The notification source tree now provides
`go run ./cmd/notification-replay --outbox-id ... --operator ... --confirm
REPLAY_ONE` for the bounded one-event operation. This is an execution tool, not
runtime evidence; the actual replay and downstream reconciliation still need a
staging/production-like drill.

## Tenant-default removal

The new Finance, Platform, CRM, Notification and Workflow migrations remove
synthetic tenant defaults and add non-empty/non-`default` checks as `NOT VALID`.
Before validating those
constraints, run a reviewed assignment job per service/database:

- inventory rows with `tenant_id = 'default'`, `tenant_id = ''`, or whitespace;
- reconcile each row to an authoritative tenant from the owning identity/domain
  source, with an exception report for rows that cannot be assigned;
- update in bounded, auditable batches and verify counts/checksums per tenant;
- only then run `VALIDATE CONSTRAINT` and record the operator, migration version,
  row counts and reconciliation evidence.

No migration or application default may assign an unknown row to a guessed
tenant. Unassigned rows block the release gate.

## Performance

Measure client-to-edge, edge-to-origin, gateway, application, database and
upstream spans separately. For browser calls, preserve the authenticated cookie
contract (`credentials: "include"`); a performance test that removes cookies
is not representative. Record cold/warm, cache hit/miss, and regional results.

## Security release gate

Before removing a legacy path, verify no source or built artifact still uses it,
the gateway policy has no route for it, the current/previous remote compatibility
matrix is green, and the rollback image cannot restore a known fail-open policy.

## Manifest render gate

Render the exact Kustomize tree before apply and inspect Secret references,
certificate mounts, probes and ports:

```bash
kubectl kustomize k8s/apps > /tmp/arda-apps-rendered.yaml
```

The repository render is currently valid. This is only a composition check;
cluster apply, Secret presence, TLS handshakes and rollout health still require
environment evidence.

Run `platform/bootstrap/verify-runtime-secrets.sh` against the target cluster
before applying workload revisions. It checks required database/broker/workload
keys and all eight mTLS Secret triplets (crm, iam, platform, workflow, hrm,
finance, media, notification) without printing Secret values; it fails
closed on a missing `HRM_DATABASE_DSN` or certificate Secret. Note the newer
gRPC services (loan, deposit, capital, statistical) are not yet covered by the
script's triplet list — extend it when provisioning their certificates.

## Current evidence snapshot

> **Snapshot:** dated 2026-08-25. Re-verify the live cluster before relying on
> the degraded-state list below; the K3s nodes are reachable via SSH audit.

As of 2026-08-25, `kubectl kustomize k8s/apps` passes and repository CI
render/identity/secret checks are defined. The workstation kubeconfig has no
current context, but a read-only SSH audit through `k3s-node1` confirmed all
three control planes and core platform dependencies are running. The deployed
Argo CD backend is still `Degraded`: HRM lacks `HRM_DATABASE_DSN`, one
auth-gateway pod exits 139, no `arda-grpc-tls-*` Secrets are present, and the
live IAM image has no `/metrics` endpoint. Therefore rollout, mTLS handshake,
canary, backup/restore and event replay remain open. Detailed evidence and
tenant-default counts are recorded in
`arda-be/docs/refactor-program/runtime-evidence-20260825.md`.

A read-only unauthenticated edge smoke returned the expected `401` with
`cf-cache-status: DYNAMIC` and HKG `CF-RAY` from `api.arda.io.vn`; ten samples
from the node had approximately `104–188 ms` TTFB. This proves only the public
edge/auth boundary, not authenticated origin or database latency. The sampled
deployed auth response also had a body `request_id` different from its
`X-Request-Id`; the backend shared problem writer now forces both to the
request-boundary ID, pending rollout verification.
