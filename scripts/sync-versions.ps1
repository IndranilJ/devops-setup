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
    Syncs all image versions across K8s manifests and Dockerfiles.

.DESCRIPTION
    Two modes:
      AUTO:   Reads versions from versions.env and propagates to all files.
      MANUAL: Pass specific -Override* params to update only those values.
              All other values are left exactly as-is. Useful for troubleshooting
              a single service without touching the rest of the cluster.

    Always use -DryRun first to preview changes before applying.

.PARAMETER DryRun
    Preview all changes without writing any files. Shows a before/after diff.

.PARAMETER Target
    Scope the sync to a specific area. Default: all
    Values: all | jenkins | nexus | sonarqube | postgres | agents | dockerfiles

.PARAMETER ShowStatus
    Print the current state of all image versions across all files, then exit.
    No changes are made. Useful for auditing drift between files and versions.env.

    ─── MANUAL OVERRIDE PARAMS ───────────────────────────────────────────────
    When any Override param is supplied, the script runs in MANUAL mode.
    Only the files relevant to the supplied params are touched.
    versions.env is NOT read in manual mode (unless you also want auto values).

.PARAMETER OverrideJenkinsTag
    Manually set the Jenkins controller image tag.
    Affected files: jenkins/statefulset.yaml (controller + init container)

.PARAMETER OverrideAgentBaseTag
    Manually set the jenkins/inbound-agent base tag used in all Dockerfiles.
    Affected files: all 4 agent Dockerfiles (JENKINS_AGENT_BASE_TAG ARG default)

.PARAMETER OverrideAgentImageVersion
    Manually set the agent image version tag (custom images in Artifact Registry).
    Affected files: jenkins/statefulset.yaml (AGENT_IMAGE_VERSION env var)

.PARAMETER OverrideNexusTag
    Manually set the Nexus image tag.
    Affected files: nexus/statefulset.yaml

.PARAMETER OverrideSonarQubeTag
    Manually set the SonarQube image tag.
    Affected files: sonarqube/deployment.yaml

.PARAMETER OverridePostgresTag
    Manually set the Postgres image tag.
    Affected files: postgres/deployment.yaml

.PARAMETER OverrideGcloudTag
    Manually set the gcloud-sdk sidecar tag (affects all backup sidecars).
    Affected files: jenkins, nexus, postgres statefulsets/deployments

.PARAMETER OverrideBusyboxTag
    Manually set the busybox init container tag.
    Affected files: jenkins, nexus, sonarqube statefulsets/deployments

.PARAMETER OverrideUbuntuBuilderTag
    Manually set the ubuntu tools-builder stage tag in all Dockerfiles.
    Affected files: all 4 agent Dockerfiles (UBUNTU_BUILDER_TAG ARG default)

.EXAMPLE
    # Preview auto-sync from versions.env (safe - no changes)
    .\scripts\sync-versions.ps1 -DryRun

    # Apply all versions from versions.env
    .\scripts\sync-versions.ps1

    # Audit current state - what tag is actually in each file right now?
    .\scripts\sync-versions.ps1 -ShowStatus

    # Sync only Jenkins-related files
    .\scripts\sync-versions.ps1 -Target jenkins

    # MANUAL: pin just Jenkins to a specific tag for troubleshooting
    # (nothing else is touched)
    .\scripts\sync-versions.ps1 -OverrideJenkinsTag 2.504.2-lts-jdk21 -DryRun
    .\scripts\sync-versions.ps1 -OverrideJenkinsTag 2.504.2-lts-jdk21

    # MANUAL: temporarily pin agent base to Java 17 for one agent type investigation
    .\scripts\sync-versions.ps1 -OverrideAgentBaseTag "latest-jdk17" -DryRun

    # MANUAL: rollback only Nexus without touching anything else
    .\scripts\sync-versions.ps1 -OverrideNexusTag 3.67.0
