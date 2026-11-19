# Backup và khôi phục PostgreSQL (pg-main)

Issue: HOA-5. Bối cảnh: ngày 2026-10-07 mất toàn bộ dữ liệu khi xoá VM Proxmox
vì không có backup ([thinkcenter-recovery-2026-10-07.md](thinkcenter-recovery-2026-10-07.md)).

## Thiết kế

| Thành phần | Giá trị |
|---|---|
| Công cụ | CloudNativePG 1.30 + Barman Cloud plugin (`cnpg-system/barman-cloud`) |
| Nơi lưu | Cloudflare R2, bucket `arda-pg-backups`, prefix `pg-main` — **ngoài** cụm k3s/Proxmox |
| WAL | Lưu trữ liên tục (`isWALArchiver: true`) → khôi phục được tới thời điểm bất kỳ |
| Base backup | Hằng ngày 19:00 UTC (02:00 giờ VN), lần đầu chạy ngay khi tạo (`immediate`) |
| Giữ lại | 30 ngày (`retentionPolicy: 30d`) |
| Manifest | `database/backup-objectstore.yaml`, `database/backup-schedule.yaml`, `database/pg-main.yaml` (`plugins`), `k8s/network-policies/database/policies.yaml` (`allow-backup-egress-r2`) |

Không dùng Garage: Garage chạy trong cùng cụm nên mất cùng lúc với VM.

## 1. Chuẩn bị — làm TRƯỚC khi merge

Argo CD (`arda-database`) tự đồng bộ `database/` khi merge vào `main`. Nếu bật
lưu WAL khi chưa có bucket hoặc Secret, việc lưu WAL lỗi liên tục và WAL dồn
lên ổ 10Gi cho tới khi Postgres dừng. Làm đúng thứ tự:

1. **Tạo bucket R2** `arda-pg-backups` trong tài khoản Cloudflare có endpoint
   ghi ở `backup-objectstore.yaml` (đang dùng cùng tài khoản với backup của
   puchi; nếu dùng tài khoản khác thì sửa `endpointURL`).
   - Khuyến nghị: bật **Bucket lock rule** (giữ object tối thiểu 30 ngày) để
     xoá nhầm hay bị chiếm token cũng không xoá được backup.
2. **Tạo R2 API token** chỉ có quyền *Object Read & Write* trên đúng bucket này.
3. **Tạo Secret** trong namespace `database` (mẫu:
   `platform/secrets/examples/r2-pg-backup-secret.yaml`):

   ```bash
   kubectl -n database create secret generic r2-pg-backup \
     --from-literal=R2_ACCESS_KEY_ID='<access key id>' \
     --from-literal=R2_SECRET_ACCESS_KEY='<secret access key>'
   ```

   Khi HOA-6 (SOPS/SealedSecrets) xong, chuyển Secret này vào git dạng mã hoá.
4. Merge PR. `arda-backend` đồng bộ NetworkPolicy, `arda-database` đồng bộ
   ObjectStore, ScheduledBackup và `plugins` của `pg-main`. CNPG khởi động lại
   lần lượt các instance để gắn sidecar Barman Cloud.

## 2. Kiểm tra sau khi bật

```bash
# Lưu WAL đang chạy: điều kiện ContinuousArchiving phải là True
kubectl -n database get cluster pg-main \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'

# Base backup đầu tiên (immediate) phải completed
kubectl -n database get backups

# Cửa sổ khôi phục
kubectl -n database get objectstore pg-main-r2 \
  -o jsonpath='{.status.serverRecoveryWindow}{"\n"}'

# Theo dõi WAL dồn ứ (nên gần 0 sau vài phút)
kubectl -n database exec pg-main-1 -c postgres -- \
  psql -tAc "select archived_count, failed_count, last_failed_wal, last_failed_time from pg_stat_archiver"
```

Nếu `failed_count` tăng: xem log sidecar
`kubectl -n database logs pg-main-1 -c plugin-barman-cloud`, kiểm tra Secret,
bucket và NetworkPolicy `allow-backup-egress-r2`.

**Kiểm tra hằng ngày** (đến khi có cảnh báo tự động):
`lastSuccessfulBackupTime` trong `status.serverRecoveryWindow` không cũ hơn 26 giờ.

## 3. Diễn tập khôi phục (bắt buộc — làm sau lần bật đầu và hằng tháng)

Khôi phục sang cụm tạm `pg-restore-test` (cùng namespace để dùng sẵn
NetworkPolicy). Manifest `database/restore-drill/pg-restore-test.yaml` không
nằm trong kustomization, Argo CD không đụng tới.

```bash
start=$(date -u +%s)
kubectl apply -f database/restore-drill/pg-restore-test.yaml
kubectl -n database wait cluster/pg-restore-test --for=condition=Ready --timeout=60m
end=$(date -u +%s); echo "RTO: $(( (end-start)/60 )) phút"
```

So sánh với `pg-main`:

```bash
q="select datname, pg_database_size(datname) from pg_database where not datistemplate order by 1"
kubectl -n database exec pg-main-1 -c postgres -- psql -tAc "$q"
kubectl -n database exec pg-restore-test-1 -c postgres -- psql -tAc "$q"

# Ví dụ kiểm tra dữ liệu nghiệp vụ: số bút toán và thời điểm bút toán mới nhất
for p in pg-main-1 pg-restore-test-1; do
  kubectl -n database exec $p -c postgres -- psql -d finance -tAc \
    "select count(*), max(created_at) from fin_journal_entries"
done
```

RPO thực tế = thời điểm bản ghi mới nhất trên `pg-main` − thời điểm bản ghi mới
nhất trên `pg-restore-test` (với WAL liên tục, kỳ vọng vài phút).

Ghi kết quả vào bảng dưới, rồi xoá cụm tạm:

```bash
kubectl delete -f database/restore-drill/pg-restore-test.yaml
```

Khôi phục về một thời điểm: bỏ comment `recoveryTarget.targetTime` trong
manifest diễn tập.

| Ngày | Người làm | Backup dùng | RTO | RPO | Ghi chú |
|---|---|---|---|---|---|
| _chưa diễn tập_ | | | | | |

## 4. Khôi phục thật (mất pg-main)

1. Dừng ghi: scale các deployment trong `arda-app` về 0.
2. Nếu cụm k3s còn: tạo cụm mới theo mẫu diễn tập, đổi tên thành `pg-main`
   chỉ sau khi đã xoá cụm hỏng, và **giữ `externalClusters` trỏ `serverName: pg-main`**.
   Sau khi cụm mới chạy ổn, bật lại `plugins` với **`serverName` mới** (ví dụ
   `pg-main-v2`) để không ghi đè dòng WAL cũ.
3. Nếu mất cả cụm: dựng lại k3s + CNPG + plugin Barman Cloud + cert-manager,
   tạo lại Secret `r2-pg-backup`, rồi làm như bước 2.
4. Đổi lại mật khẩu các role ứng dụng nếu nghi bị lộ, bật lại ứng dụng.

## Việc tiếp theo

- Cảnh báo tự động khi backup cũ hơn 26 giờ hoặc `pg_stat_archiver.failed_count` tăng (VictoriaMetrics/Gatus).
- Đưa Secret `r2-pg-backup` vào git dạng mã hoá (HOA-6).
