#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${AUTH_NAMESPACE:-auth}"
DB_NAMESPACE="${DB_NAMESPACE:-database}"
DB_HOST="${DB_HOST:-pg-main-rw.database.svc.cluster.local}"
HYDRA_RELEASE="${HYDRA_RELEASE:-hydra}"
KRATOS_RELEASE="${KRATOS_RELEASE:-kratos}"
ORY_REPO_NAME="${ORY_REPO_NAME:-ory}"
ORY_REPO_URL="${ORY_REPO_URL:-https://k8s.ory.sh/helm/charts}"

SUPERADMIN_EMAIL="${SUPERADMIN_EMAIL:-superadmin@arda.local}"
SUPERADMIN_PASSWORD="${SUPERADMIN_INITIAL_PASSWORD:-${SUPERADMIN_PASSWORD:-}}"
DEV_ADMIN_EMAIL="${DEV_ADMIN_EMAIL:-admin@arda.local}"

cd "$(dirname "$0")"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing command: $1"
    exit 1
  }
}

require_cmd kubectl
require_cmd helm

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

helm repo add "$ORY_REPO_NAME" "$ORY_REPO_URL" >/dev/null 2>&1 || true
helm repo update

postgres_password() {
  if [ -n "${POSTGRES_PASSWORD:-}" ]; then
    echo "$POSTGRES_PASSWORD"
    return 0
  fi

  kubectl get secret pg-main-superuser -n "$DB_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true
}

reset_databases() {
  echo "=== Reset Ory databases ==="
  : "${HYDRA_DATABASE_PASSWORD:?Set HYDRA_DATABASE_PASSWORD for reset-db}"
  : "${KRATOS_DATABASE_PASSWORD:?Set KRATOS_DATABASE_PASSWORD for reset-db}"
  local pg_password
  pg_password="$(postgres_password)"
  if [ -z "$pg_password" ]; then
    echo "Missing postgres password. Set POSTGRES_PASSWORD or wait for secret $DB_NAMESPACE/pg-main-superuser."
    return 1
  fi

  kubectl run psql-client --rm -i --restart=Never \
    --image postgres:16-alpine \
    --namespace "$NAMESPACE" \
    --env="PGPASSWORD=$pg_password" \
    --env="DB_HOST=$DB_HOST" \
    --env="HYDRA_DATABASE_PASSWORD=$HYDRA_DATABASE_PASSWORD" \
    --env="KRATOS_DATABASE_PASSWORD=$KRATOS_DATABASE_PASSWORD" \
    --command -- sh -c '
      psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 -v hydra_password="$HYDRA_DATABASE_PASSWORD" \
        -c "DO \$do\$ BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname = \$q\$arda_hydra\$q\$) THEN EXECUTE format('ALTER ROLE %I PASSWORD %L', 'arda_hydra', :'hydra_password'); ELSE EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', 'arda_hydra', :'hydra_password'); END IF; END \$do\$;"
      psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 -v kratos_password="$KRATOS_DATABASE_PASSWORD" \
        -c "DO \$do\$ BEGIN IF EXISTS (SELECT FROM pg_roles WHERE rolname = \$q\$arda_kratos\$q\$) THEN EXECUTE format('ALTER ROLE %I PASSWORD %L', 'arda_kratos', :'kratos_password'); ELSE EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', 'arda_kratos', :'kratos_password'); END IF; END \$do\$;"
      psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN (\$q\$hydra\$q\$, \$q\$kratos\$q\$) AND pid <> pg_backend_pid();"
      psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 \
        -c "DROP DATABASE IF EXISTS hydra;"
      psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 \
        -c "DROP DATABASE IF EXISTS kratos;"
      psql -h "$DB_HOST" -U postgres -v ON_ERROR_STOP=1 \
        -c "CREATE DATABASE hydra OWNER arda_hydra;"
      psql -h "$DB_HOST" -U postgres \
        -c "CREATE DATABASE kratos OWNER arda_kratos;"
      echo "Ory databases reset done."
    '
}

deploy_hydra() {
  echo "=== Deploy Hydra ==="
  : "${HYDRA_DATABASE_DSN:?Set HYDRA_DATABASE_DSN for deploy}"
  : "${HYDRA_SYSTEM_SECRET:?Set HYDRA_SYSTEM_SECRET for deploy}"
  : "${HYDRA_COOKIE_SECRET:?Set HYDRA_COOKIE_SECRET for deploy}"
  helm upgrade --install "$HYDRA_RELEASE" "$ORY_REPO_NAME/hydra" \
    -n "$NAMESPACE" \
    -f values-hydra.yaml \
    --set-string "hydra.config.dsn=$HYDRA_DATABASE_DSN" \
    --set-string "hydra.config.secrets.system[0]=$HYDRA_SYSTEM_SECRET" \
    --set-string "hydra.config.secrets.cookie[0]=$HYDRA_COOKIE_SECRET"
  kubectl rollout status deployment "$HYDRA_RELEASE" -n "$NAMESPACE" --timeout=120s
}

