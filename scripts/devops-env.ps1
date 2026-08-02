<#
.SYNOPSIS
    Lifecycle management for the DevOps GKE cluster environment.
    Handles one-time setup (secrets + deploy), hibernation, and wake-up.

.DESCRIPTION
    MODULAR ACTIONS:

    setup  — One-time bootstrap. Run this after a fresh Terraform apply.
    stop   — Hibernate: scale to zero (saves compute cost, data preserved).
    start  — Wake up: restore node and scale pods back to 1.

    JENKINS OPS:
    reload-jcasc           — Fast Sync local YAML to cluster + Hot reload JCasC API.
    reload-seed-job        — Fast Sync local Groovy to cluster + Trigger Seed Job.
    reload-jenkins-plugins — Sync plugins.txt + Rollout restart Jenkins.

    SONARQUBE OPS:
    export-sonar-config    — Export Quality Profiles/Gates from Pod to Git.
    import-sonar-config    — Import Quality Profiles/Gates from Git to Pod.
    export-sonar-plugins   — Download .jar plugins from Pod to Git plugins folder.
    import-sonar-plugins   — Upload .jar plugins from Git to Pod + Clean Sync + Restart.

.PARAMETER Action
    Modular action to perform (setup, start, stop, reload-jcasc, etc.)

.EXAMPLE
    # First time after terraform apply
    .\scripts\devops-env.ps1 -Action setup

    # End of workday - save GCP costs overnight
    .\scripts\devops-env.ps1 -Action stop

    # Next morning - bring it all back
    .\scripts\devops-env.ps1 -Action start
#>
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "setup", "start", "stop", 
        "reload-jcasc", "reload-seed-job", "reload-jenkins-plugins",
        "import-sonar-config", "export-sonar-config",
        "import-sonar-plugins", "export-sonar-plugins"
    )]
    [string]$Action,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Helm", "Kubectl")]
    [string]$Method = "Helm",

    [Parameter(Mandatory = $false)]
    [switch]$SkipSonar,

    [Parameter(Mandatory = $false)]
    [switch]$SkipNexus
)


# ─── CONFIG ───────────────────────────────────────────────────────────────────
$Namespace = "devops"
$ClusterName = "devops-cluster"
$NodePoolName = "$ClusterName-node-pool"
$Region = "us-central1"
$ManifestsDir = Join-Path $PSScriptRoot "..\k8s\manifests"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ProjectId = "devops-environment-488820"

