#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo -e "${GREEN}==> Bootstrapping Arda platform base <==${NC}"

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
helm repo add apisix https://apache.github.io/apisix-helm-chart || true
helm repo update
helm upgrade --install apisix apisix/apisix \
  -n gateway \
  --create-namespace \
  --set gateway.type=NodePort \
  --set dashboard.enabled=false \
  --set etcd.persistence.enabled=false \
  --set ingress-controller.enabled=true \
  --set ingress-controller.config.apisix.adminAPIVersion=v3 \
  --set ingress-controller.config.kubernetes.namespaceSelector[0]=''

# 4. Wait for APISIX
echo -e "${GREEN}==> Waiting for APISIX...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/apisix -n gateway
kubectl wait --for=condition=available --timeout=300s deployment/apisix-ingress-controller -n gateway

# 5. Install ArgoCD
echo -e "${GREEN}==> Installing ArgoCD...${NC}"
kubectl create -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || true

# 6. Wait for ArgoCD
echo -e "${GREEN}==> Waiting for ArgoCD Server...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 7. Apply Projects & Root App
echo -e "${GREEN}==> Applying ArgoCD Projects and Root App...${NC}"
kubectl apply -f argocd/projects/projects.yaml
kubectl apply -f bootstrap/root-app.yaml

echo -e "${GREEN}==> Bootstrap complete!${NC}"