#>
param (
    [ValidateSet("all", "jenkins", "nexus", "sonarqube", "postgres", "agents", "dockerfiles")]
    [string]$Target = "all",

    [switch]$DryRun,
    [switch]$ShowStatus,

    # ── Manual overrides (any of these triggers manual mode) ──────────────────
    [string]$OverrideJenkinsTag         = "",
    [string]$OverrideAgentBaseTag       = "",
    [string]$OverrideAgentImageVersion  = "",
    [string]$OverrideNexusTag           = "",
    [string]$OverrideSonarQubeTag       = "",
    [string]$OverridePostgresTag        = "",
    [string]$OverrideGcloudTag          = "",
    [string]$OverrideBusyboxTag         = "",
    [string]$OverrideUbuntuBuilderTag   = ""
)

# DEPRECATED: This script is superseded by helm-deploy.ps1 + values.yaml.
# If you need to re-enable it, remove the throw below.
throw "DEPRECATED: Use .\scripts\helm-deploy.ps1 instead. See the deprecation notice at the top of this file."

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot   = Join-Path $PSScriptRoot ".."
$VersionsFile  = Join-Path $ProjectRoot "versions.env"
$ManifestsRoot = Join-Path $ProjectRoot "k8s\manifests"
$AgentsDir     = Join-Path $ProjectRoot "agents"

# ─── HELPERS ──────────────────────────────────────────────────────────────────
function Write-Header($msg) { Write-Host "`n$msg" -ForegroundColor Cyan }
function Write-Change($file, $from, $to) {
    $fname = Split-Path $file -Leaf
    Write-Host "  [$fname]" -ForegroundColor Gray -NoNewline
    Write-Host "  $from" -ForegroundColor Red -NoNewline
    Write-Host "  →  " -NoNewline
    Write-Host "$to" -ForegroundColor Green
}
function Write-Skip($file, $reason) {
    $fname = Split-Path $file -Leaf
    Write-Host "  [$fname] (no change: $reason)" -ForegroundColor DarkGray
}
function Write-Ok($msg)   { Write-Host "  ✅ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  ⚠️  $msg" -ForegroundColor Yellow }

$ChangesApplied = 0
$ChangesSkipped = 0

# ─── APPLY SUBSTITUTION ───────────────────────────────────────────────────────
# Updates a file in-place using regex. Handles DryRun automatically.
# Pattern must contain exactly one capture group () for the part BEFORE the version.
function Set-VersionInFile {
    param(
        [string]$File,
        [string]$Pattern,       # regex with one capture group before the version value
        [string]$NewValue,      # the new version string (just the version, not full line)
        [string]$Label          # human-readable label for output
    )

    if (-not (Test-Path $File)) {
        Write-Warn "File not found, skipping: $File"
        return
    }

    $content = Get-Content $File -Raw
    if ($content -match $Pattern) {
        $currentValue = $Matches[2]   # group 2 = captured version value
        if ($currentValue -eq $NewValue) {
            $script:ChangesSkipped++
            Write-Skip $File "already $NewValue"
            return
        }
        $newContent = $content -replace $Pattern, "`${1}$NewValue`${3}"
        Write-Change $File "$Label : $currentValue" "$NewValue"
        if (-not $DryRun) {
            Set-Content -Path $File -Value $newContent -NoNewline
        }
        $script:ChangesApplied++
    } else {
        Write-Warn "Pattern not matched in $File — skipping. Pattern: $Pattern"
    }
}

# ─── LOAD VERSIONS.ENV ────────────────────────────────────────────────────────
$Versions = @{}

$ManualMode = $OverrideJenkinsTag -or $OverrideAgentBaseTag -or $OverrideAgentImageVersion `
              -or $OverrideNexusTag -or $OverrideSonarQubeTag -or $OverridePostgresTag `
              -or $OverrideGcloudTag -or $OverrideBusyboxTag -or $OverrideUbuntuBuilderTag

