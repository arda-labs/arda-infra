# ARDA Platform

Bootstrap for shared runtime components in namespace `platform`.

Hydra/Kratos are intentionally kept in `../auth` and namespace `auth`.

## Components

```text
platform            auth (separate namespace, see ../auth)
├── nats            ├── hydra
├── valkey          └── kratos
├── garage
├── cloudflared
└── zeebe 8.5
```

## Quick Setup

```bash
cd arda-infra/platform
bash bootstrap/setup-permissions.sh
./bootstrap/install-all.sh
```

## Config

Edit:

```bash
config/platform.env
```

Defaults (`config/platform.env`):

```env
INSTALL_NATS=true
INSTALL_VALKEY=true
INSTALL_GARAGE=true
INSTALL_CLOUDFLARED=true
INSTALL_ZEEBE=true
```

## Check

```bash
./bootstrap/status.sh
```

## Backup

```bash
./bootstrap/backup.sh
```

## Garage Init

After Garage pods are ready:

```bash
./bootstrap/init-garage.sh
```

The script creates layout, bucket `media`, S3 key, and secret `garage-s3`.

## Zeebe

Zeebe uses Camunda Platform chart 10.11.3 / Zeebe 8.5.x:

```env
INSTALL_ZEEBE=true
ZEEBE_CHART_VERSION=10.11.3
```
Run:

```bash
./bootstrap/install-zeebe.sh
```

## Operations

Upgrade a Helm component by re-running its install script. Back up first:

```bash
./bootstrap/backup.sh
./bootstrap/install-nats.sh     # or install-valkey.sh / install-garage.sh
```

Recover a lost `platform` namespace:

```bash
kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f -
bash bootstrap/setup-permissions.sh
./bootstrap/install-all.sh
./bootstrap/init-garage.sh
./bootstrap/status.sh
```

Cloudflared needs its secret restored before install:

```bash
cp secrets/examples/cloudflared-token-secret.yaml secrets/generated/cloudflared-token-secret.yaml
vi secrets/generated/cloudflared-token-secret.yaml
kubectl apply -f secrets/generated/cloudflared-token-secret.yaml
```

## Safety

Do not run broad deletes such as:

```bash
kubectl delete -f .
kubectl delete -f <large-folder>
```

Use component scripts instead, for example:

```bash
./bootstrap/clean-zeebe.sh
```
