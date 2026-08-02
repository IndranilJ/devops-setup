#!/bin/bash
# =============================================================================
# scripts/devops-env.sh
# Lifecycle management for the DevOps GKE cluster environment.
# Shell equivalent of devops-env.ps1 — use this on Linux/macOS or in CI.
# =============================================================================
#
# THREE ACTIONS:
#
#   setup  — One-time bootstrap after a fresh Terraform apply.
#            Order matters:
#              1. Namespace first  — everything else lives inside it
#              2. Secrets second   — pods reference them at startup; missing = crash loop
#              3. Manifests/Helm   — workloads are deployed last
#
#   stop   — Hibernation. Scales pods AND node pool to 0.
#            WHY NODE POOL? GKE charges per node, not per pod.
#            Scaling the node pool removes the VMs (zero compute cost).
#            Persistent disks and GCS backups remain intact.
#
#   start  — Wake up. Provisions the node pool back to 1, then scales pods up.
#            kubectl wait blocks until the node is Ready before scaling pods.
#
# IDEMPOTENT SECRET CREATION:
#   Pattern: kubectl create secret ... --dry-run=client -o yaml | kubectl apply -f -
#   Creates if missing, updates if exists. Safe to re-run.
#
# STEP 5 — TWO DEPLOYMENT OPTIONS (see below in the script):
#   Option A: Raw kubectl apply  (active by default in this script)
#   Option B: Helm               (comment A, uncomment B)
#
# REQUIRED ENV VARS for 'setup':
#   JENKINS_PASSWORD   — Jenkins admin password
#   DB_PASSWORD        — PostgreSQL password (also used by SonarQube)
#   GITHUB_TOKEN       — GitHub token for Jenkins pipeline access
#
# USAGE:
#   ./scripts/devops-env.sh setup
#   ./scripts/devops-env.sh stop
#   ./scripts/devops-env.sh start
# =============================================================================

NAMESPACE="devops"
CLUSTER_NAME="devops-cluster"
REGION="us-central1"
MANIFESTS_DIR="$(dirname "$0")/../k8s/manifests"

ACTION=$1

# ─── SETUP ────────────────────────────────────────────────────────────────────
if [ "$ACTION" == "setup" ]; then
    echo "=== DevOps Environment Setup ==="

    # Validate required env vars
    if [ -z "$JENKINS_PASSWORD" ] || [ -z "$DB_PASSWORD" ]; then
        echo "ERROR: Required environment variables are not set."
        echo "  export JENKINS_PASSWORD='your-jenkins-password'"
        echo "  export DB_PASSWORD='your-db-password'"
        exit 1
    fi

    # 1. Bootstrap namespace + resource quota
    echo "[1/5] Creating namespace and resource quota..."
    kubectl apply -f "$MANIFESTS_DIR/namespace.yaml"

    # 2. Create Jenkins secret
    echo "[2/5] Creating Jenkins admin secret..."
    kubectl create secret generic jenkins-admin-secret \
        --namespace="$NAMESPACE" \
        --from-literal=JENKINS_ADMIN_PASSWORD="$JENKINS_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f -

    # 3. Create Postgres secret (shared with SonarQube)
    echo "[3/5] Creating Postgres/SonarQube secret..."
    kubectl create secret generic postgres-secret \
        --namespace="$NAMESPACE" \
        --from-literal=POSTGRES_USER="sonar" \
        --from-literal=POSTGRES_PASSWORD="$DB_PASSWORD" \
        --from-literal=POSTGRES_DB="sonar" \
        --dry-run=client -o yaml | kubectl apply -f -

    # 4. Apply storage manifests
    echo "[4/5] Applying storage (StorageClass + PersistentVolumes)..."
    kubectl apply -f "$MANIFESTS_DIR/storageclass.yaml"
    kubectl apply -f "$MANIFESTS_DIR/storage/pv.yaml"

    # 5. Deploy application workloads — TWO OPTIONS, pick one:
    #
    # ┌─────────────────────────────────────────────────────────────────────┐
    # │  OPTION A: Raw kubectl apply (active — no Helm required)           │
    # │  - Applies manifests directly from k8s/manifests/                  │
    # │  - Jenkins uses kustomize (-k flag) for ConfigMap generation        │
    # │  - No revision history; rollback = manually revert YAML            │
    # └─────────────────────────────────────────────────────────────────────┘
    echo "[5/5] Applying application manifests..."
    kubectl apply -f "$MANIFESTS_DIR/postgres/"
    kubectl apply -f "$MANIFESTS_DIR/sonarqube/"
    kubectl apply -f "$MANIFESTS_DIR/nexus/"
    kubectl apply -k "$MANIFESTS_DIR/jenkins/"   # -k = kustomize (reads kustomization.yaml)
    kubectl apply -f "$MANIFESTS_DIR/backups/"   # backup CronJobs + RBAC (moved from storage/)

    # ┌─────────────────────────────────────────────────────────────────────┐
    # │  OPTION B: Helm (recommended for upgrades + rollback)              │
    # │  - Single command deploys all resources (PVCs, RBAC, pods, etc.)  │
    # │  - Tracks revision history → helm rollback <release> <revision>    │
    # │  - --atomic auto-rolls back if any pod fails readiness             │
    # │  - To switch: comment out Option A above, uncomment below          │
    # └─────────────────────────────────────────────────────────────────────┘
    # echo "[5/5] Deploying platform via Helm..."
    # helm upgrade --install devops-platform ./helm/devops-platform \
    #     --namespace "$NAMESPACE" --create-namespace \
    #     --atomic --cleanup-on-fail --timeout 10m --wait

    echo ""
    echo "Setup complete! Check pod status with:"
    echo "  kubectl get pods -n $NAMESPACE"

