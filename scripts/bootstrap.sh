#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}==> Bootstrapping Arda Production-Ready Infra <==${NC}"

# 1. Basic Setup
kubectl apply -f infrastructure/namespaces.yaml
kubectl apply -f infrastructure/storageclass.yaml

# 2. Install Helm if not present
if ! command -v helm &> /dev/null; then
  echo -e "${GREEN}==> Installing Helm...${NC}"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 3. Install APISIX Gateway
echo -e "${GREEN}==> Installing APISIX...${NC}"
helm repo add apisix https://charts.apiseven.com || true
helm repo update
helm upgrade --install apisix apisix/apisix \
  -n gateway \
  -f apps/gateway/apisix/helm-values.yaml

# 4. Wait for APISIX
echo -e "${GREEN}==> Waiting for APISIX...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/apisix-gateway -n gateway
kubectl wait --for=condition=available --timeout=300s deployment/apisix-ingress-controller -n gateway

# 4b. Install Zitadel
echo -e "${GREEN}==> Installing Zitadel...${NC}"
helm repo add zitadel https://charts.zitadel.com || true
helm repo update
kubectl create secret generic zitadel-masterkey --from-literal=masterkey="$(openssl rand -base64 32 | head -c 32)" -n arda-dev --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install zitadel zitadel/zitadel \
  -n arda-dev \
  -f apps/zitadel/base/helm-values.yaml

# 5. Install ArgoCD
echo -e "${GREEN}==> Installing ArgoCD...${NC}"
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 6. Wait for ArgoCD
echo -e "${GREEN}==> Waiting for ArgoCD Server...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 7. Apply Projects & Root App
echo -e "${GREEN}==> Applying ArgoCD Projects and Root App...${NC}"
kubectl apply -f argocd/projects/projects.yaml
kubectl apply -f bootstrap/root-app.yaml

echo -e "${GREEN}==> Bootstrap complete!${NC}"
