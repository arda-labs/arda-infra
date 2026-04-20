#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}==> Bootstrapping Arda Production-Ready Infra <==${NC}"

# 1. Basic Setup
kubectl apply -f infrastructure/namespaces.yaml
kubectl apply -f infrastructure/storageclass.yaml

# 2. Install ArgoCD
echo -e "${GREEN}==> Installing ArgoCD...${NC}"
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Wait for ArgoCD
echo -e "${GREEN}==> Waiting for ArgoCD Server...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# 4. Apply Projects & Root App
echo -e "${GREEN}==> Applying ArgoCD Projects and Root App...${NC}"
kubectl apply -f argocd/projects/projects.yaml
kubectl apply -f bootstrap/root-app.yaml

echo -e "${GREEN}==> Bootstrap complete!${NC}"