# ─── SETUP ────────────────────────────────────────────────────────────────────
if ($Action -eq "setup") {
    Write-Host "=== DevOps Environment Setup ===" -ForegroundColor Cyan

    # ── STEP 0: Fetch secrets from GCP Secret Manager ──────────────────────────
    # WHY GCP SECRET MANAGER? Secrets are stored encrypted in GCP, not in Git.
    # The Terraform 03-secrets layer creates these secret names — this script
    # fetches the values and injects them as Kubernetes secrets.
    Write-Host "Fetching secrets from GCP Secret Manager..." -ForegroundColor Yellow
    function Get-GcpSecret($SecretName) {
        $secret = gcloud secrets versions access latest --secret=$SecretName --project=$ProjectId 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $secret) {
            Write-Host "ERROR: Failed to fetch secret '$SecretName'. Ensure you have applied the 03-secrets Terraform layer." -ForegroundColor Red
            exit 1
        }
        return $secret
    }

    $JenkinsPassword = Get-GcpSecret "jenkins-admin-password"
    $DbPassword = Get-GcpSecret "db-password"
    $GithubToken = Get-GcpSecret "github-token"
    $SonarPassword = Get-GcpSecret "sonar-admin-password"
    $NexusPassword = Get-GcpSecret "nexus-admin-password"

    # Export for downstream tool-config scripts (sonarqube-setup.ps1, nexus-setup.ps1)
    # These scripts read from the environment, not from GCP, to avoid double-fetching.
    $env:NEXUS_PASSWORD = $NexusPassword
    $env:SONAR_PASSWORD = $SonarPassword

    if ($Method -eq "Helm") {
        Write-Host "Delegating deployment to Helm orchestrator..." -ForegroundColor Cyan
        & "$PSScriptRoot\helm-deploy.ps1" -Action deploy `
            -JenkinsPassword "$JenkinsPassword" `
            -DbPassword "$DbPassword" `
            -GithubToken "$GithubToken"
    }
    else {
        Write-Host "Delegating deployment to raw Kubernetes script..." -ForegroundColor Cyan
        & "$PSScriptRoot\k8s-deploy.ps1" `
            -JenkinsPassword "$JenkinsPassword" `
            -DbPassword "$DbPassword" `
            -GithubToken "$GithubToken"
    }

    Write-Host ""
    Write-Host "Platform deployed! Check pod status with:" -ForegroundColor Green
    Write-Host "  kubectl get pods -n $Namespace"


    # ── STEP 6 & 7: Tool configuration ─────────────────────────────────────────
    # These scripts configure SonarQube and Nexus via their REST APIs.
    if (-not $SkipSonar) {
        Write-Host ""
        Write-Host "[6/7] Configuring SonarQube..." -ForegroundColor Yellow
        Write-Host "Waiting for SonarQube to be ready..."
        kubectl wait --for=condition=ready pod -l app=sonarqube -n $Namespace --timeout=300s
        & "$PSScriptRoot\sonarqube-setup.ps1"
        & "$PSScriptRoot\sonarqube-import.ps1"
    }
    else {
        Write-Host ""
        Write-Host "[SKIP] Skipping SonarQube configuration..." -ForegroundColor Gray
    }

    if (-not $SkipNexus) {
        Write-Host ""
        Write-Host "[7/7] Configuring Nexus repositories..." -ForegroundColor Yellow
        Write-Host "Waiting for Nexus to be ready..."
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=nexus -n $Namespace --timeout=300s
        & "$PSScriptRoot\nexus-setup.ps1"
    }
    else {
        Write-Host ""
        Write-Host "[SKIP] Skipping Nexus configuration..." -ForegroundColor Gray
    }

}

# ─── STOP (HIBERNATE) ─────────────────────────────────────────────────────────

elseif ($Action -eq "stop") {
    Write-Host "=== Hibernating DevOps Environment ===" -ForegroundColor Cyan

    Write-Host "[1/2] Scaling all pods to 0..." -ForegroundColor Yellow
    kubectl scale statefulset jenkins  --replicas=0 -n $Namespace --timeout=60s
    kubectl scale statefulset nexus    --replicas=0 -n $Namespace --timeout=60s
    kubectl scale deployment sonarqube --replicas=0 -n $Namespace --timeout=60s
    kubectl scale deployment postgres  --replicas=0 -n $Namespace --timeout=60s

    Write-Host "[2/2] Scaling node pool to 0 (zero compute cost)..." -ForegroundColor Yellow
    gcloud container clusters resize $ClusterName `
        --node-pool=$NodePoolName `
        --region=$Region `
        --num-nodes=0 `
        --quiet

    Write-Host "Environment hibernated. Data is safe on persistent disks." -ForegroundColor Green

}

# ─── START (WAKE UP) ──────────────────────────────────────────────────────────

elseif ($Action -eq "start") {
    Write-Host "=== Starting DevOps Environment ===" -ForegroundColor Cyan

    Write-Host "[1/2] Provisioning node (e2-standard-4)..." -ForegroundColor Yellow
    gcloud container clusters resize $ClusterName `
        --node-pool=$NodePoolName `
        --region=$Region `
        --num-nodes=1 `
        --quiet

    Write-Host "Waiting for node to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    Write-Host "[2/2] Scaling all pods to 1..." -ForegroundColor Yellow
    kubectl scale statefulset jenkins  --replicas=1 -n $Namespace
    kubectl scale statefulset nexus    --replicas=1 -n $Namespace
    kubectl scale deployment sonarqube --replicas=1 -n $Namespace
    kubectl scale deployment postgres  --replicas=1 -n $Namespace

    Write-Host "Environment started. Check pod status with:" -ForegroundColor Green
    Write-Host "  kubectl get pods -n $Namespace"
}

