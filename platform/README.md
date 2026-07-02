# ARDA Platform

Bootstrap for shared runtime components in namespace `platform`.

Hydra/Kratos are intentionally kept in `../auth` and namespace `auth`.

## Components

- NATS
- Valkey
- Garage
- Cloudflared, disabled by default
- Zeebe, disabled by default

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

Defaults:

```env
INSTALL_NATS=true
INSTALL_VALKEY=true
INSTALL_GARAGE=true
INSTALL_CLOUDFLARED=false
INSTALL_ZEEBE=false
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

Zeebe is present but disabled by default:

```env
INSTALL_ZEEBE=false
```

To test it:

```env
INSTALL_ZEEBE=true
```

Then run:

```bash
./bootstrap/install-zeebe.sh
```

Camunda Platform chart 10.x may require secondary storage. If that happens,
disable Zeebe here and split it into a pinned chart/values setup later.

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
