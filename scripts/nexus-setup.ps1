<#
.SYNOPSIS
    First-time Nexus Repository Manager setup: password change + repository creation.

.DESCRIPTION
    WHAT THIS SCRIPT DOES (TWO PHASES):

    Phase 1 — Initial Password Change:
    Nexus generates a random initial admin password and writes it to a file
    inside the container: /nexus-data/admin.password
    This script reads that file via kubectl exec, uses it to authenticate, then
    changes the password to the value in $env:NEXUS_PASSWORD.
    After a successful password change, Nexus deletes the admin.password file
    automatically, so Phase 1 is naturally idempotent — if the file is gone,
    the initial password was already changed.

    Phase 2 — Repository Creation:
    Creates three repositories needed by app teams:
      - docker-hosted       : Internal Docker image registry (stores built images)
      - maven-central-proxy : Caches Maven Central (faster builds, offline-safe)
      - npm-proxy           : Caches NPM registry (faster builds, offline-safe)
    Also enables the Docker Bearer Token realm (required for docker login to work).

    WHY PORT-FORWARD?
    This script runs from your local machine. Nexus is inside the cluster.
    Port-forward creates a tunnel: localhost:8081 → nexus pod:8081
    The port-forward process is started in the background and killed at the end.

    IDEMPOTENCY:
    The New-Repo function checks if each repository already exists (GET request)
    before attempting to create it (POST). Safe to re-run.

    PREREQUISITE:
    $env:NEXUS_PASSWORD must be set. devops-env.ps1 fetches this from GCP
    Secret Manager and sets it before calling this script.

.EXAMPLE
    # Normally called automatically by devops-env.ps1 -Action setup.
    # To run manually:
    $env:NEXUS_PASSWORD = (gcloud secrets versions access latest --secret=nexus-admin-password)
    .\scripts\nexus-setup.ps1
#>
param ()


$ErrorActionPreference = "Stop"

# Port-forward Nexus to localhost so we can configure it
Write-Host "Port-forwarding Nexus..."
$pfProcess = Start-Process -FilePath "kubectl" -ArgumentList "port-forward statefulset/nexus 8081:8081 -n devops" -PassThru -NoNewWindow
Start-Sleep -Seconds 5 # Wait for port-forward to establish

$NexusUrl = "http://localhost:8081"
$Auth = "admin:$env:NEXUS_PASSWORD"

# Handle initial password reset
$InitialPassword = ""
try {
    $InitialPassword = kubectl exec nexus-0 -n devops -c nexus -- cat /nexus-data/admin.password 2>$null
} catch {}

if ($InitialPassword) {
    Write-Host "Initial Nexus password found. Changing password..."
    $InitAuth = "admin:$InitialPassword"
    $EncodedInitAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($InitAuth))
    $InitHeaders = @{
        "Authorization" = "Basic $EncodedInitAuth"
        "Content-Type"  = "text/plain"
        "Accept"        = "application/json"
    }
    
    try {
        Invoke-RestMethod -Uri "$NexusUrl/service/rest/v1/security/users/admin/change-password" -Headers $InitHeaders -Method Put -Body $env:NEXUS_PASSWORD | Out-Null
        Write-Host "Password changed successfully."
        # Nexus deletes the admin.password file automatically after password change, but we can double check.
    } catch {
        Write-Host "Failed to change initial password. It may have already been changed." -ForegroundColor Yellow
    }
}

$EncodedAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($Auth))
$Headers = @{
    "Authorization" = "Basic $EncodedAuth"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

Write-Host "Configuring Nexus at $NexusUrl..."

function New-Repo($RepoName, $RecipeName, $RepoJson) {
    # Check if repo exists
    try {
        $response = Invoke-RestMethod -Uri "$NexusUrl/service/rest/v1/repositories/$RepoName" -Headers $Headers -Method Get -ErrorAction Stop
        Write-Host "Repository '$RepoName' already exists. Skipping."
    } catch {
        if ($_.Exception.Response.StatusCode -eq "NotFound") {
            Write-Host "Creating repository '$RepoName'..."
            Invoke-RestMethod -Uri "$NexusUrl/service/rest/v1/repositories/$RecipeName" -Headers $Headers -Method Post -Body $RepoJson
        } else {
            throw $_
        }
    }
}

# 1. Docker Hosted Repository
$DockerJson = @"
{
  "name": "docker-hosted",
  "online": true,
  "storage": { "blobStoreName": "default", "strictContentTypeValidation": true, "writePolicy": "allow_once" },
  "component": { "proprietaryComponents": true },
  "docker": { "v1Enabled": false, "forceBasicAuth": true, "httpPort": 8082 }
}
"@
New-Repo "docker-hosted" "docker/hosted" $DockerJson

# 2. Maven Proxy Repository (Maven Central)
$MavenJson = @"
{
  "name": "maven-central-proxy",
  "online": true,
  "storage": { "blobStoreName": "default", "strictContentTypeValidation": true },
  "proxy": { "remoteUrl": "https://repo1.maven.org/maven2/", "contentMaxAge": 1440, "metadataMaxAge": 1440 },
  "negativeCache": { "enabled": true, "timeToLive": 1440 },
  "httpClient": { "blocked": false, "autoBlock": true, "connection": { "retries": 0, "userAgentSuffix": "", "timeout": 60, "enableCircularRedirects": false, "enableCookies": false } },
  "maven": { "versionPolicy": "RELEASE", "layoutPolicy": "PERMISSIVE" }
}
"@
New-Repo "maven-central-proxy" "maven/proxy" $MavenJson

# 3. NPM Proxy Repository
$NpmJson = @"
{
  "name": "npm-proxy",
  "online": true,
  "storage": { "blobStoreName": "default", "strictContentTypeValidation": true },
  "proxy": { "remoteUrl": "https://registry.npmjs.org/", "contentMaxAge": 1440, "metadataMaxAge": 1440 },
  "negativeCache": { "enabled": true, "timeToLive": 1440 },
  "httpClient": { "blocked": false, "autoBlock": true, "connection": { "retries": 0, "userAgentSuffix": "", "timeout": 60, "enableCircularRedirects": false, "enableCookies": false } }
}
"@
New-Repo "npm-proxy" "npm/proxy" $NpmJson

# Enable Docker Bearer Token Realm for docker push/pull
Write-Host "Enabling Docker Bearer Token Realm..."
$ActiveRealms = Invoke-RestMethod -Uri "$NexusUrl/service/rest/v1/security/realms/active" -Headers $Headers -Method Get
if ($ActiveRealms -notcontains "DockerToken") {
    $ActiveRealms += "DockerToken"
    $RealmJson = $ActiveRealms | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "$NexusUrl/service/rest/v1/security/realms/active" -Headers $Headers -Method Put -Body $RealmJson | Out-Null
}

Write-Host "Nexus setup complete."
if ($pfProcess) {
    Stop-Process -Id $pfProcess.Id -Force -ErrorAction SilentlyContinue
}
