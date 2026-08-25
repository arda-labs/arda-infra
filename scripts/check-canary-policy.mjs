import { readFile } from "node:fs/promises"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

const root = fileURLToPath(new URL("..", import.meta.url))
const path = join(root, "platform", "policy", "canary-policy-v1.json")
const policy = JSON.parse(await readFile(path, "utf8"))
const errors = []

if (policy.version !== 1) errors.push("version must be 1")
if (policy.rollout?.max_canary_replicas !== 1) errors.push("canary must start with exactly one replica")
if (policy.rollout?.image_ref !== "immutable-digest-or-commit-sha") errors.push("canary must use immutable image references")
if (policy.rollout?.schema_mode !== "expand-contract") errors.push("schema mode must be expand-contract")
if (policy.rollout?.commands !== "no-duplicate-non-idempotent-replay") errors.push("non-idempotent commands must not be duplicated")
if (!Number.isInteger(policy.observation?.minimum_minutes) || policy.observation.minimum_minutes < 15) errors.push("minimum observation must be at least 15 minutes")
for (const field of ["status_code", "error_rate", "p50_ms", "p95_ms", "p99_ms", "business_reconciliation"]) {
  if (!policy.observation?.comparison?.includes(field)) errors.push(`observation comparison missing ${field}`)
}
for (const field of ["5xx_rate_percent", "p95_regression_percent", "policy_denial_regression_percent", "db_lock_wait_ms", "event_redelivery_regression_percent"]) {
  if (!Number.isFinite(policy.halt_thresholds?.[field]) || policy.halt_thresholds[field] <= 0) errors.push(`halt threshold missing ${field}`)
}
if (policy.rollback?.preserve_schema_compatibility !== true) errors.push("rollback must preserve schema compatibility")
for (const field of ["old_image", "new_image", "manifest_revision", "start", "end", "decision", "operator"]) {
  if (!policy.rollback?.record?.includes(field)) errors.push(`rollback record missing ${field}`)
}

if (errors.length) {
  console.error(errors.join("\n"))
  process.exit(1)
}

console.log("Canary policy OK: immutable one-replica rollout with halt and recovery thresholds")
