# Quản lý secret (Sealed Secrets)

Issue: HOA-6. Mục tiêu: dựng lại cụm từ Git mà không phải tạo secret bằng tay.

## Vì sao Sealed Secrets

- Secret được mã hoá bằng khoá công khai của controller rồi commit vào Git dưới
  dạng `SealedSecret`. Chỉ controller trong cụm có khoá riêng để giải mã.
- Argo CD đồng bộ `SealedSecret` như mọi manifest khác. **Không phải sửa
  `argocd-repo-server`** (SOPS + KSOPS thì phải, mà Argo CD đang được cài ngoài
  repo này nên sửa sẽ tạo lệch cấu hình).
- Triển khai nhiều site sau này (GĐ5): mỗi cụm có controller và khoá riêng;
  seal cho site nào thì dùng chứng chỉ của site đó (`kubeseal --cert`).

Đánh đổi: khoá riêng của controller là thứ duy nhất Git không dựng lại được —
**phải backup ra ngoài cụm** (§2).

| Thành phần | Vị trí |
|---|---|
| Controller | Argo Application `sealed-secrets` (chart 2.22.0, controller v0.41.2), `kube-system/sealed-secrets-controller`, project `platform` |
| Manifest đã mã hoá | `secrets/<namespace>/<tên>.sealed.yaml` |
| Seal một secret đang chạy | `platform/bootstrap/seal-secret.sh <namespace> <tên>` |
| Backup khoá | `platform/bootstrap/backup-sealing-key.sh` |
| Chặn commit secret thô | `scripts/check-secret-hygiene.mjs` (CI) |

## 1. Cài controller

Ứng dụng trong `argocd/apps` được áp dụng bằng tay:

```bash
kubectl apply -k argocd
kubectl -n kube-system rollout status deploy/sealed-secrets-controller
```

Cài CLI `kubeseal` **v0.41.2** (cùng phiên bản controller) và `age` trên máy quản trị.

## 2. Backup khoá — làm ngay sau khi cài, rồi hằng tháng

Controller tự sinh khoá mới mỗi 30 ngày và giữ khoá cũ. Thiếu khoá ⇒ mọi
`*.sealed.yaml` trong Git thành vô dụng khi mất cụm (như sự cố 2026-10-07).

```bash
BACKUP_AGE_RECIPIENT=age1...  platform/bootstrap/backup-sealing-key.sh ./out
```

Lưu file `.age` ở **hai nơi ngoài cụm**: trình quản lý mật khẩu và bucket R2
`arda-pg-backups` (prefix `sealed-secrets-keys/`). Khoá riêng age để giải mã
backup giữ trong trình quản lý mật khẩu, không để trên máy chủ nào của cụm.
Không commit file `.age`.

## 3. Chuyển một secret sang Git

```bash
platform/bootstrap/seal-secret.sh arda-app arda-app-secrets
git add secrets/arda-app/arda-app-secrets.sealed.yaml
```

Script đọc secret đang chạy, mã hoá qua pipe (không ghi bản rõ ra đĩa), ghi
`secrets/<ns>/<tên>.sealed.yaml`, và gắn annotation
`sealedsecrets.bitnami.com/managed=true` để controller được tiếp quản secret có
sẵn. Script từ chối seal secret do controller khác sinh ra (CNPG, Argo CD,
service-account token, Helm release).

Sau khi đã có file đầu tiên cho một namespace, thêm `secrets/<ns>/kustomization.yaml`
và một Argo Application (hoặc đưa vào kustomization sẵn có của namespace đó).
Namespace ngoài project `arda` (`platform`, `auth`, `argocd`) cần mở thêm
destination cho project tương ứng.

Đổi giá trị (xoay vòng): tạo lại secret đang chạy bằng `kubectl create secret
... --dry-run=client -o yaml | kubectl apply -f -`, chạy lại `seal-secret.sh`,
commit. Hoặc seal trực tiếp từ đầu vào mà không đụng cụm:
`kubectl create secret ... --dry-run=client -o yaml | kubeseal --format yaml > secrets/<ns>/<tên>.sealed.yaml`.

## 4. Kiểm kê secret (2026-11-19)

Đọc từ cụm, chỉ tên và loại, không đọc giá trị.

### Cần chuyển sang Git (do người tạo)

| Namespace | Secret | Nguồn hiện tại | Ưu tiên | Xoay vòng khi chuyển |
|---|---|---|---|---|
| arda-app | `arda-app-secrets` | `argocd/README.md` (tay) | 1 | Có: `ARDA_SERVICE_AUTH_SECRET`, mật khẩu DB trong DSN |
| arda-app | `iam-service-secrets` | `arda-be/docs/ghcr-k3s-deployment.md` | 1 | Có |
| arda-app | `arda-grpc-tls-*` (13) | runbook mTLS của arda-be | 1 | Cấp lại CA + chứng chỉ |
| arda-app, argocd | `ghcr-pull` | `argocd/README.md` | 2 | Có (PAT) |
| database | `r2-pg-backup` | HOA-5 runbook | 1 | Không (mới tạo) |
| platform | `valkey-auth`, `garage-admin-secret`, `garage-webui-secret` | `create-secrets.sh`, `install-garage.sh` | 2 | Có |
| platform | `garage-s3` | `init-garage.sh` | 2 | Có |
| platform | `cloudflared-token` | tay | 2 | Có |
| monitoring | `grafana-admin` (và `telegram-alerts` khi tạo) | tay | 3 | Có |
| argocd | `arda-github-repo-creds`, `argocd-image-updater-secret`, `argocd-notifications-secret` | `argocd/README.md` | 3 | Có |
| auth | `hydra`, `kratos` | `auth/setup.sh` truyền `--set-string` vào Helm | 2 | Đổi chart sang `existingSecret` trước, rồi seal |

### Không chuyển (do controller khác sinh)

`pg-main-*` (CNPG), `cilium-ca`, `hubble-*` (Cilium), `argocd-secret`,
`argocd-redis`, `argocd-initial-admin-secret` (Argo CD), `cloud-agent-readonly-token`
(service-account token), `nats-box-contexts` (chart NATS), `garage-rpc-secret`
(kiểm tra lại nguồn trước khi quyết).

Không thuộc Arda (để chủ dự án đó tự quyết): `repo-game-hub`,
`repo-hoanit-guard`, `repo-puchi-gitops`.

## 5. Dựng lại cụm từ Git

1. Dựng k3s, Cilium, Argo CD.
2. **Khôi phục khoá Sealed Secrets trước khi cài controller:**

   ```bash
   age -d -i <age-identity> sealed-secrets-keys-<ngày>.yaml.age | kubectl apply -f -
   ```

3. `kubectl apply -k argocd` → controller khởi động, nhận khoá đã khôi phục,
   giải mã mọi `SealedSecret` mà Argo CD đồng bộ.
4. Khôi phục Postgres theo `docs/postgres-backup-restore.md` §4.

Nếu mất khoá: mọi secret phải tạo lại bằng tay và seal lại — đúng tình huống
issue này muốn loại bỏ.

## Việc tiếp theo

- Chuyển theo thứ tự ưu tiên ở §4, mỗi namespace một PR; xoay vòng giá trị khi chuyển.
- Đổi `auth/setup.sh` để Hydra/Kratos đọc từ Secret có sẵn thay vì `--set-string`.
- Cảnh báo khi controller sinh khoá mới mà chưa có bản backup tương ứng.
