import { readFile } from "node:fs/promises"

const files = [
  "platform/bootstrap/backup.sh",
  "platform/bootstrap/restore.sh",
  "platform/bootstrap/preflight.sh",
  "platform/bootstrap/verify-runtime-secrets.sh",
]

const sources = new Map()
for (const file of files) sources.set(file, await readFile(file, "utf8"))

for (const [file, source] of sources) {
  if (!source.startsWith("#!/usr/bin/env bash\nset -euo pipefail")) {
    throw new Error(`${file}: must fail closed with set -euo pipefail`)
  }
}

const backup = sources.get(files[0])
for (const required of ["BACKUP_INCLUDE_SECRETS", "BACKUP_AGE_RECIPIENT", "SHA256SUMS", "backup-metadata.env"]) {
  if (!backup.includes(required)) throw new Error(`backup.sh: missing ${required}`)
}
if (/kubectl\s+get\s+secret[^\n]*>\s*.*\.ya?ml(\s|$)/i.test(backup)) {
  throw new Error("backup.sh: plaintext Secret snapshot is forbidden")
}

const restore = sources.get(files[1])
for (const required of ["--source", "sha256sum -c SHA256SUMS", 'TARGET_NAMESPACE" = "platform']) {
  if (!restore.includes(required)) throw new Error(`restore.sh: missing fail-closed guard ${required}`)
}
if (/kubectl\s+apply|helm\s+(install|upgrade)/i.test(restore)) {
  throw new Error("restore.sh: automatic apply is not allowed in the verification-only runbook")
}

const secrets = sources.get(files[3])
for (const required of ["HRM_DATABASE_DSN", "ARDA_SERVICE_AUTH_SECRET", 'for service in crm iam platform workflow hrm finance media notification', 'secret="arda-grpc-tls-$service"']) {
  if (!secrets.includes(required)) throw new Error(`verify-runtime-secrets.sh: missing ${required}`)
}

const notificationManifest = await readFile("k8s/apps/notification-service.yaml", "utf8")
if (/key: NATS_URL\s+optional: true/.test(notificationManifest)) {
  throw new Error("notification-service.yaml: runtime NATS_URL must be required")
}
if (!notificationManifest.includes("key: NATS_URL")) {
  throw new Error("notification-service.yaml: NATS_URL reference is missing")
}

console.log("Operational gate scripts OK: backup, restore, preflight and runtime secret checks")
