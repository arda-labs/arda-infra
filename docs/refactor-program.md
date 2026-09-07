# Arda Refactor Infrastructure and Operations Plan

Status: execution in progress; runtime changes are landed only with their
corresponding backend/frontend contract and verification evidence.

Last updated: 2026-09-07

Post-2026-08-25 additions reflected in the manifests: `loan`, `mdm`,
`deposit`, `capital` and `statistical` services now have `k8s/apps` manifests
and Image Updater tracking (commits `89983e5`, `cb19db7`, `802cf29`); container
ports are unified at HTTP 8080 / gRPC 9090 (`ae8b8de`).

Runtime evidence status: repository render and CI gates are prepared; the local
environment currently has no configured Kubernetes context, so cluster rollout,
certificate handshake and recovery drills remain explicit deployment gates.

Read-only SSH evidence is now available from the operator node: control planes
and platform dependencies are healthy, but the deployed backend remains
Degraded due to an incomplete HRM secret, one auth-gateway crashloop, absent
mTLS Secrets and an older image without the new metrics endpoint. The detailed
record is maintained in the backend runtime evidence document.

Repository-side backup hardening is landed: ordinary snapshots omit Secret data,
the archive records format/namespace metadata and checksums every artifact, and
encrypted Secret export requires explicit age-based operator configuration.
`restore.sh` verifies an explicitly selected archive and rejects the production
namespace; it does not pretend a platform resource snapshot is a database
backup or apply a restore without an operator-reviewed isolated target plan.

Repository-side secret hygiene is also gated: Ory values, application database
bootstrap, Compose-style endpoint examples and generated rendered values no
longer contain committed credentials. `scripts/check-secret-hygiene.mjs` and
the Kustomize render gate pass; secret rotation and cluster presence still need
an environment run.

The canary/rollback policy is now versioned at
`platform/policy/canary-policy-v1.json` and checked by
`scripts/check-canary-policy.mjs`. It requires one immutable canary replica,
explicit halt thresholds, correlation fields and forward-recovery handling for
irreversible schema/data/event changes. It is a release policy, not evidence
that a live canary has already been executed.

The cross-stack master plan lives in the workspace at
`arda-be/docs/refactor-program/README.md`. This document covers the infrastructure,
edge, observability, secrets, integration environment, deployment, recovery and
capacity work needed to make the application refactor safe.

The executable evidence checklist for canary, backup/restore, event durability,
performance and security release gates is
[refactor-operational-gates.md](refactor-operational-gates.md).

## 1. Outcomes

- Explicit edge-to-service route ownership matching the application policy registry.
- Authenticated and encrypted internal service calls, with restrictive network
  policy. Signed workload assertions are an authorization layer, not a
  substitute for transport encryption.
- Secret references and tested rotation instead of tracked runtime credentials.
- Production-like integration/staging dependencies and contract testability.
- End-to-end telemetry before large migration waves.
- GitOps canary/rollback that distinguishes workload readiness from user success.
- Backup/restore and event replay procedures rehearsed before destructive cleanup.

## 2. Edge and routing

The target path remains explicit:

```text
browser
  -> Cloudflare DNS/WAF/Tunnel
  -> Traefik
  -> auth-gateway for browser session/policy context where required
  -> explicitly owned domain route
```

Required controls:

- Inventory Cloudflare hostname/path, tunnel ingress, Traefik routes and gateway policies.
- Detect public routes missing from any layer or pointing to a different owner.
- Keep public identity headers untrusted and stripped at the gateway boundary.
- Route unknown protected operations to deny/not-found, never generic authenticated pass-through.
- Keep CORS exact-origin and credentialed behavior synchronized with API hostname,
  cookie, CSRF/origin and OAuth redirect policy.
- Apply WAF/rate limit by path/method/risk class while preserving backend limits.
- Measure Cloudflare colo/network time separately from origin/gateway time.

## 3. Service identity and network

- Select and provision the accepted workload identity mechanism from ADR-006.
- Internal gRPC now requires mTLS files (`ca.crt`, `tls.crt`, `tls.key`) plus a
  signed short-lived HMAC assertion; missing files fail startup and plaintext
  is not an accepted fallback. Use the backend
  `docs/refactor-program/09-mtls-runbook.md` for Secret names, SANs, mounts,
  rotation, and verification.
- Authorize caller service/method at the callee; network namespace alone is insufficient.
- Use network policies to reduce reachability in addition to identity.
- Separate user delegation metadata from workload authentication.
- Rotate trust material without all-service outage.
- Provide integration/staging parity so identity failures are caught before production.

## 4. Secrets

- Inventory every DB, Redis, NATS, Ory, storage, OAuth and signing credential.
- Record owner, consumers, environments, rotation interval and emergency revoke path.
- Replace tracked values with placeholders and Kubernetes/External Secret references.
- Prevent secrets from entering ConfigMaps, image layers, build args, frontend bundles,
  logs, traces and GitOps rendered output.
- Rotate previously exposed values and invalidate exposed sessions/cookies privately.
- Alert on failed/expired secret rollout without printing secret material.

## 5. Integration and staging platform

Provide reproducible, isolated dependencies:

