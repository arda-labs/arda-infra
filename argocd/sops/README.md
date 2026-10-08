# SOPS with age and KSOPS

The `platform-secrets` Argo CD Application uses the `sops-ksops` Config
Management Plugin to decrypt SOPS-encrypted Kubernetes resources during
manifest generation. The plugin runs as a separate repo-server sidecar; the
global Kustomize build options remain unchanged.

## Key handling

- Keep the age private identity outside Git, in the operator's protected
  `SOPS_AGE_KEY_FILE`, and maintain an offline recovery copy.
- Create the Argo CD key Secret from that file without printing its contents:

  ```powershell
  kubectl -n argocd create secret generic argocd-sops-age `
    --from-file=keys.txt=$env:APPDATA\sops\age\arda-age-key.txt `
    --dry-run=client -o yaml | kubectl apply -f -
  ```

- The public recipient is recorded in the repository `.sops.yaml`. It is safe
  to share; the corresponding private identity is not.

## Enable the Argo CD plugin

The Argo CD installation is currently installed outside this repository's
Applications. Apply the tracked plugin ConfigMap and strategic patch as a
one-time Argo CD installation change:

```powershell
kubectl apply -k argocd/sops
kubectl -n argocd patch deployment argocd-repo-server `
  --type=strategic --patch-file argocd/sops/repo-server-patch.yaml
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=5m
```

The patch adds a pinned KSOPS init container and an Argo CD v3.5.4 CMP sidecar,
mounts the age key read-only, and keeps the sidecar's temporary directory
separate from repo-server's `/tmp`. Revisit the image version when Argo CD is
upgraded. After the task branch has been reviewed and merged, register the
`platform-secrets` Application with `kubectl apply -k argocd`, then verify its
sync in Argo CD. Do not add `--enable-exec` to global `argocd-cm` build options.

## Encrypt and render

Encrypt a Kubernetes Secret manifest in place with SOPS using the checked-in
`.sops.yaml` recipient. Only its `data`/`stringData` values are encrypted; the
resource identity remains readable for review. Put the encrypted manifest in
`platform/secrets/sops/` and include it in `ksops-generator.yaml`.

To migrate an existing cluster Secret without writing its plaintext to disk or
the terminal, use the helper from the repository root:

```powershell
$env:SOPS_AGE_KEY_FILE = "$env:APPDATA\sops\age\arda-age-key.txt"
$env:PATH = "$(go env GOPATH)\bin;$env:PATH" # when SOPS was installed with Go
.\scripts\encrypt-cluster-secret.ps1 `
  -Namespace platform -Name valkey-auth `
  -OutputPath platform/secrets/sops/valkey-auth.enc.yaml
Remove-Item Env:\SOPS_AGE_KEY_FILE
```

For local rendering, install compatible `sops`, `age`, and `ksops` binaries,
put `kustomize` and `ksops` on `PATH`, and set `SOPS_AGE_KEY_FILE` to the
private identity. Then run:

```powershell
kustomize build --enable-alpha-plugins --enable-exec platform/secrets/sops
```

Argo CD discovers this path because it contains `ksops-generator.yaml` and
uses the CMP only for Applications that opt in with `plugin: {}`. The encrypted
Valkey Secret in this directory is the first managed secret; other
cluster-local credentials remain out of Git until migrated one at a time.
