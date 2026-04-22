#!/bin/bash
set -e

# Load secrets
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a && source "$SCRIPT_DIR/../.env" && set +a
fi

GREEN='\033[0;32m'
NC='\033[0m'

APISIX_ADMIN="http://127.0.0.1:9180"
API_KEY="${APISIX_API_KEY:?APISIX_API_KEY is not set}"

echo -e "${GREEN}==> Port-forwarding APISIX admin API...${NC}"
kubectl port-forward -n gateway deployment/apisix 9180:9180 &
PF_PID=$!
sleep 2

trap "kill $PF_PID 2>/dev/null" EXIT

echo -e "${GREEN}==> Creating APISIX routes...${NC}"

# Route: mfe-common (/common/*) - ID 1, Priority 10
curl -s "$APISIX_ADMIN/apisix/admin/routes/1" \
  -H "X-API-KEY: $API_KEY" \
  -X PUT \
  -d '{
    "uri": "/common/*",
    "host": "arda.io.vn",
    "priority": 10,
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "mfe-common.arda-dev.svc.cluster.local:80": 1
      }
    }
  }'
echo ""

# Route: iam-login-public (/v1/auth/login) - ID 5, Priority 9 (KHÔNG CÓ AUTH)
curl -s "$APISIX_ADMIN/apisix/admin/routes/5" \
  -H "X-API-KEY: $API_KEY" \
  -X PUT \
  -d '{
    "uri": "/v1/auth/login",
    "host": "arda.io.vn",
    "priority": 9,
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "iam-service.arda-dev.svc.cluster.local:8000": 1
      }
    }
  }'
echo ""

# Route: iam-api (/v1/*) - ID 6, Priority 8 (CÓ FORWARD AUTH)
curl -s "$APISIX_ADMIN/apisix/admin/routes/6" \
  -H "X-API-KEY: $API_KEY" \
  -X PUT \
  -d '{
    "uri": "/v1/*",
    "host": "arda.io.vn",
    "priority": 8,
    "plugins": {
      "forward-auth": {
        "uri": "http://iam-service.arda-dev.svc.cluster.local:8000/v1/auth/forward",
        "request_headers": ["Authorization"],
        "upstream_headers": ["X-User-Id", "X-Tenant-Id"]
      }
    },
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "iam-service.arda-dev.svc.cluster.local:8000": 1
      }
    }
  }'
echo ""

# Route: mfe-shell (/* - catch all) - ID 3, Priority 1
curl -s "$APISIX_ADMIN/apisix/admin/routes/3" \
  -H "X-API-KEY: $API_KEY" \
  -X PUT \
  -d '{
    "uri": "/*",
    "host": "arda.io.vn",
    "priority": 1,
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "mfe-shell.arda-dev.svc.cluster.local:80": 1
      }
    }
  }'
echo ""

# Route: Zitadel (auth.arda.io.vn/*) - ID 4
curl -s "$APISIX_ADMIN/apisix/admin/routes/4" \
  -H "X-API-KEY: $API_KEY" \
  -X PUT \
  -d '{
    "uri": "/*",
    "host": "auth.arda.io.vn",
    "priority": 100,
    "plugins": {
      "proxy-rewrite": {
        "headers": {
          "X-Forwarded-Proto": "https",
          "X-Forwarded-Host": "auth.arda.io.vn"
        }
      }
    },
    "upstream": {
      "nodes": {
        "zitadel.arda-dev.svc.cluster.local:8080": 1
      }
    }
  }'
echo ""

echo -e "${GREEN}==> Routes created. Verifying...${NC}"
curl -s "$APISIX_ADMIN/apisix/admin/routes" \
  -H "X-API-KEY: $API_KEY" | python -m json.tool 2>/dev/null || \
  curl -s "$APISIX_ADMIN/apisix/admin/routes" \
  -H "X-API-KEY: $API_KEY"

echo ""
echo -e "${GREEN}==> Done!${NC}"
