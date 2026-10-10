// Requires every workload in k8s/ to declare a pod securityContext and resource
// limits.
//
// Why this is a gate rather than a review note:
//
//   - Without memory limits, the reachable memory-exhaustion bugs (an unbounded
//     request body read in the gateway, the gRPC HTTP/2 fragmentation CVE) are
//     pod-scoped at best. On a three-node cluster with no limits they pressure
//     the kubelet and can take the node, and with it every other pod on it.
//   - runAsNonRoot / allowPrivilegeEscalation:false / capabilities:drop[ALL] are
//     what stop a compromised process in a container from becoming root on the
//     node. Their absence is invisible until someone finds an RCE.
//   - automountServiceAccountToken:false removes the API credential from every
//     pod that never calls the API server, which is the precondition for the
//     egress restrictions in k8s/network-policies/ meaning anything.
//
// The one documented exception is prometheus/alertmanager, which refuses to
// start as an arbitrary uid, so it is allowlisted by name rather than by
// omitting the check.

import { readFile, readdir } from "node:fs/promises"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(fileURLToPath(new URL("..", import.meta.url)))
const errors = []

// Alertmanager refuses to run as a non-root uid, so demanding runAsNonRoot
// there would be a gate nobody can satisfy. It is a single upstream Deployment
// that is not part of this platform's trust boundary.
const ALLOWLIST = new Map([
  ["k8s/monitoring/grafana-alerting.yaml", "prometheus/alertmanager cannot run as a non-root uid"],
])

// Workloads that legitimately keep the ServiceAccount token mounted, because the
// API is the credential they actually authenticate with. Removing it breaks
// observability silently rather than loudly, so the exemption is explicit and
// scoped to the two workloads rather than switched off for the namespace.
const KEEP_SERVICE_ACCOUNT_TOKEN = new Set([
  "k8s/monitoring/victoria-metrics.yaml",
  "k8s/monitoring/cluster-metrics.yaml",
])

const REQUIRED = [
  ["runAsNonRoot", /runAsNonRoot:\s*true/],
  ["runAsUser", /runAsUser:\s*\d+/],
  ["allowPrivilegeEscalation", /allowPrivilegeEscalation:\s*false/],
  ["readOnlyRootFilesystem", /readOnlyRootFilesystem:\s*true/],
  ["seccompProfile", /seccompProfile:\s*\n\s*type:\s*RuntimeDefault/],
  ["capabilities", /capabilities:\s*\n\s*drop:\s*\n\s*- ALL/],
]

for (const dir of ["k8s/apps", "k8s/monitoring", "k8s/frontend"]) {
  for (const name of await readdir(join(root, dir))) {
    if (!name.endsWith(".yaml")) continue
    const rel = `${dir}/${name}`
    if (name === "kustomization.yaml") continue
    const manifest = await readFile(join(root, dir, name), "utf8")

    // Workloads only. Ingress/Service/ConfigMap carry no pod spec.
    const workloadCount = (
      manifest.match(/^kind:\s*(Deployment|StatefulSet|DaemonSet|CronJob|Job)\s*$/gm) ?? []
    ).length
    if (workloadCount === 0) continue

    const exception = ALLOWLIST.get(rel)

    for (const [label, pattern] of REQUIRED) {
      if (exception && label === "runAsNonRoot") continue
      // Counted, not just present: a manifest with two workloads and one
      // securityContext is half-hardened, which is the case worth catching.
      const hits = (manifest.match(new RegExp(pattern.source, "gm")) ?? []).length
      if (hits < workloadCount) {
        errors.push(
          `${rel}: pod securityContext "${label}" appears ${hits} time(s) for ${workloadCount} workload(s)` +
            (exception ? ` (allowed to differ here: ${exception})` : ""),
        )
      }
    }

    // The API server credential. Every other workload reaches its dependencies
    // with a password or a service-auth secret, never with a ServiceAccount
    // token, so mounting one is pure exposure.
    if (KEEP_SERVICE_ACCOUNT_TOKEN.has(rel)) {
      // Must still be explicit that the token is intentional, so nobody reads
      // the omission as an oversight and "fixes" it.
      if (!/automountServiceAccountToken:\s*true/.test(manifest)) {
        errors.push(
          `${rel}: keeps the ServiceAccount token on purpose; say so with an ` +
            "explicit `automountServiceAccountToken: true` so the exemption is visible",
        )
      }
    } else {
      const tokenHits = (manifest.match(/automountServiceAccountToken:\s*false/g) ?? []).length
      if (tokenHits < workloadCount) {
        errors.push(
          `${rel}: automountServiceAccountToken is not false on every workload; each pod is mounting an API credential`,
        )
      }
    }

    // Resource limits. requests and limits must both be present, and memory
    // must be limited: the reachable DoS bugs are memory and body-size based.
    if (!/^\s+resources:\s*$/m.test(manifest)) {
      errors.push(`${rel}: no resources block; a memory-exhaustion bug can take the node, not just the pod`)
    } else {
      if (!/^\s+requests:\s*$/m.test(manifest)) {
        errors.push(`${rel}: resources has no requests`)
      }
      if (!/^\s+limits:\s*$/m.test(manifest)) {
        errors.push(`${rel}: resources has no limits`)
      }
      if (!/^\s+memory:\s*\d+Mi\s*$/m.test(manifest)) {
        errors.push(`${rel}: resources.limits has no memory limit in Mi`)
      }
    }
  }
}

if (errors.length) {
  console.error(errors.join("\n"))
  process.exit(1)
}

console.log("Workload hardening OK: pod securityContext, no SA token mount, and resource limits on every workload")