# ─── STOP (HIBERNATE) ─────────────────────────────────────────────────────────
elif [ "$ACTION" == "stop" ]; then
    echo "=== Hibernating DevOps Environment ==="

    echo "[1/2] Scaling all pods to 0..."
    kubectl scale statefulset jenkins  --replicas=0 -n "$NAMESPACE"
    kubectl scale statefulset nexus    --replicas=0 -n "$NAMESPACE"
    kubectl scale deployment sonarqube --replicas=0 -n "$NAMESPACE"
    kubectl scale deployment postgres  --replicas=0 -n "$NAMESPACE"

    echo "[2/2] Scaling node pool to 0 (zero compute cost)..."
    gcloud container clusters resize "$CLUSTER_NAME" \
        --node-pool="${CLUSTER_NAME}-node-pool" \
        --region="$REGION" \
        --num-nodes=0 \
        --quiet

    echo "Environment hibernated. Data is safe on persistent disks."

# ─── START (WAKE UP) ──────────────────────────────────────────────────────────
elif [ "$ACTION" == "start" ]; then
    echo "=== Starting DevOps Environment ==="

    echo "[1/2] Provisioning node (e2-standard-4)..."
    gcloud container clusters resize "$CLUSTER_NAME" \
        --node-pool="${CLUSTER_NAME}-node-pool" \
        --region="$REGION" \
        --num-nodes=1 \
        --quiet

    echo "Waiting for node to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    echo "[2/2] Scaling all pods to 1..."
    kubectl scale statefulset jenkins  --replicas=1 -n "$NAMESPACE"
    kubectl scale statefulset nexus    --replicas=1 -n "$NAMESPACE"
    kubectl scale deployment sonarqube --replicas=1 -n "$NAMESPACE"
    kubectl scale deployment postgres  --replicas=1 -n "$NAMESPACE"

    echo "Environment started. Check pod status with:"
    echo "  kubectl get pods -n $NAMESPACE"

# ─── USAGE ────────────────────────────────────────────────────────────────────
else
    echo "Usage: $0 [setup|start|stop]"
    echo ""
    echo "  setup  — First-time: create secrets and deploy all apps"
    echo "  start  — Wake up hibernated environment"
    echo "  stop   — Hibernate environment (zero compute cost)"
    exit 1
fi
