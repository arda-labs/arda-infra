# ThinkCentre recovery — 2026-10-07

The three Arda VMs and their disks had been removed from Proxmox. No local
VM backup was present. The owner explicitly chose a fresh database.

## Recovered runtime

| VM | Address | RAM | Virtual disk |
| --- | --- | --- | --- |
| 101 / k3s-node1 | 192.168.10.201 | 8 GiB | 35 GiB |
| 102 / k3s-node2 | 192.168.10.202 | 8 GiB | 35 GiB |
| 103 / k3s-node3 | 192.168.10.203 | 6 GiB | 35 GiB |
| 104 / aigiare-gw | 192.168.10.211 | 6 GiB | 100 GiB |

VM 104 was reduced from 16 GiB RAM and rebooted; all five VIPAI workloads
returned Ready. Docker build cache cleanup reclaimed 26.6 GB, followed by
filesystem TRIM. Its filesystem uses approximately 13 GiB and its thin volume
approximately 16.1 GiB. Its 100 GiB virtual capacity was retained: shrinking
the virtual block device directly would truncate the filesystem. Thin storage
does not reserve that entire capacity.

Arda uses K3s v1.36.5+k3s1, Cilium 1.20.2, a single control plane and two
agents. All VMs start automatically with the host; QEMU guest agents run.
CloudNativePG has three healthy PostgreSQL 18 instances. NATS, Valkey Sentinel,
Garage, Zeebe 8.5, Elasticsearch, Hydra, Kratos and monitoring are running.
All 15 backend Deployments are Ready with one replica per service, using
`overlays/thinkcenter-recovery`. The separate VM hosts AiGiare; its obsolete
in-cluster gateway workloads remain scaled to zero in this recovery overlay.

The frontend continues to be served by the existing Cloudflare Workers site.
The in-cluster frontend is intentionally not duplicated. Argo CD is installed;
backend GitOps tracks `codex/thinkcenter-recovery` and its recovery overlay.

## Fresh-install fixes

Infrastructure fixes cover current Cilium Helm options, routable pod egress,
node CIDR policy matching, PostgreSQL replication/API/auth access, Sentinel
discovery, tunnel ingress, selected workloads' external HTTPS, and Alloy's
data volume ownership and explicit projected API credentials. Auth admin
NodePort manifests now declare their namespace.

Three backend migrations failed on a clean installation:

- IAM: move only the known bootstrap superadmin user/role from the legacy
  placeholder tenant to the explicit system scope before validating checks.
- AI: replace only empty UUID knowledge tables before creating the newer
  BIGINT RAG schema; fail if legacy tables contain any records.
- HRM: remove a duplicated block adding tenant columns a second time.

Recovery binaries were built from committed backend revision
`c3c96299f064321ef6392d8d7a6c96f2d7498045` plus those three SQL changes.
Existing unrelated uncommitted backend changes were excluded. The IAM, AI and
HRM recovery images were imported on all three nodes under
`recovery-20261007`; **they have not been published to GHCR**. The AI image
also contains `ai-eval` and the committed evaluation sets. Image archives
are retained on node1 at `/home/hoan/arda-recovery-images` and in the local
temporary recovery build directory.

## Verification

- All three nodes Ready; PostgreSQL reports `Cluster in healthy state`.
- All 15 backend Deployments Ready; IAM, AI and HRM completed their Goose
  migration chains without changing migration tracking manually.
- Superadmin password login through the Kratos LAN ingress: HTTP 200 and
  active session. Gateway `/health/ready`: `{"status":"ready"}`.
- A separate temporary database confirmed the AI migration refuses populated
  legacy knowledge tables and retains their records; that test database was
  removed afterward.
- Migration standards, workload hardening, secret hygiene, network policy,
  canary policy and operational gates pass; recovery Kustomize renders and
  `git diff --check` passes for the changed files.
- The workstation's default kubeconfig points at the new cluster; the former
  file is retained as `.kube/config.pre-recovery-20261007-*`.

Generated cluster secrets and CA keys are kept outside Git in node1's
root-only `/root/arda-rebuild`. Operator login credentials are saved on the
workstation in `C:\Users\hoanv\.config\arda-recovery-20261007\logins.json`
with restricted ACLs. No passwords or tokens are included in this report.

## GitOps and public edge

Commit/push and reconnecting GitOps were explicitly authorized. The three
backend migration fixes are published as
`5e2c34d34f9babbe36d7907b47b37331793af852`. Unrelated working-tree changes
remain excluded. CI successfully published all 15 backend images; the recovery overlay
references this immutable commit for IAM, AI, HRM and auth-gateway.

Infrastructure uses `codex/thinkcenter-recovery`, retaining the necessary
existing Cilium/network-policy foundation without moving `main`. Argo CD is
installed with private repository and registry credentials. Both backend and database applications are `Synced / Healthy`. Image Updater
successfully updated all 15 backend image digests with no errors.

The supplied Cloudflare tunnel token is installed; two connectors are Ready.
Public gateway, Hydra and Kratos readiness endpoints return HTTP 200, and
public Kratos password login returns an active session. The new gateway fixes the old image's incorrect OAuth UI host: OAuth lands
on `https://arda.io.vn/login` with HTTP 200. Public gateway password login
and IAM login acceptance succeed and reach the expected MFA enrollment step. Superadmin MFA is not activated by the recovery operator; the owner must
scan the enrollment QR and verify a code at first login. A full authenticated
OAuth callback after that user-owned step remains untested.

Gatus application/public/self checks now pass after fixing selector mismatches
and its explicit egress grants. The Image Updater manifest uses one reference
per application, as required by its CRD. A startup NATS stream collision was
resolved by provisioning ARDA_EVENTS with explicit business prefixes that do
not overlap AI_EVENTS. `platform/bootstrap/init-event-streams.sh` records this
prerequisite and preserves existing streams on repeated runs.

## Backups

All three snapshot backups completed successfully and passed `zstd -t`:

- `/var/lib/vz/dump/vzdump-qemu-101-2026_10_07-19_00_30.vma.zst` (5.85 GB)
- `/var/lib/vz/dump/vzdump-qemu-102-2026_10_07-19_01_58.vma.zst` (4.90 GB)
- `/var/lib/vz/dump/vzdump-qemu-103-2026_10_07-19_03_20.vma.zst` (3.90 GB)

A further node1 backup after GitOps/tunnel restoration completed at 19:18:
`/var/lib/vz/dump/vzdump-qemu-101-2026_10_07-19_16_36.vma.zst` (5.87 GB).
Archive integrity was verified; a restore drill has not been performed.
The new VMs share one physical host; three guests do not protect against a
host or disk failure. These archives are local recovery copies.

## Owner configuration

Tenant AI providers, embedding credentials and optional alert integrations
must be configured for the fresh installation. The former database and its
configuration were not recovered.