- PostgreSQL version compatible with migrations, one service-owned database/role;
- Redis where used;
- NATS JetStream streams, durable consumers and DLQ policy; publishers must wait
  for PubAck and use a stable event/outbox ID for duplicate suppression;
- object storage with multipart/presigned behavior;
- Ory/Kratos/Hydra auth integration or a contract-faithful test setup;
- Zeebe reachable only through Workflow service;
- OTel collector/export, structured logs and metrics;
- synthetic multi-tenant/org data.

Local development may use mocks for unavailable dependencies, but integration
tests must exercise real protocol behavior, especially auth, PostgreSQL, JetStream,
multipart upload and gRPC deadlines.

## 6. Observability platform

Provision before domain migration waves:

- W3C trace ingestion and correlation across HTTP/gRPC/events;
- log schema parsing, retention and redaction;
- API/gateway/service/DB/JetStream/Zeebe/storage dashboards;
- MFE remote/version/route and browser performance dashboards;
- SLO burn-rate alerts for critical journeys;
- canary comparison by version/tenant/cohort without high-cardinality overload;
- audit storage/access/retention separated from application logs.

Telemetry labels must use route templates, RPC methods, service/version and stable
codes, not user/resource IDs.

## 7. GitOps and CI controls

- Validate schema/policy of manifests and render every environment overlay.
- Diff route inventory against application endpoint/policy catalog.
- Verify secret references exist without exposing values.
- Pin image digests or approved immutable versions for controlled rollout.
- Surface ArgoCD Application health separately from pod readiness.
- Smoke test actual route, contract, auth and critical journey after rollout.
- Retain previous known-good application/MFE artifacts and manifests.
- Require manual approval for destructive schema cleanup and trust-root rotation.

## 8. Canary and feature switches

- Deploy additive schema/foundations first.
- Switch compatible adapters by explicit cohort/tenant where business semantics allow.
- Do not canary a non-idempotent command by duplicating requests.
- Define halt thresholds for errors, latency, policy denials, DB locks, event lag and business reconciliation.
- Roll back code only while schema remains backward compatible.
- Use forward recovery for irreversible data changes.
- Keep switches few, owned, observable and tied to cleanup work packages.

## 9. Data protection and recovery

- Verify automated backup completion and retention per service database.
- Keep Kubernetes Secret snapshots out of ordinary backups; if a secret backup
  is explicitly required, encrypt it with the documented age recipient flow.
- Rehearse restore to isolated environment and execute application reconciliation.
- Capture migration-specific backup/reference before risky changes.
- Monitor storage headroom, WAL/replication, lock waits and migration batch pressure.
- Define JetStream retention, replay, DLQ and projection rebuild procedures.
- Define object storage lifecycle for incomplete multipart uploads and orphaned objects.
- Never delete old schema/data in the same rollout that first switches consumers.

## 10. Capacity and performance

For each migration wave compare:

- public Cloudflare path versus origin/gateway/service timing;
- achieved RPS, completed iterations, dropped work, errors and p95/p99;
- CPU/memory/pod saturation and autoscaling behavior;
- DB connections, pool wait, locks, query plans and I/O;
- JetStream publish ack, consumer lag and redelivery;
- MFE artifact/cache behavior and route load;
- object storage throughput and multipart cleanup.

Do not infer backend slowness from public waiting time alone. Preserve a direct
internal measurement path for diagnosis without exposing services publicly.

## 11. Infrastructure phases

### OPS-0 — Inventory and baseline

- Edge/route, service/dependency, secret, dashboard, backup and environment catalog.
- Current public/internal performance and capacity baseline.

### OPS-1 — Security containment

- Route mismatch alerts/gates, privileged-header boundary, secret rotation and
  restrictive direct-service reachability.

### OPS-2 — Foundation platform

- Integration dependencies, service identity reference, OTel/log/metrics baseline,
  GitOps validation and canary pattern.

### OPS-3 — Pilot support

- Dashboards, alerts, feature switches and recovery evidence for list, high-risk
  command and media pilots.

### OPS-4 — Domain waves

- Add service-specific SLOs, JetStream streams/consumers, DB migration monitoring
  and workload identity as each domain moves.

### OPS-5 — Hardening and cleanup

- Capacity/failure/DR drills, complete secret rotation, remove temporary routes,
  insecure transport and expired switches; validate final documentation against deployment.

## 12. Infrastructure definition of done

- Runtime routes match catalog and missing policy fails closed.
- Internal protected calls authenticate workload and are encrypted.
- No tracked/runtime secret leaks through config, logs, traces or frontend assets.
- Integration/staging reproduce critical protocol behavior.
- Traces, logs, metrics, SLOs and canary comparison are operational.
- Backup restore and event replay are rehearsed with evidence.
- Rollout checks actual user/API behavior, not pod readiness alone.
- Every temporary route, switch and compatibility resource has a cleanup owner/date.

## 13. Safe subagent split

Infrastructure work can run in parallel by non-overlapping ownership:

- edge/route inventory and policy validation;
- observability collectors/dashboards;
- integration dependency stack;
- secret references/rotation preparation;
- backup/restore and replay runbooks;
- GitOps CI/canary mechanics.

Trust-root, ingress, namespace-wide network policy and shared observability schema
changes require one integrator because concurrent edits can produce cluster-wide effects.
