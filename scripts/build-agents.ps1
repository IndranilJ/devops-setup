<#
.SYNOPSIS
    Build and push Jenkins agent images to GCP Artifact Registry.
    Reads versions from versions.env in the project root.

.PARAMETER AgentFilter
    Optional. Build only a specific agent: python, maven, nodejs, dotnet
    If omitted, all agents are built.

.PARAMETER AgentVersion
    The version tag to apply (e.g. 2026.05.2).
    Defaults to AGENT_IMAGE_VERSION from versions.env.
    Update versions.env before running; this param overrides for one-off builds.

.PARAMETER AlsoTagLatest
    If set, also pushes a :latest tag in addition to the versioned tag.
    NOT recommended for production; use only for local dev testing.

.PARAMETER DryRun
    Print what would be done without actually building or pushing.

.EXAMPLE
    # Build all agents using version from versions.env
    .\scripts\build-agents.ps1

    # Build only the python agent
    .\scripts\build-agents.ps1 -AgentFilter python

    # Build with a specific version override
    .\scripts\build-agents.ps1 -AgentVersion 2026.06.1

    # Dry run - see what would happen
    .\scripts\build-agents.ps1 -DryRun
#>
param (
    [ValidateSet("python", "maven", "nodejs", "dotnet", "")]
    [string]$AgentFilter = "",

    [string]$AgentVersion = "",

    [switch]$AlsoTagLatest,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── LOAD versions.env ────────────────────────────────────────────────────────
$ProjectRoot = Join-Path $PSScriptRoot ".."
$VersionsFile = Join-Path $ProjectRoot "versions.env"

if (-not (Test-Path $VersionsFile)) {
    Write-Error "versions.env not found at $VersionsFile. Cannot continue."
    exit 1
}

$Versions = @{}
Get-Content $VersionsFile | Where-Object { $_ -match "^\s*[^#].*=.*" } | ForEach-Object {
    $parts = $_ -split "=", 2
    $Versions[$parts[0].Trim()] = $parts[1].Trim()
}

$PROJECT_ID    = "devops-environment-488820"
$LOCATION      = "us-central1"
$REPO          = "devops-agents"
$BASE_URL      = "$($LOCATION)-docker.pkg.dev/$($PROJECT_ID)/$($REPO)"

# Use CLI override or fall back to versions.env
if (-not $AgentVersion) {
    $AgentVersion = $Versions["AGENT_IMAGE_VERSION"]
}

if (-not $AgentVersion) {
    Write-Error "AGENT_IMAGE_VERSION not set in versions.env and -AgentVersion not provided."
    exit 1
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " DevOps Agent Builder" -ForegroundColor Cyan
Write-Host " Agent Version : $AgentVersion" -ForegroundColor Cyan
Write-Host " Registry      : $BASE_URL" -ForegroundColor Cyan
if ($DryRun) { Write-Host " [DRY RUN - no builds or pushes will occur]" -ForegroundColor Yellow }
Write-Host "=============================================" -ForegroundColor Cyan

# Build args extracted from versions.env
$BUILD_ARGS = @(
    "--build-arg", "AGENT_IMAGE_VERSION=$AgentVersion",
    "--build-arg", "TERRAFORM_VERSION=$($Versions['TERRAFORM_VERSION'])",
    "--build-arg", "AWS_CLI_VERSION=$($Versions['AWS_CLI_VERSION'])",
    "--build-arg", "SONAR_VERSION=$($Versions['SONAR_SCANNER_VERSION'])",
    "--build-arg", "GCLOUD_VERSION=$($Versions['GCLOUD_SDK_APT_VERSION'])",
    "--build-arg", "TRIVY_VERSION=$($Versions['TRIVY_VERSION'])",
    "--build-arg", "DOCKER_CLI_VERSION=$($Versions['DOCKER_CLI_VERSION'])"
)

# ─── LOGIN ────────────────────────────────────────────────────────────────────
if (-not $DryRun) {
    Write-Host "`n--- Authenticating to Artifact Registry ---" -ForegroundColor Yellow
    gcloud auth configure-docker "$($LOCATION)-docker.pkg.dev" --quiet
}

# ─── AGENT DEFINITIONS ───────────────────────────────────────────────────────
$ALL_AGENTS = @(
    @{ Name = "python"; ExtraBuildArgs = @("--build-arg", "PYTHON_VERSION=$($Versions['PYTHON_VERSION'])") },
    @{ Name = "maven";  ExtraBuildArgs = @("--build-arg", "MAVEN_JDK_VERSION=$($Versions['MAVEN_JDK_VERSION'])", "--build-arg", "MAVEN_VERSION=$($Versions['MAVEN_VERSION'])") },
    @{ Name = "nodejs"; ExtraBuildArgs = @("--build-arg", "NODEJS_MAJOR_VERSION=$($Versions['NODEJS_MAJOR_VERSION'])") },
    @{ Name = "dotnet"; ExtraBuildArgs = @("--build-arg", "DOTNET_SDK_VERSION=$($Versions['DOTNET_SDK_VERSION'])") }
)

# Filter if requested
$AGENTS_TO_BUILD = if ($AgentFilter) {
    $ALL_AGENTS | Where-Object { $_.Name -eq $AgentFilter }
} else {
    $ALL_AGENTS
}

$FailedAgents = @()
$BuiltImages  = @()

foreach ($Agent in $AGENTS_TO_BUILD) {
    $AgentName   = $Agent.Name
    $ImageName   = "jenkins-$($AgentName)-agent"
    $Dockerfile  = Join-Path $ProjectRoot "agents\Dockerfile.$($AgentName)-agent"
    $VersionedTag = "$($BASE_URL)/$($ImageName):$AgentVersion"
    $LatestTag    = "$($BASE_URL)/$($ImageName):latest"

    Write-Host "`n━━━ Building: $AgentName agent ($VersionedTag) ━━━" -ForegroundColor Cyan

    if (-not (Test-Path $Dockerfile)) {
        Write-Error "Dockerfile not found: $Dockerfile"
        $FailedAgents += $AgentName
        continue
    }

    $AllBuildArgs = $BUILD_ARGS + $Agent.ExtraBuildArgs
    $BuildCmd = @("build", "-t", $VersionedTag) + $AllBuildArgs + @("-f", $Dockerfile, (Join-Path $ProjectRoot "agents"))

    if ($DryRun) {
        Write-Host "  [DRY RUN] docker $($BuildCmd -join ' ')" -ForegroundColor Gray
    } else {
        docker @BuildCmd
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Build FAILED for $AgentName"
            $FailedAgents += $AgentName
            continue
        }
        docker push $VersionedTag
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Push FAILED for $AgentName"
            $FailedAgents += $AgentName
            continue
        }
        if ($AlsoTagLatest) {
            docker tag $VersionedTag $LatestTag
            docker push $LatestTag
        }
        Write-Host "  ✅ Pushed: $VersionedTag" -ForegroundColor Green
        $BuiltImages += $VersionedTag
    }
}

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
Write-Host "`n=============================================" -ForegroundColor Cyan
if ($FailedAgents.Count -gt 0) {
    Write-Host " ❌ Failed agents: $($FailedAgents -join ', ')" -ForegroundColor Red
    exit 1
} else {
    Write-Host " ✅ All agents built and pushed successfully" -ForegroundColor Green
    Write-Host ""
    Write-Host " Next steps:" -ForegroundColor Yellow
    Write-Host "   1. Update jenkins.agentImageVersion in helm/devops-platform/values.yaml to: $AgentVersion" -ForegroundColor Yellow
    Write-Host "      (this tells Jenkins which image tag to use for new agent pods)" -ForegroundColor Gray
    Write-Host "   2. Deploy the change: .\scripts\helm-deploy.ps1 -Action deploy" -ForegroundColor Yellow
    Write-Host "      (helm upgrade --atomic restarts Jenkins and picks up the new agentImageVersion)" -ForegroundColor Gray
    Write-Host "   3. Trigger a test build to verify agents connect:" -ForegroundColor Yellow
    Write-Host "      Jenkins UI -> devops/test-agents -> Build Now" -ForegroundColor Gray
}
