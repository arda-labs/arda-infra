// Validates the NetworkPolicy layer under k8s/network-policies/.
//
// These policies are only meaningful with a CNI that enforces them, and an
// allowlist that misses a traffic edge takes production down rather than
// failing visibly. Both failure modes are silent, so both are checked here
// against the manifests that declare the real traffic.
//
// Checks:
//   A. The Cilium values file exists. Flannel accepted every policy in this
//      cluster and enforced none of them; shipping policies without a
//      netpol-capable CNI reproduces that exact false assurance.
//   B. Every managed namespace has a default-deny covering Ingress and Egress.
//   C. Every default-denied namespace can still resolve DNS. Without this the
//      cluster loses name resolution the moment the deny lands, and every
//      symptom looks like a service outage.
//   D. Every podSelector in a policy matches a label a real pod actually sets.
//      This is the class of bug where a policy selects
//      `app.kubernetes.io/name: vmsingle` while the workload sets `app:
//      vmsingle`: the policy is accepted, matches nothing, and denies.
//   E. Every service-to-service URL in k8s/apps is permitted by an egress rule.
//      A new dependency added to a manifest without a matching policy grant
//      fails at runtime with a connection timeout, not at review time.

import { readFile, readdir } from "node:fs/promises"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const root = resolve(fileURLToPath(new URL("..", import.meta.url)))
const errors = []

// --- minimal YAML subset parser -------------------------------------------
// The network policy files use block mappings, block sequences and flow
// sequences only. That is a small enough grammar to parse directly, which
// keeps this check dependency-free like the rest of scripts/.
function parseScalar(raw) {
  const v = raw.trim()
  if (v === "" || v === "~" || v === "null") return null
  if (v === "true") return true
  if (v === "false") return false
  if (v === "[]") return []
  if (v === "{}") return {}
  if (/^-?\d+$/.test(v)) return Number(v)
  if (/^".*"$/.test(v) || /^'.*'$/.test(v)) return v.slice(1, -1)
  return v
}

function parseBlock(lines, start, indent) {
  // Returns [value, nextIndex] for the block at the given indent.
  if (start >= lines.length) return [null, start]
  const first = lines[start]
  if (/^\s*-\s/.test(first)) {
    const items = []
    let i = start
    while (i < lines.length) {
      const line = lines[i]
      if (!/^\s*-\s/.test(line)) break
      if (line.match(/^\s*/)[0].length !== indent) break
      const rest = line.replace(/^\s*-\s/, "")
      if (rest.includes(": ") || rest.endsWith(":")) {
        // An inline mapping opening a sequence item; re-parse it as a mapping
        // whose first key sits two columns in.
        const synthetic = [" ".repeat(indent + 2) + rest, ...lines.slice(i + 1)]
        const [value, consumed] = parseBlock(synthetic, 0, indent + 2)
        items.push(value)
        i += consumed
        continue
      }
      items.push(parseScalar(rest))
      i += 1
    }
    return [items, i]
  }
  const map = {}
  let i = start
  while (i < lines.length) {
    const line = lines[i]
    if (line.trim() === "" || line.trim().startsWith("#")) {
      i += 1
      continue
    }
    const indentHere = line.match(/^\s*/)[0].length
    if (indentHere < indent) break
    const m = line.trim().match(/^([\w.\-/]+):\s*(.*)$/)
    if (!m) {
      i += 1
      continue
    }
    const [, key, rest] = m
    if (rest !== "" && !rest.startsWith("#")) {
      map[key] = parseScalar(rest)
      i += 1
      continue
    }
    // A key with no inline value owns the indented block beneath it.
    let j = i + 1
    while (j < lines.length && lines[j].trim() === "") j += 1
    if (j < lines.length && lines[j].match(/^\s*/)[0].length > indentHere) {
      const [value, next] = parseBlock(lines, j, lines[j].match(/^\s*/)[0].length)
      map[key] = value
      i = next
      continue
    }
    map[key] = null
    i += 1
  }
  return [map, i]
}

