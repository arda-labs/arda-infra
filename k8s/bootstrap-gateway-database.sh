#!/usr/bin/env bash
set -euo pipefail

# Creates the role and database for the AiGiare gateway (new-api) on the
# shared CloudNativePG cluster.
#
# Kept separate from k8s/bootstrap-app-databases.sh on purpose. That script
# gives every Arda service role the same APP_DATABASE_PASSWORD, which is fine
# because they are one product sharing one trust boundary. The gateway is a
# different product with a different blast radius — it is internet-facing and
# runs third-party code — so it gets its own credential, and losing the
# gateway database must not be reachable from an Arda service connection.
#
# The same Argo CD caveat applies: the pg-main Cluster is tracked by the
# arda-database Application with prune: true, so do not put the role or the
# database in a manifest under database/. Roles and databases live in the
# Postgres data volume and survive a prune, but a hand-made Secret in the
# database namespace does not.
#
# Usage:
#   GATEWAY_DATABASE_PASSWORD='<password>' bash k8s/bootstrap-gateway-database.sh
#
# Verify afterwards:
#   kubectl exec -n database pg-main-1 -- \
#     psql -U postgres -tc "SELECT rolname FROM pg_roles WHERE rolname='aigiare_gw'"

NAMESPACE="${DB_NAMESPACE:-database}"
HOST="${DB_HOST:-pg-main-rw.database.svc.cluster.local}"
ROLE="${GATEWAY_DATABASE_ROLE:-aigiare_gw}"
DATABASE="${GATEWAY_DATABASE_NAME:-aigiare_gw}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
GATEWAY_DATABASE_PASSWORD="${GATEWAY_DATABASE_PASSWORD:-}"

if [ -z "$GATEWAY_DATABASE_PASSWORD" ]; then
  echo "Missing GATEWAY_DATABASE_PASSWORD. Refusing to create a role with an empty password." >&2
  exit 1
fi

if [ -z "$POSTGRES_PASSWORD" ]; then
  POSTGRES_PASSWORD="$(kubectl get secret pg-main-superuser -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
fi

if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "Missing postgres password. Set POSTGRES_PASSWORD or wait for secret $NAMESPACE/pg-main-superuser." >&2
  exit 1
fi

kubectl run aigiare-gateway-db-bootstrap --rm -i --restart=Never \
  --image postgres:18-alpine \
  --namespace "$NAMESPACE" \
  --env="DB_HOST=$HOST" \
  --env="PGPASSWORD=$POSTGRES_PASSWORD" \
  --env="GATEWAY_ROLE=$ROLE" \
  --env="GATEWAY_DATABASE=$DATABASE" \
  --env="GATEWAY_DATABASE_PASSWORD=$GATEWAY_DATABASE_PASSWORD" \
  --command -- sh -s <<'EOF'
set -eu
# LOGIN only, never SUPERUSER and never CREATEDB. new-api runs GORM
# AutoMigrate on every boot, so the role needs to create and alter tables in
# its own database — and nothing beyond that. An empty privileges clause keeps
# the role out of pg_hba.conf's trust path and out of the cluster's ability to
# hand out extensions.
psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 \
  -v role="$GATEWAY_ROLE" \
  -v role_password="$GATEWAY_DATABASE_PASSWORD" <<'SQL'
DO $do$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') THEN
    EXECUTE format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'role', :'role_password');
  ELSE
    EXECUTE format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'role', :'role_password');
  END IF;
END
$do$;
SQL

psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 \
  -tc "SELECT 1 FROM pg_database WHERE datname = '$GATEWAY_DATABASE'" | grep -q 1 || \
  psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE $GATEWAY_DATABASE OWNER $GATEWAY_ROLE;"

# revoking CONNECT from PUBLIC and granting it only to the owning role keeps a
# leaked password from being the only thing protecting this database: another
# role in the cluster still could not open a connection.
psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 \
  -c "REVOKE ALL ON DATABASE $GATEWAY_DATABASE FROM PUBLIC;"

echo "gateway database ready: role=$GATEWAY_ROLE database=$GATEWAY_DATABASE"
EOF
