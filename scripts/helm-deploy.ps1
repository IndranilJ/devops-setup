<#
.SYNOPSIS
    Deploy / upgrade / rollback / verify the DevOps platform using Helm.

.DESCRIPTION
    WHAT IS HELM INSTALL vs UPGRADE?
    - helm install: First-time deployment. Creates the "release" in Kubernetes.
    - helm upgrade: Updates an existing release with new values or templates.
    - helm upgrade --install: Does install if not exists, upgrade if already deployed.
      This is the most common pattern — idempotent, works on fresh or existing clusters.

    WHAT IS A RELEASE?
    When Helm deploys a chart it creates a "release" — a named, tracked instance.
    This release stores revision history so you can rollback to any previous version.
    The release name here is: devops-platform

    WHAT IS --atomic?
    If any resource fails to become ready within the timeout, Helm automatically
    rolls back to the previous revision. This is your safety net.

    WHAT IS --dry-run?
    Renders all templates and prints the resulting YAML without applying anything.
    Essential for reviewing changes before applying.

.PARAMETER Action
    deploy   - Install or upgrade the platform
    rollback - Roll back to a previous Helm revision
    verify   - Show current release status and revision history
    diff     - Preview what would change (requires helm-diff plugin)
    template - Render templates to YAML for debugging

.PARAMETER JenkinsPassword
    Admin password for Jenkins. If provided, secrets are injected into the namespace.
.PARAMETER DbPassword
    Database password for SonarQube.
.PARAMETER GithubToken
    GitHub Personal Access Token.

.PARAMETER Revision
    The revision number for rollback operations.
.PARAMETER Set
    Manual --set overrides for the helm command.
#>
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("deploy", "rollback", "verify", "diff", "template")]
    [string]$Action,

    [string]$JenkinsPassword = "",
    [string]$DbPassword = "",
    [string]$GithubToken = "",

    [int]$Revision = 0,
    [string]$Set = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ReleaseName = "devops-platform"
$ChartPath   = Join-Path $PSScriptRoot "..\helm\devops-platform"
$Namespace   = "devops"
$Timeout     = "10m"

function Write-Step($msg) { Write-Host "`n$msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  ✅ $msg" -ForegroundColor Green }

# Build optional --set flag
$SetFlag = if ($Set) { "--set `"$Set`"" } else { "" }

switch ($Action) {

    "deploy" {
        # ┌─────────────────────────────────────────────────────────────────────────┐
        # │ STEP 1: Namespace & Secret Injection                                    │
        # │ - We create the namespace and secrets BEFORE running Helm.              │
        # │ - This ensures that when Helm creates the Pods, their dependencies      │
        # │   (secrets/configmaps) are already present.                             │
        # └─────────────────────────────────────────────────────────────────────────┘
        Write-Host "Ensuring namespace '$Namespace' exists..." -ForegroundColor Yellow
        $ProjectRoot = Split-Path -Parent $PSScriptRoot
        $ManifestsDir = Join-Path $ProjectRoot "k8s\manifests"
        kubectl apply -f "$ManifestsDir\namespace.yaml"

        # "Sign" the namespace and quota so Helm accepts ownership
        kubectl label namespace $Namespace app.kubernetes.io/managed-by=Helm --overwrite
        kubectl annotate namespace $Namespace meta.helm.sh/release-name=$ReleaseName --overwrite
        kubectl annotate namespace $Namespace meta.helm.sh/release-namespace=$Namespace --overwrite

        kubectl label resourcequota devops-quota -n $Namespace app.kubernetes.io/managed-by=Helm --overwrite
        kubectl annotate resourcequota devops-quota -n $Namespace meta.helm.sh/release-name=$ReleaseName --overwrite
        kubectl annotate resourcequota devops-quota -n $Namespace meta.helm.sh/release-namespace=$Namespace --overwrite

        if ($JenkinsPassword -and $DbPassword) {
            Write-Host "Injecting environment secrets..." -ForegroundColor Yellow
            
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

            $ProjectRoot = Split-Path -Parent $PSScriptRoot
            $ConfigRoot = Join-Path $ProjectRoot "config"
            kubectl create configmap jenkins-casc-config `
                --from-file="jenkins.yaml=$ConfigRoot\jenkins\jenkins-casc.yaml" `
                --from-file="plugins.txt=$ConfigRoot\jenkins\plugins.txt" `
                --from-file="jenkins_jobs.groovy=$ConfigRoot\jenkins\jenkins-jobs.groovy" `
                --from-file="seed-bootstrap.groovy=$ConfigRoot\jenkins\seed-bootstrap.groovy" `
                --namespace="$Namespace" `
                --dry-run=client -o yaml | kubectl apply -f -
        }

        # ┌─────────────────────────────────────────────────────────────────────────┐
        # │ STEP 2: Helm Upgrade/Install                                            │
        # │ - Deploys the actual application workloads.                             │
        # │ - --wait: Blocks until all pods are Ready.                              │
        # └─────────────────────────────────────────────────────────────────────────┘
        Write-Host "Deploying / upgrading $ReleaseName..." -ForegroundColor Cyan
        $helmCmd = "helm upgrade --install $ReleaseName $ChartPath --namespace $Namespace --create-namespace --atomic --cleanup-on-fail --timeout 10m --wait"
        if ($Set) { $helmCmd += " --set $Set" }
        
        Write-Host "  Chart   : $ChartPath" -ForegroundColor Gray
        Write-Host "  Running: $helmCmd" -ForegroundColor Gray
        Invoke-Expression $helmCmd

        Write-Ok "Deployment successful"
        Write-Host ""
        Write-Host "  Verify with:  .\scripts\helm-deploy.ps1 -Action verify" -ForegroundColor Yellow
    }

    "rollback" {
        if ($Revision -eq 0) {
            Write-Host "  Specify -Revision N. See history with: .\scripts\helm-deploy.ps1 -Action verify" -ForegroundColor Red
            exit 1
        }
        Write-Step "Rolling back $ReleaseName to revision $Revision"
        helm rollback $ReleaseName $Revision --namespace $Namespace --wait
        Write-Ok "Rolled back to revision $Revision"
    }

    "verify" {
        Write-Step "Release Status"
        helm status $ReleaseName --namespace $Namespace

        Write-Step "Revision History"
        # helm history shows all revisions with their chart version, status, and description
        helm history $ReleaseName --namespace $Namespace

        Write-Step "Pod Status"
        kubectl get pods -n $Namespace -o wide
    }

    "diff" {
        Write-Step "Previewing changes (helm diff)"
        Write-Host "  This shows what WOULD change without applying anything." -ForegroundColor Yellow
        Write-Host "  Requires the helm-diff plugin: helm plugin install https://github.com/databus23/helm-diff" -ForegroundColor Yellow
        Write-Host ""

        $cmd = "helm diff upgrade $ReleaseName $ChartPath --namespace $Namespace $SetFlag"
        Invoke-Expression $cmd
    }

    "template" {
        Write-Step "Rendering templates (no cluster required)"
        Write-Host "  Outputs the fully-rendered Kubernetes YAML that Helm would apply." -ForegroundColor Yellow
        Write-Host ""

        $cmd = "helm template $ReleaseName $ChartPath --namespace $Namespace $SetFlag"
        Invoke-Expression $cmd
    }
}