# ─── MODULAR RELOADS ──────────────────────────────────────────────────────────

# Helper: Sync ConfigMap and Wait for Hash
function Sync-JenkinsConfig {
    Write-Host "Updating Jenkins ConfigMap from local files..." -ForegroundColor Yellow
    kubectl create configmap jenkins-casc-config `
        --from-file="jenkins.yaml=$ProjectRoot\config\jenkins\jenkins-casc.yaml" `
        --from-file="plugins.txt=$ProjectRoot\config\jenkins\plugins.txt" `
        --from-file="jenkins_jobs.groovy=$ProjectRoot\config\jenkins\jenkins-jobs.groovy" `
        --from-file="seed-bootstrap.groovy=$ProjectRoot\config\jenkins\seed-bootstrap.groovy" `
        --namespace $Namespace `
        --dry-run=client -o yaml | kubectl apply -f -

    Write-Host "Waiting for sync (MD5 check)..." -ForegroundColor Yellow
    $localHash = (certutil -hashfile "$ProjectRoot\config\jenkins\jenkins-casc.yaml" MD5 | Select-Object -Index 1).Replace(" ", "")
    $synced = $false
    $timeout = 120
    $start = Get-Date
    while (-not $synced -and ((Get-Date) - $start).TotalSeconds -lt $timeout) {
        $remoteHash = (kubectl exec jenkins-0 -n $Namespace -- md5sum /var/jenkins_config/jenkins.yaml 2>$null)
        if ($remoteHash -match "^([a-f0-9]+)") {
            if ($matches[1] -eq $localHash) { $synced = $true; Write-Host "SUCCESS: Sync verified." -ForegroundColor Green }
        }
        if (-not $synced) { Write-Host "." -NoNewline -ForegroundColor Gray; Start-Sleep -Seconds 2 }
    }
}

# Helper: Get Jenkins Auth
function Get-JenkinsAuth {
    $pw = gcloud secrets versions access latest --secret="jenkins-admin-password" --project=$ProjectId
    $ip = kubectl get svc jenkins -n $Namespace -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
    return @{ Password = $pw; Ip = $ip }
}

if ($Action -eq "reload-jcasc") {
    Write-Host "=== Action: Reloading JCasC Configuration ===" -ForegroundColor Cyan
    Sync-JenkinsConfig
    # 2. Get Jenkins Auth
    $Auth = Get-JenkinsAuth

    # 3. Purge old Seed Job (to force JCasC to recreate it with fresh structure)
    # This resolves the "Ant GLOB" error by ensuring the old absolute path target is wiped.
    Write-Host "Purging old Seed Job for fresh recreation..." -ForegroundColor Yellow
    $Headers = @{ "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$($Auth.Password)"))) " }
    try {
        $Crumb = Invoke-RestMethod -Uri "http://$($Auth.Ip)/crumbIssuer/api/json" -Method Get -Headers $Headers -SessionVariable Session
        if ($Crumb) { $Headers.Add($Crumb.crumbRequestField, $Crumb.crumb) }
        
        # We delete the job to clear any corrupted 'targets' fields
        $DeleteUrl = "http://$($Auth.Ip)/job/admin-tasks/job/Seed-Job/job/seed-job/doDelete"
        Invoke-RestMethod -Uri $DeleteUrl -Method Post -Headers $Headers -WebSession $Session -ErrorAction SilentlyContinue
    } catch { }

    Write-Host "Triggering JCasC reload API..." -ForegroundColor Yellow
    try {
        Invoke-RestMethod -Uri "http://$($Auth.Ip)/configuration-as-code/reload" -Method Post -Headers $Headers -WebSession $Session
        Write-Host "SUCCESS: JCasC reload complete." -ForegroundColor Green
    } catch { Write-Host "ERROR: Reload failed." -ForegroundColor Red; exit 1 }
}

