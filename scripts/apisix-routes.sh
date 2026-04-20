#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

APISIX_ADMIN="http://127.0.0.1:9180"
API_KEY="edd1c9f034335f136f87ad84b625c8f1"

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