if (-not $ManualMode) {
    # Auto mode: load everything from versions.env
    if (-not (Test-Path $VersionsFile)) {
        Write-Error "versions.env not found at $VersionsFile"
        exit 1
    }
    Get-Content $VersionsFile | Where-Object { $_ -match "^\s*[^#].*=.*" } | ForEach-Object {
        $parts = $_ -split "=", 2
        $Versions[$parts[0].Trim()] = $parts[1].Trim()
    }
    Write-Host "Mode: AUTO (reading from versions.env)" -ForegroundColor Cyan
} else {
    Write-Host "Mode: MANUAL (using supplied overrides only)" -ForegroundColor Yellow
}

# Resolve effective values (manual overrides win over versions.env)
function Get-Version($key, $override) {
    if ($override) { return $override }
    if ($Versions.ContainsKey($key)) { return $Versions[$key] }
    return $null
}

$V = @{
    JenkinsTag         = Get-Version "JENKINS_TAG"              $OverrideJenkinsTag
    AgentBaseTag       = Get-Version "JENKINS_AGENT_BASE_TAG"   $OverrideAgentBaseTag
    AgentImageVersion  = Get-Version "AGENT_IMAGE_VERSION"      $OverrideAgentImageVersion
    NexusTag           = Get-Version "NEXUS_TAG"                $OverrideNexusTag
    SonarQubeTag       = Get-Version "SONARQUBE_TAG"            $OverrideSonarQubeTag
    PostgresTag        = Get-Version "POSTGRES_TAG"             $OverridePostgresTag
    GcloudTag          = Get-Version "GCLOUD_SDK_TAG"           $OverrideGcloudTag
    BusyboxTag         = Get-Version "BUSYBOX_TAG"              $OverrideBusyboxTag
    UbuntuBuilderTag   = Get-Version "UBUNTU_BUILDER_TAG"       $OverrideUbuntuBuilderTag
}

# ─── SHOW STATUS ──────────────────────────────────────────────────────────────
if ($ShowStatus) {
    Write-Host "`n━━━ Current Version State ━━━" -ForegroundColor Cyan
    Write-Host "  (versions.env → actual value in each file)`n" -ForegroundColor Gray

    function Show-FileVersion($label, $file, $pattern) {
        if (-not (Test-Path $file)) { Write-Host "  $label : FILE NOT FOUND" -ForegroundColor Red; return }
        $content = Get-Content $file -Raw
        $actual = if ($content -match $pattern) { $Matches[2] } else { "PATTERN NOT MATCHED" }
        $key = $label.Split(" ")[0]
        $expected = if ($Versions.ContainsKey($key)) { $Versions[$key] } else { "n/a" }
        $match = if ($actual -eq $expected) { "✅" } else { "❌" }
        $fname = Split-Path $file -Leaf
        Write-Host ("  {0,-30} {1,-45} [{2}] in {3}" -f $label, $actual, $match, $fname)
    }

    $jSS = Join-Path $ManifestsRoot "jenkins\statefulset.yaml"
    $nSS = Join-Path $ManifestsRoot "nexus\statefulset.yaml"
    $sqD = Join-Path $ManifestsRoot "sonarqube\deployment.yaml"
    $pgD = Join-Path $ManifestsRoot "postgres\deployment.yaml"

    Show-FileVersion "JENKINS_TAG"             $jSS '(image: jenkins/jenkins:)([^\s\r\n"]+)()'
    Show-FileVersion "AGENT_IMAGE_VERSION"      $jSS '(name: AGENT_IMAGE_VERSION\s+value: ")([^"]+)(")'
    Show-FileVersion "NEXUS_TAG"               $nSS '(image: sonatype/nexus3:)([^\s\r\n"]+)()'
    Show-FileVersion "SONARQUBE_TAG"           $sqD '(image: sonarqube:)([^\s\r\n"]+)()'
    Show-FileVersion "POSTGRES_TAG"            $pgD '(image: postgres:)([^\s\r\n"]+)()'
    Show-FileVersion "GCLOUD_SDK_TAG (jenkins)" $jSS '(image: google/cloud-sdk:)([^\s\r\n"]+)()'
    Show-FileVersion "BUSYBOX_TAG (jenkins)"   $jSS '(image: busybox:)([^\s\r\n"]+)()'

    $agents = @("python", "maven", "nodejs", "dotnet")
    foreach ($a in $agents) {
        $df = Join-Path $AgentsDir "Dockerfile.$a-agent"
        Show-FileVersion "JENKINS_AGENT_BASE_TAG ($a)" $df '(ARG JENKINS_AGENT_BASE_TAG=)([^\s\r\n]+)()'
    }

    Write-Host "`n  ✅ = matches versions.env   ❌ = drift detected`n" -ForegroundColor Gray
    exit 0
}