elseif ($Action -eq "reload-seed-job") {
    Write-Host "=== Action: Syncing & Triggering Seed Job ===" -ForegroundColor Cyan
    Sync-JenkinsConfig
    $Auth = Get-JenkinsAuth
    Write-Host "Triggering Seed Job build..." -ForegroundColor Yellow
    $Headers = @{ "Authorization" = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$($Auth.Password)"))) " }
    try {
        $Crumb = Invoke-RestMethod -Uri "http://$($Auth.Ip)/crumbIssuer/api/json" -Method Get -Headers $Headers -SessionVariable Session
        if ($Crumb) { $Headers.Add($Crumb.crumbRequestField, $Crumb.crumb) }
        Invoke-RestMethod -Uri "http://$($Auth.Ip)/job/admin-tasks/job/Seed-Job/job/seed-job/build" -Method Post -Headers $Headers -WebSession $Session
        Write-Host "SUCCESS: Seed Job triggered." -ForegroundColor Green
    } catch { Write-Host "ERROR: Trigger failed." -ForegroundColor Red; exit 1 }
}

elseif ($Action -eq "reload-jenkins-plugins") {
    Write-Host "=== Action: Updating Jenkins Plugins ===" -ForegroundColor Cyan
    Sync-JenkinsConfig
    Write-Host "Rolling out Jenkins restart to install new plugins..." -ForegroundColor Yellow
    kubectl rollout restart statefulset/jenkins -n $Namespace
    kubectl rollout status statefulset/jenkins -n $Namespace --timeout=300s
}

elseif ($Action -eq "export-sonar-config") {
    Write-Host "=== Action: Exporting SonarQube Config ===" -ForegroundColor Cyan
    $env:SONAR_PASSWORD = gcloud secrets versions access latest --secret="sonar-admin-password" --project=$ProjectId
    & "$PSScriptRoot\sonarqube-export.ps1"
}

elseif ($Action -eq "import-sonar-config") {
    Write-Host "=== Action: Importing SonarQube Config ===" -ForegroundColor Cyan
    $env:SONAR_PASSWORD = gcloud secrets versions access latest --secret="sonar-admin-password" --project=$ProjectId
    & "$PSScriptRoot\sonarqube-import.ps1"
}


elseif ($Action -eq "export-sonar-plugins") {
    Write-Host "=== Action: Exporting SonarQube Plugins (.jar) ===" -ForegroundColor Cyan
    $pod = (kubectl get pod -l app.kubernetes.io/name=sonarqube -n $Namespace -o jsonpath='{.items[0].metadata.name}')
    $targetDir = "$ProjectRoot\config\sonarqube\plugins"
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir }
    
    Write-Host "Downloading plugins from pod $pod..." -ForegroundColor Yellow
    kubectl cp "$($Namespace)/$($pod):/opt/sonarqube/extensions/plugins" "$targetDir"
    Write-Host "SUCCESS: Plugins exported to $targetDir" -ForegroundColor Green
}

elseif ($Action -eq "import-sonar-plugins") {
    Write-Host "=== Action: Importing SonarQube Plugins (.jar) ===" -ForegroundColor Cyan
    $pod = (kubectl get pod -l app.kubernetes.io/name=sonarqube -n $Namespace -o jsonpath='{.items[0].metadata.name}')
    $sourceDir = "$ProjectRoot\config\sonarqube\plugins"
    
    if (-not (Test-Path $sourceDir)) { 
        Write-Host "ERROR: No plugins found in $sourceDir. Run export first." -ForegroundColor Red
        exit 1
    }

    Write-Host "Cleaning up old plugins in pod to ensure a clean sync..." -ForegroundColor Gray
    kubectl exec $pod -n $Namespace -- sh -c "rm -rf /opt/sonarqube/extensions/plugins/*"

    Write-Host "Uploading plugins to pod $pod..." -ForegroundColor Yellow
    kubectl cp "$sourceDir" "$($Namespace)/$($pod):/opt/sonarqube/extensions/plugins"
    
    Write-Host "Restarting SonarQube to activate plugins..." -ForegroundColor Yellow
    kubectl rollout restart deployment/sonarqube -n $Namespace
    kubectl rollout status deployment/sonarqube -n $Namespace --timeout=300s
    Write-Host "SUCCESS: Plugins imported and SonarQube restarted." -ForegroundColor Green
}