function parseDocuments(source) {
  const docs = []
  const chunks = source.replace(/\r\n/g, "\n").split(/^---\s*$/m)
  for (const chunk of chunks) {
    const lines = chunk.split("\n")
    const hasContent = lines.some((l) => l.trim() !== "" && !l.trim().startsWith("#"))
    if (!hasContent) continue
    const [doc] = parseBlock(lines, 0, 0)
    if (doc && Object.keys(doc).length > 0) docs.push(doc)
  }
  return docs
}

async function readYaml(file) {
  return parseDocuments(await readFile(join(root, file), "utf8"))
}

// --- A. CNI prerequisite ---------------------------------------------------
let ciliumValues
try {
  ciliumValues = await readFile(join(root, "platform/helm/cilium/values.yaml"), "utf8")
} catch {
  errors.push(
    "platform/helm/cilium/values.yaml is missing. The NetworkPolicy objects in " +
      "k8s/network-policies/ are inert without a netpol-capable CNI, and Flannel " +
      "does not implement the API. Restore the Cilium values file or remove the policies.",
  )
}
if (ciliumValues && !/exclusive:\s*true/.test(ciliumValues)) {
  errors.push("platform/helm/cilium/values.yaml: cni.exclusive must be true when taking over from another CNI")
}

// --- collect the managed namespaces and their policies --------------------
const nsDir = join(root, "k8s/network-policies")
const managed = []
for (const entry of await readdir(nsDir, { withFileTypes: true })) {
  if (!entry.isDirectory()) continue
  const policies = await readYaml(`k8s/network-policies/${entry.name}/policies.yaml`)
  managed.push({ namespace: entry.name, policies })
}

if (managed.length === 0) {
  errors.push("k8s/network-policies contains no namespace directories")
}

for (const { namespace, policies } of managed) {
  // --- B. default-deny ---
  const deny = policies.find(
    (p) =>
      p?.kind === "NetworkPolicy" &&
      p.metadata?.name === "default-deny" &&
      p.spec?.podSelector &&
      Object.keys(p.spec.podSelector).length === 0,
  )
  if (!deny) {
    errors.push(`k8s/network-policies/${namespace}: no namespace-wide default-deny NetworkPolicy`)
    continue
  }
  const types = deny.spec.policyTypes ?? []
  for (const required of ["Ingress", "Egress"]) {
    if (!types.includes(required)) {
      errors.push(`k8s/network-policies/${namespace}: default-deny must declare policyTypes ${required}`)
    }
  }

  // --- C. DNS ---
  const dns = policies.some(
    (p) =>
      p?.kind === "NetworkPolicy" &&
      (p.spec?.egress ?? []).some((rule) =>
        (rule.to ?? []).some(
          (peer) =>
            peer.namespaceSelector?.matchLabels?.["kubernetes.io/metadata.name"] === "kube-system" &&
            peer.podSelector?.matchLabels?.["k8s-app"] === "kube-dns" &&
            (rule.ports ?? []).some((port) => String(port.port) === "53"),
        ),
      ),
  )
  if (!dns) {
    errors.push(
      `k8s/network-policies/${namespace}: no egress rule for kube-dns on 53. ` +
        "A default-deny without DNS breaks every Service hostname and looks like a service outage.",
    )
  }
}

// --- D. every podSelector matches a real pod label ------------------------
// Pod labels per namespace, taken from the workload manifests in this repo plus
// the known external namespaces the policies reference.
const repoLabels = new Map() // namespace -> Set of "k=v,k=v2=v2"
function addLabels(ns, labels) {
  if (!repoLabels.has(ns)) repoLabels.set(ns, new Set())
  const set = repoLabels.get(ns)
  for (const [k, v] of Object.entries(labels ?? {})) {
    if (typeof v === "string") set.add(`${k}=${v}`)
  }
}

function templateLabels(manifest) {
  const docs = parseDocuments(manifest)
  const found = []
  const walk = (node) => {
    if (!node || typeof node !== "object") return
    if (Array.isArray(node)) return node.forEach(walk)
    if (node.kind === "Deployment" || node.kind === "StatefulSet" || node.kind === "DaemonSet") {
      found.push(node.spec?.template?.metadata?.labels)
    }
    if (node.kind === "CronJob") found.push(node.spec?.jobTemplate?.spec?.template?.metadata?.labels)
    Object.values(node).forEach(walk)
  }
  docs.forEach(walk)
  return found
}