# ─── FILE PATHS ───────────────────────────────────────────────────────────────
$Files = @{
    JenkinsSS   = Join-Path $ManifestsRoot "jenkins\statefulset.yaml"
    NexusSS     = Join-Path $ManifestsRoot "nexus\statefulset.yaml"
    SonarQubeDp = Join-Path $ManifestsRoot "sonarqube\deployment.yaml"
    PostgresDp  = Join-Path $ManifestsRoot "postgres\deployment.yaml"
    Dockerfiles = @("python","maven","nodejs","dotnet") | ForEach-Object {
        Join-Path $AgentsDir "Dockerfile.$_-agent"
    }
}

if ($DryRun) {
    Write-Host "`n[DRY RUN - no files will be modified]`n" -ForegroundColor Yellow
}

# ─── SYNC: JENKINS ────────────────────────────────────────────────────────────
$syncJenkins = $Target -eq "all" -or $Target -eq "jenkins"
if ($syncJenkins) {
    Write-Header "Jenkins Controller"

    if ($V.JenkinsTag) {
        # Controller container (matches first occurrence - both uses same tag)
        Set-VersionInFile $Files.JenkinsSS `
            '(image: jenkins/jenkins:)([^\s\r\n"]+)()' `
            $V.JenkinsTag "jenkins/jenkins"
    }

    if ($V.AgentImageVersion) {
        Set-VersionInFile $Files.JenkinsSS `
            '(name: AGENT_IMAGE_VERSION\s+value: ")([^"]+)(")' `
            $V.AgentImageVersion "AGENT_IMAGE_VERSION"
    }

    if ($V.GcloudTag) {
        Set-VersionInFile $Files.JenkinsSS `
            '(image: google/cloud-sdk:)([^\s\r\n"]+)()' `
            $V.GcloudTag "gcloud-sdk (jenkins)"
    }

    if ($V.BusyboxTag) {
        Set-VersionInFile $Files.JenkinsSS `
            '(image: busybox:)([^\s\r\n"]+)()' `
            $V.BusyboxTag "busybox (jenkins)"
    }
}

# ─── SYNC: NEXUS ──────────────────────────────────────────────────────────────
$syncNexus = $Target -eq "all" -or $Target -eq "nexus"
if ($syncNexus) {
    Write-Header "Nexus"

    if ($V.NexusTag) {
        Set-VersionInFile $Files.NexusSS `
            '(image: sonatype/nexus3:)([^\s\r\n"]+)()' `
            $V.NexusTag "sonatype/nexus3"
    }

    if ($V.GcloudTag) {
        Set-VersionInFile $Files.NexusSS `
            '(image: google/cloud-sdk:)([^\s\r\n"]+)()' `
            $V.GcloudTag "gcloud-sdk (nexus)"
    }

    if ($V.BusyboxTag) {
        Set-VersionInFile $Files.NexusSS `
            '(image: busybox:)([^\s\r\n"]+)()' `
            $V.BusyboxTag "busybox (nexus)"
    }
}

