# =============================================================================
# DEPRECATED � Superseded by Helm
# =============================================================================
# This script is no longer needed.
#
# WHY: With Helm, values.yaml IS the single source of truth.
#      Helm renders template variables at deploy time � there is nothing to
#      "sync" into files. Changing a value in values.yaml and running
#      helm upgrade automatically propagates it everywhere.
#
# REPLACED BY:
#   values.yaml                    (version config)
#   .\scripts\helm-deploy.ps1      (deploy / upgrade / rollback)
#
# This file is kept for reference. To re-enable, remove the outer <# #> wrapper.
# =============================================================================
<#
.SYNOPSIS
    Blue/Green upgrade tool for the DevOps cluster platform tools.
    Handles: Jenkins, Nexus, SonarQube, Postgres, and Agent Images.

.DESCRIPTION
    Implements a safe upgrade pattern:
      1. Validate the new image is pullable
      2. Create a blue (current) snapshot label
      3. Apply the new image (green)
      4. Wait for readiness
      5. Run smoke tests
      6. Provide a rollback command if anything fails

.PARAMETER Tool
    Which tool to upgrade: jenkins, nexus, sonarqube, postgres, agents

.PARAMETER NewVersion
    The new image tag to roll out (e.g. 2.504.2-lts-jdk21, 3.69.0, 15.8)
    For agents, this is the AGENT_IMAGE_VERSION (e.g. 2026.06.1)

.PARAMETER Action
    upgrade (default) | verify | rollback

.PARAMETER RollbackToVersion
    For rollback action: specify the version tag to roll back to.

.EXAMPLE
    # Upgrade Jenkins controller
    .\scripts\upgrade-tool.ps1 -Tool jenkins -NewVersion 2.504.2-lts-jdk21

    # Upgrade all agent images to new version
    .\scripts\upgrade-tool.ps1 -Tool agents -NewVersion 2026.06.1

    # Verify current deployment health (no change)
    .\scripts\upgrade-tool.ps1 -Tool jenkins -Action verify

    # Rollback Jenkins to previous version
    .\scripts\upgrade-tool.ps1 -Tool jenkins -Action rollback -RollbackToVersion 2.504.1-lts-jdk21
#>
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("jenkins", "nexus", "sonarqube", "postgres", "agents")]
    [string]$Tool,

    [string]$NewVersion = "",

    [ValidateSet("upgrade", "verify", "rollback")]
    [string]$Action = "upgrade",

    [string]$RollbackToVersion = ""
)

# DEPRECATED: This script is superseded by helm-deploy.ps1.
# If you need to re-enable it, remove the throw below.
throw "DEPRECATED: Use .\scripts\helm-deploy.ps1 instead. See the deprecation notice at the top of this file."

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Namespace     = "devops"
$ProjectRoot   = Join-Path $PSScriptRoot ".."
$VersionsFile  = Join-Path $ProjectRoot "versions.env"
$ManifestsRoot = Join-Path $ProjectRoot "k8s\manifests"
$PROJECT_ID    = "devops-environment-488820"
$LOCATION      = "us-central1"
$REPO_BASE     = "$($LOCATION)-docker.pkg.dev/$($PROJECT_ID)/devops-agents"

# ─── LOAD VERSIONS ────────────────────────────────────────────────────────────
$Versions = @{}
Get-Content $VersionsFile | Where-Object { $_ -match "^\s*[^#].*=.*" } | ForEach-Object {
    $parts = $_ -split "=", 2
    $Versions[$parts[0].Trim()] = $parts[1].Trim()
}

# ─── TOOL DEFINITIONS ─────────────────────────────────────────────────────────
$ToolConfig = @{
    jenkins    = @{
        Kind          = "statefulset"
        Name          = "jenkins"
        ContainerName = "jenkins"
        ImageBase     = "jenkins/jenkins"
        ManifestPath  = Join-Path $ManifestsRoot "jenkins"
        UseKustomize  = $true
        HealthPath    = "/login"
        HealthPort    = 8080
        ReadyLabel    = "app.kubernetes.io/name=jenkins"
    }
    nexus      = @{
        Kind          = "statefulset"
        Name          = "nexus"
        ContainerName = "nexus"
        ImageBase     = "sonatype/nexus3"
        ManifestPath  = Join-Path $ManifestsRoot "nexus"
        UseKustomize  = $false
        HealthPath    = "/service/rest/v1/status"
        HealthPort    = 8081
        ReadyLabel    = "app.kubernetes.io/name=nexus"
    }
    sonarqube  = @{
        Kind          = "deployment"
        Name          = "sonarqube"
        ContainerName = "sonarqube"
        ImageBase     = "sonarqube"
        ManifestPath  = Join-Path $ManifestsRoot "sonarqube"
        UseKustomize  = $false
        HealthPath    = "/api/system/status"
        HealthPort    = 9000
        ReadyLabel    = "app.kubernetes.io/name=sonarqube"
    }
    postgres   = @{
        Kind          = "deployment"
        Name          = "postgres"
        ContainerName = "postgres"
        ImageBase     = "postgres"
        ManifestPath  = Join-Path $ManifestsRoot "postgres"
        UseKustomize  = $false
        HealthPath    = ""
        HealthPort    = 5432
        ReadyLabel    = "app.kubernetes.io/name=postgres"
    }
}

