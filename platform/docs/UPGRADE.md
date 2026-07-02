# Upgrade

Các component dùng Helm nên upgrade bằng script install tương ứng:

```bash
./bootstrap/install-nats.sh
./bootstrap/install-valkey.sh
./bootstrap/install-garage.sh
```

Trước khi upgrade:

```bash
./bootstrap/backup.sh
```