# ─── SYNC: SONARQUBE ──────────────────────────────────────────────────────────
$syncSonar = $Target -eq "all" -or $Target -eq "sonarqube"
if ($syncSonar) {
    Write-Header "SonarQube"

    if ($V.SonarQubeTag) {
        Set-VersionInFile $Files.SonarQubeDp `
            '(image: sonarqube:)([^\s\r\n"]+)()' `
            $V.SonarQubeTag "sonarqube"
    }

    if ($V.BusyboxTag) {
        # Two busybox entries in sonarqube - replace both
        $file = $Files.SonarQubeDp
        $content = Get-Content $file -Raw
        $pattern = '(image: busybox:)([^\s\r\n"]+)()'
        $matches = [regex]::Matches($content, $pattern)
        foreach ($m in $matches) {
            $currentVal = $m.Groups[2].Value
            if ($currentVal -ne $V.BusyboxTag) {
                Write-Change $file "busybox : $currentVal" $V.BusyboxTag
                $script:ChangesApplied++
            } else {
                Write-Skip $file "busybox already $($V.BusyboxTag)"
                $script:ChangesSkipped++
            }
        }
        if (-not $DryRun -and $matches.Count -gt 0) {
            $newContent = $content -replace $pattern, "`${1}$($V.BusyboxTag)`${3}"
            Set-Content -Path $file -Value $newContent -NoNewline
        }
    }
}

# ─── SYNC: POSTGRES ───────────────────────────────────────────────────────────
$syncPostgres = $Target -eq "all" -or $Target -eq "postgres"
if ($syncPostgres) {
    Write-Header "Postgres"

    if ($V.PostgresTag) {
        Set-VersionInFile $Files.PostgresDp `
            '(image: postgres:)([^\s\r\n"]+)()' `
            $V.PostgresTag "postgres"
    }

    if ($V.GcloudTag) {
        Set-VersionInFile $Files.PostgresDp `
            '(image: google/cloud-sdk:)([^\s\r\n"]+)()' `
            $V.GcloudTag "gcloud-sdk (postgres)"
    }
}

# ─── SYNC: DOCKERFILES ────────────────────────────────────────────────────────
$syncDockerfiles = $Target -eq "all" -or $Target -eq "dockerfiles" -or $Target -eq "agents"
if ($syncDockerfiles) {
    Write-Header "Agent Dockerfiles"

    foreach ($df in $Files.Dockerfiles) {
        if ($V.UbuntuBuilderTag) {
            Set-VersionInFile $df `
                '(ARG UBUNTU_BUILDER_TAG=)([^\s\r\n]+)()' `
                $V.UbuntuBuilderTag "UBUNTU_BUILDER_TAG"
        }

        if ($V.AgentBaseTag) {
            Set-VersionInFile $df `
                '(ARG JENKINS_AGENT_BASE_TAG=)([^\s\r\n]+)()' `
                $V.AgentBaseTag "JENKINS_AGENT_BASE_TAG"
        }
    }
}

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "━━━ Summary ━━━" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "  Dry run - no files were written" -ForegroundColor Yellow
    Write-Host "  Changes that WOULD be applied : $ChangesApplied" -ForegroundColor Yellow
} else {
    Write-Host "  Changes applied : $ChangesApplied" -ForegroundColor Green
}
Write-Host "  Already up to date : $ChangesSkipped" -ForegroundColor Gray

if ($ChangesApplied -gt 0 -and -not $DryRun) {
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "    kubectl apply -k k8s/manifests/jenkins/    (if Jenkins changed)" -ForegroundColor Yellow
    Write-Host "    kubectl apply -f k8s/manifests/nexus/      (if Nexus changed)" -ForegroundColor Yellow
    Write-Host "    kubectl apply -f k8s/manifests/sonarqube/  (if SonarQube changed)" -ForegroundColor Yellow
    Write-Host "    kubectl apply -f k8s/manifests/postgres/   (if Postgres changed)" -ForegroundColor Yellow
    Write-Host "    .\scripts\build-agents.ps1                  (if Dockerfiles changed)" -ForegroundColor Yellow
}