function Write-Step($msg) {
    Write-Host "`n[$($msg)]" -ForegroundColor Cyan
}

function Write-Ok($msg) { Write-Host "  ✅ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  ⚠️  $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "  ❌ $msg" -ForegroundColor Red }

# ─── VERIFY ACTION ────────────────────────────────────────────────────────────
function Invoke-Verify {
    Write-Step "Verifying current cluster health"

    $tools = if ($Tool -eq "agents") { @("jenkins") } else { @($Tool) }

    foreach ($t in $tools) {
        $cfg = $ToolConfig[$t]
        Write-Host "  Checking $t..." -NoNewline
        $ready = kubectl get $cfg.Kind $cfg.Name -n $Namespace `
            -o jsonpath="{.status.readyReplicas}" 2>$null
        if ($ready -ge 1) {
            Write-Ok "$t is ready ($ready replica(s))"
        } else {
            Write-Fail "$t has 0 ready replicas"
        }
    }

    Write-Host ""
    Write-Host "  Pod status:" -ForegroundColor Yellow
    kubectl get pods -n $Namespace -o wide
}

# ─── ROLLBACK ACTION ──────────────────────────────────────────────────────────
function Invoke-Rollback {
    if (-not $RollbackToVersion) {
        Write-Fail "-RollbackToVersion is required for rollback action."
        exit 1
    }

    if ($Tool -eq "agents") {
        Write-Step "Rolling back agent images to $RollbackToVersion"
        $agents = @("python", "maven", "nodejs", "dotnet")
        foreach ($a in $agents) {
            $img = "$REPO_BASE/jenkins-$($a)-agent:$RollbackToVersion"
            Write-Host "  Rolling back $a to $img"
            kubectl set image statefulset/jenkins `
                jnlp=$img -n $Namespace 2>$null
        }
        # Update JCasC ConfigMap
        Write-Warn "Remember to also update jenkins.yaml image tags to $RollbackToVersion and re-apply kustomize."
        return
    }

    $cfg = $ToolConfig[$Tool]
    $img = "$($cfg.ImageBase):$RollbackToVersion"

    Write-Step "Rolling back $Tool to $img"
    kubectl set image "$($cfg.Kind)/$($cfg.Name)" `
        "$($cfg.ContainerName)=$img" -n $Namespace

    Write-Step "Waiting for rollback rollout..."
    kubectl rollout status "$($cfg.Kind)/$($cfg.Name)" -n $Namespace --timeout=300s
    Write-Ok "Rollback complete. Verify with: .\scripts\upgrade-tool.ps1 -Tool $Tool -Action verify"
}

# ─── UPGRADE ACTION ───────────────────────────────────────────────────────────
function Invoke-Upgrade {
    if (-not $NewVersion) {
        Write-Fail "-NewVersion is required for upgrade action."
        exit 1
    }

    # ── AGENT IMAGE UPGRADE ───────────────────────────────────────────────────
    if ($Tool -eq "agents") {
        Write-Step "Upgrading Jenkins agent images to version $NewVersion"
        Write-Host ""
        Write-Host "  This does NOT change the running K8s workload directly." -ForegroundColor Yellow
        Write-Host "  Agent pods are ephemeral - new version takes effect for next build." -ForegroundColor Yellow
        Write-Host ""

        $ManifestFile = Join-Path $ManifestsRoot "jenkins\jenkins.yaml"
        $content = Get-Content $ManifestFile -Raw

        # Replace all agent image version tags
        $currentVersion = $Versions["AGENT_IMAGE_VERSION"]
        $newContent = $content -replace "(:)(${currentVersion})", ":$NewVersion"

        if ($content -eq $newContent) {
            Write-Warn "No version references to '$currentVersion' found in jenkins.yaml. Check manually."
        } else {
            Set-Content -Path $ManifestFile -Value $newContent -NoNewline
            Write-Ok "Updated jenkins.yaml agent image tags: $currentVersion -> $NewVersion"
        }

        # Update versions.env
        $versionsContent = Get-Content $VersionsFile -Raw
        $versionsContent = $versionsContent -replace "AGENT_IMAGE_VERSION=.*", "AGENT_IMAGE_VERSION=$NewVersion"
        Set-Content -Path $VersionsFile -Value $versionsContent -NoNewline
        Write-Ok "Updated AGENT_IMAGE_VERSION in versions.env to $NewVersion"

        Write-Step "Applying updated JCasC ConfigMap via Kustomize"
        $jenkinsManifestPath = Join-Path $ManifestsRoot "jenkins"
        kubectl apply -k $jenkinsManifestPath
        kubectl rollout restart statefulset/jenkins -n $Namespace
        kubectl rollout status statefulset/jenkins -n $Namespace --timeout=300s
        Write-Ok "Jenkins restarted with updated agent config. New agent images will be used from next build."
        return
    }

    # ── PLATFORM TOOL UPGRADE ─────────────────────────────────────────────────
    $cfg = $ToolConfig[$Tool]
    $NewImage = "$($cfg.ImageBase):$NewVersion"

    Write-Step "Pre-flight: Checking image exists"
    # Pull just the manifest (fast, no download)
    docker manifest inspect $NewImage 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Image not found or not pullable: $NewImage"
        Write-Host "  Ensure the image tag exists before upgrading." -ForegroundColor Red
        exit 1
    }
    Write-Ok "Image verified: $NewImage"

    Write-Step "Capturing current version for potential rollback"
    $currentImage = kubectl get $cfg.Kind $cfg.Name -n $Namespace `
        -o jsonpath="{.spec.template.spec.containers[?(@.name=='$($cfg.ContainerName)')].image}"
    Write-Warn "Current: $currentImage"
    Write-Warn "To rollback, run: .\scripts\upgrade-tool.ps1 -Tool $Tool -Action rollback -RollbackToVersion <TAG>"

    Write-Step "Applying new image: $NewImage"
    kubectl set image "$($cfg.Kind)/$($cfg.Name)" `
        "$($cfg.ContainerName)=$NewImage" -n $Namespace

    Write-Step "Waiting for rollout (timeout: 5m)"
    kubectl rollout status "$($cfg.Kind)/$($cfg.Name)" -n $Namespace --timeout=300s
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Rollout did not complete. Check pod events:"
        kubectl describe pods -l $cfg.ReadyLabel -n $Namespace
        Write-Warn "Rollback with: .\scripts\upgrade-tool.ps1 -Tool $Tool -Action rollback -RollbackToVersion <PREV_TAG>"
        exit 1
    }
    Write-Ok "Rollout complete"

    Write-Step "Smoke test: checking pod readiness"
    $ready = kubectl get $cfg.Kind $cfg.Name -n $Namespace `
        -o jsonpath="{.status.readyReplicas}"
    if ($ready -ge 1) {
        Write-Ok "$Tool is ready with $ready replica(s) running $NewImage"
    } else {
        Write-Fail "Pod not ready after rollout. Investigate:"
        kubectl get pods -l $cfg.ReadyLabel -n $Namespace
        exit 1
    }

    # Update versions.env to reflect new deployed version
    Write-Step "Updating versions.env"
    $versionKey = @{
        jenkins   = "JENKINS_TAG"
        nexus     = "NEXUS_TAG"
        sonarqube = "SONARQUBE_TAG"
        postgres  = "POSTGRES_TAG"
    }[$Tool]

    $versionsContent = Get-Content $VersionsFile -Raw
    $versionsContent = $versionsContent -replace "${versionKey}=.*", "${versionKey}=$NewVersion"
    Set-Content -Path $VersionsFile -Value $versionsContent -NoNewline
    Write-Ok "Updated $versionKey=$NewVersion in versions.env"

    Write-Host ""
    Write-Host "━━━ Upgrade Summary ━━━" -ForegroundColor Green
    Write-Host "  Tool    : $Tool" -ForegroundColor White
    Write-Host "  From    : $currentImage" -ForegroundColor White
    Write-Host "  To      : $NewImage" -ForegroundColor White
    Write-Host "  Status  : ✅ Successful" -ForegroundColor Green
    Write-Host ""
    Write-Host "  IMPORTANT: Commit the following changes to Git:" -ForegroundColor Yellow
    Write-Host "    - versions.env ($versionKey updated)" -ForegroundColor Yellow
    Write-Host "    - Update the corresponding manifest image tag in k8s/manifests/$Tool/" -ForegroundColor Yellow
}

# ─── DISPATCH ─────────────────────────────────────────────────────────────────
switch ($Action) {
    "verify"   { Invoke-Verify }
    "rollback" { Invoke-Rollback }
    "upgrade"  { Invoke-Upgrade }
}

