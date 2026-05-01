# Media & CRM Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Media Service, BPM Bridge, CRM Service, and Infrastructure (SeaweedFS, Camunda 8) via ArgoCD.

**Architecture:** Standardized kustomize manifests for each component, integrated into existing ArgoCD Application manifests. External DB access via Kubernetes Service/Endpoints.

**Tech Stack:** K8s, Kustomize, ArgoCD, Go, Kotlin.

---

### Task 1: External Database Integration

**Files:**
- Create: `apps/base/external-db/service.yaml`
- Create: `apps/base/external-db/endpoints.yaml`
- Create: `apps/base/external-db/kustomization.yaml`

- [ ] **Step 1: Create Service and Endpoints for ThinkCentre Postgres**

```yaml
# apps/base/external-db/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-external
  namespace: infra
spec:
  ports:
    - port: 5432
      targetPort: 5432
---
# apps/base/external-db/endpoints.yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: postgres-external
  namespace: infra
subsets:
  - addresses:
      - ip: 192.168.1.100 # Adjust to actual ThinkCentre IP
    ports:
      - port: 5432
```

- [ ] **Step 2: Create Kustomization for external-db**

```yaml
# apps/base/external-db/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yaml
  - endpoints.yaml
```

- [ ] **Step 3: Commit infrastructure changes**

```bash
git add apps/base/external-db
git commit -m "infra: add external postgres integration"
```

### Task 2: SeaweedFS ArgoCD Application

**Files:**
- Create: `argocd/apps/infra-seaweedfs.yaml`

- [ ] **Step 1: Create ArgoCD Application for SeaweedFS**

```yaml
# argocd/apps/infra-seaweedfs.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: seaweedfs
  namespace: argocd
spec:
  project: arda-platform
  source:
    repoURL: https://github.com/arda-labs/arda-infra.git
    targetRevision: main
    path: apps/base/seaweedfs
  destination:
    server: https://kubernetes.default.svc
    namespace: infra
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: Commit ArgoCD manifest**

```bash
git add argocd/apps/infra-seaweedfs.yaml
git commit -m "infra: add seaweedfs argocd application"
```

### Task 3: Camunda 8 ArgoCD Application

**Files:**
- Create: `argocd/apps/infra-camunda8.yaml`

- [ ] **Step 1: Create ArgoCD Application for Camunda 8**

```yaml
# argocd/apps/infra-camunda8.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: camunda8
  namespace: argocd
spec:
  project: arda-platform
  source:
    repoURL: https://github.com/arda-labs/arda-infra.git
    targetRevision: main
    path: apps/base/camunda8
  destination:
    server: https://kubernetes.default.svc
    namespace: infra
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: Commit ArgoCD manifest**

```bash
git add argocd/apps/infra-camunda8.yaml
git commit -m "infra: add camunda8 argocd application"
```

### Task 4: Media Service Deployment Manifests

**Files:**
- Create: `apps/media-service/base/service.yaml`
- Create: `apps/media-service/base/kustomization.yaml`
- Create: `apps/media-service/overlays/dev/kustomization.yaml`

- [ ] **Step 1: Create Media Service base manifests**

```yaml
# apps/media-service/base/service.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: media-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: media-service
  template:
    metadata:
      labels:
        app: media-service
    spec:
      containers:
        - name: media-service
          image: ghcr.io/arda-labs/media-service:latest
          env:
            - name: STORAGE_S3_ENDPOINT
              value: "http://seaweedfs-s3.infra.svc.cluster.local:8333"
            - name: DATABASE_URL
              value: "postgres://user:pass@postgres-external.infra.svc.cluster.local:5432/media?sslmode=disable"
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: media-service
spec:
  ports:
    - port: 80
      targetPort: 8080
  selector:
    app: media-service
```

- [ ] **Step 2: Create Media Service kustomizations**

```yaml
# apps/media-service/base/kustomization.yaml
resources:
  - service.yaml

# apps/media-service/overlays/dev/kustomization.yaml
namespace: arda-apps
resources:
  - ../../base
```

- [ ] **Step 3: Commit manifests**

```bash
git add apps/media-service
git commit -m "infra: add media-service manifests"
```

### Task 5: ArgoCD Application Registry Update

**Files:**
- Modify: `argocd/apps/arda-apps.yaml`

- [ ] **Step 1: Add new services to arda-apps Application set**

```yaml
# Add to argocd/apps/arda-apps.yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: media-service
  namespace: argocd
spec:
  project: arda-platform
  source:
    repoURL: https://github.com/arda-labs/arda-infra.git
    targetRevision: main
    path: apps/media-service/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: arda-apps
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

- [ ] **Step 2: Add BPM Bridge and CRM Service similarly** (repeat structure for bpm-bridge and crm-service)

- [ ] **Step 3: Commit updates**

```bash
git add argocd/apps/arda-apps.yaml
git commit -m "infra: register media-service, bpm-bridge, and crm-service in argocd"
```