deploy_kratos() {
  echo "=== Deploy Kratos ==="
  : "${KRATOS_DATABASE_DSN:?Set KRATOS_DATABASE_DSN for deploy}"
  : "${KRATOS_DEFAULT_SECRET:?Set KRATOS_DEFAULT_SECRET for deploy}"
  : "${KRATOS_COOKIE_SECRET:?Set KRATOS_COOKIE_SECRET for deploy}"
  helm upgrade --install "$KRATOS_RELEASE" "$ORY_REPO_NAME/kratos" \
    -n "$NAMESPACE" \
    -f values-kratos.yaml \
    --set-string "kratos.config.dsn=$KRATOS_DATABASE_DSN" \
    --set-string "kratos.config.secrets.default[0]=$KRATOS_DEFAULT_SECRET" \
    --set-string "kratos.config.secrets.cookie[0]=$KRATOS_COOKIE_SECRET"
  kubectl rollout status deployment "$KRATOS_RELEASE" -n "$NAMESPACE" --timeout=120s
}

create_hydra_client() {
  echo "=== Create Hydra OAuth2 client ==="
  kubectl exec -n "$NAMESPACE" "deploy/$HYDRA_RELEASE" -- \
    hydra delete oauth2-client arda-shell \
    --endpoint http://127.0.0.1:4445 2>/dev/null || true

  kubectl exec -n "$NAMESPACE" "deploy/$HYDRA_RELEASE" -- \
    hydra create oauth2-client \
    --endpoint http://127.0.0.1:4445 \
    --id arda-shell \
    --grant-type authorization_code \
    --grant-type refresh_token \
    --response-type code \
    --scope openid,email,offline_access \
    --redirect-uri https://api.arda.io.vn/api/auth/callback \
    --redirect-uri https://arda.io.vn/callback \
    --redirect-uri http://localhost:5000/api/auth/callback \
    --redirect-uri http://localhost:5000/callback \
    --token-endpoint-auth-method none \
    --skip-consent
}

create_kratos_identity() {
  local email="$1"
  local name="$2"

  kubectl exec -n "$NAMESPACE" "deploy/$KRATOS_RELEASE" -- \
    kratos import \
    --endpoint http://127.0.0.1:4434 \
    /dev/stdin <<EOF 2>/dev/null || true
{
  "schema_id": "default",
  "traits": {
    "email": "$email",
    "name": "$name"
  },
  "credentials": {
    "password": {
      "config": {
        "password": "$SUPERADMIN_PASSWORD"
      }
    }
  }
}
EOF
}

create_seed_identities() {
  echo "=== Create Kratos seed identities ==="
  create_kratos_identity "$SUPERADMIN_EMAIL" "Super Admin"
  create_kratos_identity "$DEV_ADMIN_EMAIL" "Admin"
}

setup_nodeports() {
  echo "=== Setup NodePorts ==="
  kubectl apply -n "$NAMESPACE" -f auth-admin-nodeport.yaml
}

case "${1:-deploy}" in
  reset)
    : "${SUPERADMIN_INITIAL_PASSWORD:?Set SUPERADMIN_INITIAL_PASSWORD for auth bootstrap}"
    : "${HYDRA_DATABASE_DSN:?Set HYDRA_DATABASE_DSN for auth deploy}"
    : "${KRATOS_DATABASE_DSN:?Set KRATOS_DATABASE_DSN for auth deploy}"
    reset_databases
    deploy_hydra
    deploy_kratos
    create_hydra_client
    create_seed_identities
    setup_nodeports
    ;;
  deploy)
    : "${SUPERADMIN_INITIAL_PASSWORD:?Set SUPERADMIN_INITIAL_PASSWORD for auth bootstrap}"
    : "${HYDRA_DATABASE_DSN:?Set HYDRA_DATABASE_DSN for auth deploy}"
    : "${KRATOS_DATABASE_DSN:?Set KRATOS_DATABASE_DSN for auth deploy}"
    deploy_hydra
    deploy_kratos
    create_hydra_client
    create_seed_identities
    setup_nodeports
    ;;
  reset-db)
    reset_databases
    ;;
  client)
    : "${SUPERADMIN_INITIAL_PASSWORD:?Set SUPERADMIN_INITIAL_PASSWORD for identity seed}"
    create_hydra_client
    create_seed_identities
    ;;
  nodeport)
    setup_nodeports
    ;;
  *)
    echo "Usage: $0 {deploy|reset|reset-db|client|nodeport}"
    exit 1
    ;;
esac

echo "=== Done ==="
echo "Hydra public:  https://auth.arda.io.vn"
echo "Kratos public: https://identity.arda.io.vn"
echo "Hydra Admin NodePort: 30445"
echo "Kratos Admin NodePort: 30446"
echo "Superadmin identity: $SUPERADMIN_EMAIL"
echo "Dev admin identity:  $DEV_ADMIN_EMAIL"
