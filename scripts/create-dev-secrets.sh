#!/bin/bash
# Script tạo Kubernetes Secrets cho môi trường dev
# Chạy một lần khi setup cluster mới
# KHÔNG commit file này lên git nếu bạn hardcode giá trị thật vào đây

NAMESPACE="arda-dev"

echo "=== Tạo secrets cho iam-service ==="
kubectl create secret generic iam-service-secrets \
  --from-literal=DATABASE_URL='postgres://iam:iam%40123@thinkcenter:5432/iam?sslmode=disable' \
  --from-literal=REDIS_ADDR='thinkcenter:6379' \
  --from-literal=ZITADEL_LOGIN_CLIENT_PAT='<PASTE_LOGIN_CLIENT_PAT_HERE>' \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Tạo secrets cho mfe-shell ==="
kubectl create secret generic mfe-shell-secrets \
  --from-literal=AUTH_CLIENT_ID='369717196990972004' \
  -n "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Done! ==="
kubectl get secrets -n "$NAMESPACE"
