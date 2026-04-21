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

# Route: mfe-common (/common/*)
curl -s "$APISIX_ADMIN/apisix/admin/routes/1" \
  -H "X-API-KEY: $API_KEY" \
  -X PUT \
  -d '{
    "uri": "/common/*",
    "host": "arda.io.vn",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "mfe-common.arda-dev.svc.cluster.local:80": 1
      }
    }
  }'
echo ""

# Route: Zitadel (auth.arda.io.vn/*)
curl -s "$APISIX_ADMIN/apisix/admin/routes/4" \
  -H "X-API-KEY: $API_KEY" \
  -X PUT \
  -d '{
    "uri": "/*",
    "host": "auth.arda.io.vn",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "zitadel.arda-dev.svc.cluster.local:8080": 1
      }
    }
  }'
echo ""

# Route: go-crm (/api/*)
curl -s "$APISIX_ADMIN/apisix/admin/routes/2" \
  -H "X-API-KEY: $API_KEY" \
  -X PUT \
  -d '{
    "uri": "/api/*",
    "host": "arda.io.vn",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "go-crm.arda-dev.svc.cluster.local:80": 1
      }
    }
  }'
echo ""

# Route: mfe-shell (/* - catch all)
curl -s "$APISIX_ADMIN/apisix/admin/routes/3" \
  -H "X-API-KEY: $API_KEY" \
  -X PUT \
  -d '{
    "uri": "/*",
    "host": "arda.io.vn",
    "upstream": {
      "type": "roundrobin",
      "nodes": {
        "mfe-shell.arda-dev.svc.cluster.local:80": 1
      }
    }
  }'
echo ""

echo -e "${GREEN}==> Routes created. Verifying...${NC}"
curl -s "$APISIX_ADMIN/apisix/admin/routes" \
  -H "X-API-KEY: $API_KEY" | python3 -m json.tool 2>/dev/null || \
  curl -s "$APISIX_ADMIN/apisix/admin/routes" \
  -H "X-API-KEY: $API_KEY"

echo ""
echo -e "${GREEN}==> Done!${NC}"