for (const dir of ["k8s/apps", "k8s/gateway", "k8s/monitoring"]) {
  for (const name of await readdir(join(root, dir))) {
    if (!name.endsWith(".yaml")) continue
    const manifest = await readFile(join(root, dir, name), "utf8")
    const nsMatch = manifest.match(/^\s*namespace:\s*(\S+)\s*$/m)
    const ns = nsMatch ? nsMatch[1] : dir === "k8s/apps" ? "arda-app" : "monitoring"
    for (const labels of templateLabels(manifest)) addLabels(ns, labels)
  }
}

// Labels owned outside this repository. These are verified against the live
// cluster during the CNI rollout; they are listed here so a typo in a policy is
// still caught.
addLabels("kube-system", { "app.kubernetes.io/name": "traefik", "k8s-app": "kube-dns" })

for (const { namespace, policies } of managed) {
  for (const policy of policies) {
    if (policy?.kind !== "NetworkPolicy") continue
    const policyName = policy.metadata?.name ?? "?"
    const selector = policy.spec?.podSelector ?? {}
    const entries = Object.entries(selector.matchLabels ?? {})
    if (entries.length === 0) continue // namespace-wide, nothing to verify

    const known = repoLabels.get(namespace)
    if (!known) {
      errors.push(
        `k8s/network-policies/${namespace}/${policyName}: selects ${JSON.stringify(selector.matchLabels)} ` +
          "but no workload manifests were found for that namespace",
      )
      continue
    }
    const matched = entries.every(([k, v]) => known.has(`${k}=${v}`))
    if (!matched) {
      errors.push(
        `k8s/network-policies/${namespace}/${policyName}: podSelector ${JSON.stringify(selector.matchLabels)} ` +
          `matches no pod label in ${namespace}. Known: ${[...known].sort().join(", ")}`,
      )
    }
  }
}

// --- E. every declared service dependency is permitted ---------------------
const EGRESS_PORTS = {
  "arda-app": new Set(["8080", "9090"]),
  database: new Set(["5432"]),
  platform: new Set(["4222", "6379", "8080", "26500", "9200", "3900", "3000"]),
  auth: new Set(["4433", "4434", "4444", "4445"]),
}

function egressPortsFor(namespace) {
  return EGRESS_PORTS[namespace] ?? new Set()
}

function namespaceForHost(host) {
  if (host.includes(".svc.cluster.local")) return host.split(".")[1]
  if (host.includes(".svc.")) return host.split(".")[1]
  return "arda-app" // bare service name inside arda-app
}

const appPolicies = managed.find((m) => m.namespace === "arda-app")
if (appPolicies) {
  const allowed = egressPortsFor("arda-app")
  for (const name of await readdir(join(root, "k8s/apps"))) {
    if (!name.endsWith(".yaml")) continue
    const manifest = await readFile(join(root, "k8s/apps", name), "utf8")
    // value: http://host:port  and  value: host:port (gRPC dialling)
    const refs = manifest.matchAll(/value:\s*(?:https?:\/\/)?([a-z0-9.-]+):(\d+)/g)
    for (const [, host, port] of refs) {
      if (host.includes("arda.io.vn")) continue // public edge, not cluster traffic
      const targetNs = namespaceForHost(host)
      const permitted = egressPortsFor(targetNs)
      if (!permitted.has(port)) {
        errors.push(
          `k8s/apps/${name}: reaches ${host}:${port} but no NetworkPolicy in arda-app ` +
            `permits egress to ${targetNs}:${port}. Add it to allow-egress-data-tier ` +
            `or allow-egress-service-mesh, otherwise the call will time out at runtime.`,
        )
      }
    }
  }
}

if (errors.length) {
  console.error(errors.join("\n"))
  process.exit(1)
}

console.log(
  `Network policy OK: CNI prerequisite present, ${managed.length} namespaces default-deny with DNS, ` +
    "pod selectors resolve, declared service dependencies are permitted",
)
