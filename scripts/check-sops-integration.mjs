import { readFile } from "node:fs/promises"

const files = new Map(
  await Promise.all(
    [
      ".sops.yaml",
      "platform/secrets/sops/valkey-auth.enc.yaml",
      "platform/secrets/sops/ksops-generator.yaml",
      "argocd/sops/plugin-config.yaml",
      "argocd/sops/repo-server-patch.yaml",
      "argocd/apps/platform-secrets.yaml",
    ].map(async (path) => [path, await readFile(path, "utf8")]),
  ),
)

const failures = []
const assert = (condition, message) => {
  if (!condition) failures.push(message)
}

const sopsConfig = files.get(".sops.yaml")
const encryptedSecret = files.get("platform/secrets/sops/valkey-auth.enc.yaml")
const generator = files.get("platform/secrets/sops/ksops-generator.yaml")
const plugin = files.get("argocd/sops/plugin-config.yaml")
const patch = files.get("argocd/sops/repo-server-patch.yaml")
const application = files.get("argocd/apps/platform-secrets.yaml")

assert(/age:\s*age1[0-9a-z]+/.test(sopsConfig), ".sops.yaml must use a public age recipient")
assert(!/AGE-SECRET-KEY|age-secret-key-1/i.test(sopsConfig), ".sops.yaml must not contain a private age identity")
assert(/ENC\[AES256_GCM,/.test(encryptedSecret), "the managed Secret must store encrypted values")
assert(/name:\s*valkey-auth/.test(encryptedSecret), "the encrypted Secret identity must remain reviewable")
assert(/valkey-auth\.enc\.yaml/.test(generator), "KSOPS must load the encrypted Secret")
assert(/kustomize build --enable-alpha-plugins --enable-exec/.test(plugin), "CMP must enable KSOPS only in its sidecar")
assert(/ksops-generator\.yaml/.test(plugin), "CMP discovery must be scoped to KSOPS Applications")
assert(/argocd-cmp-server/.test(patch), "repo-server patch must register the CMP sidecar")
assert(/SOPS_AGE_KEY_FILE/.test(patch) && /readOnly:\s*true/.test(patch), "the sidecar must mount the age identity read-only")
assert(/argocd-sops-age/.test(patch), "the sidecar must read the age identity from its named Secret")
assert(/path:\s*platform\/secrets\/sops/.test(application), "the SOPS Application must target the encrypted resource path")
assert(/plugin:\s*\{\}/.test(application), "the SOPS Application must opt in to CMP discovery")

if (failures.length) {
  console.error(failures.join("\n"))
  process.exit(1)
}

console.log("SOPS integration OK: encrypted resource, public recipient, scoped CMP, and read-only key mount")
