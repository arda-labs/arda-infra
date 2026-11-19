import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { readFile } from "node:fs/promises"

const execFileAsync = promisify(execFile)
const { stdout } = await execFileAsync("git", ["ls-files", "-z"], { encoding: "utf8" })
const files = stdout.split("\0").filter(Boolean)
const findings = []
const forbidden = [
  /\badmin123\b/i,
  /\b123456\b/,
  new RegExp(["fixed", "key"].join("-"), "i"),
  new RegExp(["test", "test"].join(":"), "i"),
]
const credentialedUrl = /(?:postgres(?:ql)?|redis):\/\/[^\s"'`<>$]+:[^\s"'`<>$@]+@/i
// A plain `kind: Secret` carrying data may only be a placeholder example.
// Real secrets are committed as SealedSecrets (docs/secret-management.md).
const isExample = (file) =>
  file.startsWith("platform/secrets/examples/") || /\.example\.ya?ml$/.test(file)
const isYaml = (file) => /\.ya?ml$/.test(file)
const plainSecretWithData = (doc) =>
  /^kind:\s*Secret\s*$/m.test(doc) && /^(data|stringData):/m.test(doc)
const sealedSecretAge = (doc) =>
  /^kind:\s*SealedSecret\s*$/m.test(doc) && !/^\s+encryptedData:/m.test(doc)

for (const file of files) {
  if (file.endsWith(".lock") || file.includes("node_modules/")) continue
  let content
  try {
    content = await readFile(file, "utf8")
  } catch (error) {
    if (error.code === "ENOENT") continue
    throw error
  }
  for (const pattern of forbidden) {
    if (pattern.test(content)) findings.push(`${file}: forbidden credential pattern ${pattern}`)
  }
  if (credentialedUrl.test(content)) findings.push(`${file}: credentialed database/cache URL must come from a secret reference`)
  if (isYaml(file) && !isExample(file)) {
    for (const doc of content.split(/^---\s*$/m)) {
      if (plainSecretWithData(doc)) {
        findings.push(`${file}: plain Secret with data; commit a SealedSecret instead (platform/bootstrap/seal-secret.sh)`)
      }
      if (sealedSecretAge(doc)) {
        findings.push(`${file}: SealedSecret without encryptedData`)
      }
    }
  }
}

if (findings.length) {
  console.error(findings.join("\n"))
  process.exit(1)
}
console.log(`Secret hygiene OK: scanned ${files.length} tracked files`)
