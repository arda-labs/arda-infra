# Recovery

Nếu mất namespace `platform`:

```bash
kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f -
bash bootstrap/setup-permissions.sh
./bootstrap/install-all.sh
./bootstrap/init-garage.sh
./bootstrap/status.sh
```

Nếu dùng Cloudflared, tạo secret trước:

```bash
cp secrets/examples/cloudflared-token-secret.yaml secrets/generated/cloudflared-token-secret.yaml
vi secrets/generated/cloudflared-token-secret.yaml
kubectl apply -f secrets/generated/cloudflared-token-secret.yaml
```
