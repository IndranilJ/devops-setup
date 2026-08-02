<#
.SYNOPSIS
    Raw Kubernetes manifest deployment (Fallback Method).
    Applies YAML files directly from k8s/manifests using kubectl.

.DESCRIPTION
    This script is the 'Classic' alternative to the Helm-based workflow.
    It follows a strict sequential order to ensure dependencies (like secrets
    and namespaces) exist before the workloads (Jenkins, Nexus, etc.) are applied.

    USE CASE:
    - Disaster recovery if Helm is unavailable.
    - Debugging manifest issues without Helm's abstraction layer.
    - Local testing of raw Kubernetes manifests.

.PARAMETER JenkinsPassword
    The admin password for Jenkins (fetched from GCP by devops-env.ps1).
.PARAMETER DbPassword
    The database password for SonarQube (fetched from GCP by devops-env.ps1).
.PARAMETER GithubToken
    Personal Access Token for GitHub integration.
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$JenkinsPassword,

    [Parameter(Mandatory = $true)]
    [string]$DbPassword,

    [Parameter(Mandatory = $true)]
    [string]$GithubToken
)

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ManifestsDir = Join-Path $PSScriptRoot "..\k8s\manifests"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Namespace = "devops"

Write-Host "=== Raw Kubernetes Deployment ===" -ForegroundColor Cyan

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ STEP 1: Namespace (The Foundation)                                      │
# │ - All resources must live within this logical boundary.                  │
# │ - Includes ResourceQuotas for governance.                               │
# └─────────────────────────────────────────────────────────────────────────┘
Write-Host "[1/6] Creating namespace..." -ForegroundColor Yellow
kubectl apply -f "$ManifestsDir\namespace.yaml"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ STEP 2: Secrets (Application Credentials)                               │
# │ - Injected directly from GCP Secret Manager via devops-env parameters.   │
# │ - Pods reference these via secretKeyRef; must exist before pods start.  │
# └─────────────────────────────────────────────────────────────────────────┘
Write-Host "[2/6] Creating secrets..." -ForegroundColor Yellow
kubectl create secret generic jenkins-secrets `
    --namespace="$Namespace" `
    --from-literal=JENKINS_ADMIN_PASSWORD="$JenkinsPassword" `
    --from-literal=GITHUB_TOKEN="$GithubToken" `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic postgres-secret `
    --namespace="$Namespace" `
    --from-literal=POSTGRES_USER="sonar" `
    --from-literal=POSTGRES_PASSWORD="$DbPassword" `
    --from-literal=POSTGRES_DB="sonar" `
    --dry-run=client -o yaml | kubectl apply -f -

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ STEP 3: ConfigMaps (Configuration as Code)                              │
# │ - Jenkins JCasC and plugin list.                                        │
# │ - Stored in Git (config/jenkins/) and projected into the cluster.       │
# └─────────────────────────────────────────────────────────────────────────┘
Write-Host "[3/6] Creating ConfigMaps..." -ForegroundColor Yellow
$ConfigRoot = Join-Path $ProjectRoot "config"
kubectl create configmap jenkins-casc-config `
    --from-file="jenkins.yaml=$ConfigRoot\jenkins\jenkins-casc.yaml" `
    --from-file="plugins.txt=$ConfigRoot\jenkins\plugins.txt" `
    --from-file="jenkins_jobs.groovy=$ConfigRoot\jenkins\jenkins-jobs.groovy" `
    --from-file="seed-bootstrap.groovy=$ConfigRoot\jenkins\seed-bootstrap.groovy" `
    --namespace="$Namespace" `
    --dry-run=client -o yaml | kubectl apply -f -

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ STEP 4: Storage (Persistence Layer)                                     │
# │ - StorageClass + PersistentVolumes.                                     │
# │ - Binds the Kubernetes objects to the physical GCP Persistent Disks.    │
# └─────────────────────────────────────────────────────────────────────────┘
Write-Host "[4/6] Applying storage..." -ForegroundColor Yellow
kubectl apply -f "$ManifestsDir\storageclass.yaml"
kubectl apply -f "$ManifestsDir\storage\pv.yaml"

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ STEP 5: Application Workloads                                           │
# │ - Deploys Postgres, SonarQube, Nexus, and Jenkins.                      │
# │ - Uses Kustomize for Jenkins to generate the final deployment YAML.     │
# └─────────────────────────────────────────────────────────────────────────┘
Write-Host "[5/6] Applying application manifests..." -ForegroundColor Yellow
kubectl apply -f "$ManifestsDir\postgres\"
kubectl apply -f "$ManifestsDir\sonarqube\"
kubectl apply -f "$ManifestsDir\nexus\"
kubectl apply -k "$ManifestsDir\jenkins\"
kubectl apply -f "$ManifestsDir\backups\"

Write-Host "[6/6] Verification..." -ForegroundColor Yellow
kubectl get pods -n $Namespace
